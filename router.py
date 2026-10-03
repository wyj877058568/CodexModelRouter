#!/usr/bin/env python3
"""Local model router for Codex.

Listens on 127.0.0.1 and forwards each Responses API request to the right
upstream, based on the requested model name:

  * deepseek-*  -> https://api.deepseek.com  (direct, DeepSeek API key)
  * everything  -> https://chatgpt.com/backend-api/codex  (ChatGPT login token
                   from auth.json, optionally through the system HTTP proxy)

Only Python's standard library is used.
"""

import base64
import http.client
import hashlib
import json
import os
import re
import select
import ssl
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(
    os.path.expanduser("~"), ".codex"
)
AUTH_PATH = os.path.join(CODEX_HOME, "auth.json")
CONFIG_PATH = os.path.join(CODEX_HOME, "config.toml")

# When running as a frozen executable (PyInstaller) the script itself lives in a
# temporary extraction directory, so resolve everything relative to the program
# that is actually running. Running from source keeps the old behaviour.
if getattr(sys, "frozen", False):
    BASE_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

LOG_PATH = os.path.join(BASE_DIR, "router.log")
TLS_DIR = os.path.join(BASE_DIR, "tls")

LISTEN_HOST = os.environ.get("ROUTER_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("ROUTER_PORT", "8788"))

DEEPSEEK_HOST = "api.deepseek.com"
CHATGPT_HOST = "chatgpt.com"
CHATGPT_PREFIX = "/backend-api/codex"
AUTH_HOST = "auth.openai.com"
AUTH_TOKEN_PATH = "/oauth/token"
CHATGPT_CLIENT_ID = os.environ.get("ROUTER_OAUTH_CLIENT_ID", "app_EMoamEEZ73f0CkXaXp7hrann")

UPSTREAM_TIMEOUT_SEC = float(os.environ.get("ROUTER_UPSTREAM_TIMEOUT", "900"))
DEFAULT_ORIGINATOR = "Codex Desktop"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def log(record):
    record = dict(record)
    record["at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 5 * 1024 * 1024:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def read_deepseek_key():
    """Pull experimental_bearer_token out of the [model_providers.deepseek] block."""
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return None
    match = re.search(r"(?ms)^\[model_providers\.deepseek\]\s*(.*?)(?=^\[|\Z)", text)
    if not match:
        return None
    token = re.search(r'experimental_bearer_token\s*=\s*"([^"]+)"', match.group(1))
    return token.group(1) if token else None


def read_chatgpt_auth():
    try:
        with open(AUTH_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None, None
    tokens = data.get("tokens") or {}
    return tokens.get("access_token"), tokens.get("account_id")


def read_refresh_token():
    try:
        with open(AUTH_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return (data.get("tokens") or {}).get("refresh_token")


def read_system_proxy():
    """Return (host, port) for the WinINET proxy when it is enabled."""
    override = os.environ.get("ROUTER_PROXY")
    if override is not None:
        override = override.strip()
        if override.lower() in ("", "none", "off", "direct"):
            return None
        return parse_proxy(override)
    if os.name != "nt":
        return None
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
        ) as key:
            enabled = winreg.QueryValueEx(key, "ProxyEnable")[0]
            server = winreg.QueryValueEx(key, "ProxyServer")[0]
        if not enabled or not server:
            return None
        return parse_proxy(server)
    except OSError:
        return None


def parse_proxy(value):
    if "=" in value:
        entries = {}
        for part in value.split(";"):
            if "=" in part:
                scheme, addr = part.split("=", 1)
                entries[scheme.strip().lower()] = addr.strip()
        value = entries.get("https") or entries.get("http") or ""
    value = value.strip()
    if not value:
        return None
    value = re.sub(r"^[a-zA-Z]+://", "", value)
    if ":" not in value:
        return (value, 8080)
    host, port = value.rsplit(":", 1)
    try:
        return (host, int(port))
    except ValueError:
        return (host, 8080)


def open_https(host, port=443, proxy=None):
    context = ssl.create_default_context()
    if proxy:
        connection = http.client.HTTPSConnection(
            proxy[0], proxy[1], timeout=UPSTREAM_TIMEOUT_SEC, context=context
        )
        connection.set_tunnel(host, port)
        return connection
    return http.client.HTTPSConnection(host, port, timeout=UPSTREAM_TIMEOUT_SEC, context=context)


def refresh_chatgpt_tokens(refresh_token):
    """Exchange the stored refresh token for a fresh access token."""
    payload = json.dumps(
        {
            "client_id": CHATGPT_CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": "openid profile email",
        }
    ).encode("utf-8")
    proxy = read_system_proxy()
    connection = open_https(AUTH_HOST, 443, proxy)
    try:
        connection.request(
            "POST",
            AUTH_TOKEN_PATH,
            body=payload,
            headers={"content-type": "application/json", "accept": "application/json"},
        )
        response = connection.getresponse()
        raw = response.read()
        if response.status != 200:
            log({"event": "refresh_failed", "status": response.status, "body": raw[:200].decode("utf-8", "replace")})
            return None
        return json.loads(raw.decode("utf-8"))
    except Exception as exc:
        log({"event": "refresh_error", "error": repr(exc)})
        return None
    finally:
        try:
            connection.close()
        except Exception:
            pass


def persist_chatgpt_tokens(tokens):
    """Write refreshed tokens back into auth.json without disturbing other fields."""
    try:
        with open(AUTH_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return
    current = data.get("tokens") or {}
    if tokens.get("access_token"):
        current["access_token"] = tokens["access_token"]
    if tokens.get("refresh_token"):
        current["refresh_token"] = tokens["refresh_token"]
    if tokens.get("id_token"):
        current["id_token"] = tokens["id_token"]
    data["tokens"] = current
    data["last_refresh"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f000Z")
    tmp_path = AUTH_PATH + ".router-tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
        os.replace(tmp_path, AUTH_PATH)
        log({"event": "tokens_refreshed"})
    except OSError as exc:
        log({"event": "refresh_persist_failed", "error": repr(exc)})


def adapt_body_for_chatgpt(body):
    """Minimal fixes so the ChatGPT backend accepts the Responses payload."""
    changed = []
    if body.get("store") is not False:
        body["store"] = False
        changed.append("store")
    reasoning = body.get("reasoning")
    if isinstance(reasoning, dict):
        summary = reasoning.get("summary")
        if summary not in ("auto", "concise", "detailed"):
            reasoning["summary"] = "auto"
            changed.append("reasoning.summary")
    body.pop("safety_identifier", None)
    return changed


def upstream_path(path):
    """Map a client path onto chatgpt.com.

    Codex either talks to the router root (old custom-provider setup, so it
    sends "/responses") or to a base URL that already contains /backend-api
    (current setup, so it sends the full path). Anything already absolute must
    be forwarded untouched.
    """
    if path.startswith("/backend-api") or path.startswith("/.well-known"):
        return path
    if path.endswith("/responses"):
        return CHATGPT_PREFIX + "/responses"
    return CHATGPT_PREFIX + path


BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)

# Only paths listed in this file use browser-like headers. Everything else keeps
# the original headers. The file is re-read per request, so the list can be
# changed without restarting the router.
BROWSER_HEADER_CONFIG = os.path.join(
    BASE_DIR, "browser-header-paths.txt"
)


def browser_header_paths():
    try:
        with open(BROWSER_HEADER_CONFIG, "r", encoding="utf-8") as handle:
            return tuple(
                line.strip()
                for line in handle
                if line.strip() and not line.strip().startswith("#")
            )
    except OSError:
        return ()


def browser_headers(token, account_id):
    headers = {
        "accept": "*/*",
        "accept-language": "en-US,en;q=0.9",
        "authorization": "Bearer " + token,
        "originator": DEFAULT_ORIGINATOR,
        "user-agent": BROWSER_USER_AGENT,
        "sec-ch-ua": '"Chromium";v="140", "Not:A-Brand";v="24"',
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"Windows"',
        "sec-fetch-dest": "empty",
        "sec-fetch-mode": "cors",
        "sec-fetch-site": "same-origin",
    }
    if account_id:
        headers["chatgpt-account-id"] = account_id
    return headers


def ws_preview(data, masked, limit=200):
    """Best-effort peek at the first websocket frame inside a raw buffer."""
    try:
        if len(data) < 2:
            return ""
        length = data[1] & 0x7F
        offset = 2
        if length == 126:
            length = int.from_bytes(data[2:4], "big")
            offset = 4
        elif length == 127:
            length = int.from_bytes(data[2:10], "big")
            offset = 10
        key = b""
        if data[1] & 0x80:
            key = data[offset:offset + 4]
            offset += 4
        payload = bytearray(data[offset:offset + limit])
        if key:
            for index in range(len(payload)):
                payload[index] ^= key[index % 4]
        return "opcode=%d len=%d %s" % (
            data[0] & 0x0F,
            length,
            bytes(payload).decode("utf-8", "replace"),
        )
    except Exception as exc:
        return "preview error: %r" % (exc,)


def encode_ws_frame(opcode, payload, mask=True):
    header = bytearray([0x80 | opcode])
    length = len(payload)
    flag = 0x80 if mask else 0
    if length < 126:
        header.append(flag | length)
    elif length < 65536:
        header.append(flag | 126)
        header += length.to_bytes(2, "big")
    else:
        header.append(flag | 127)
        header += length.to_bytes(8, "big")
    if not mask:
        return bytes(header) + payload
    key = os.urandom(4)
    header += key
    return bytes(header) + bytes(payload[i] ^ key[i % 4] for i in range(length))


def read_ws_frame(sock, buffer, timeout=None):
    """Return (opcode, fin, payload, raw), None on EOF, "timeout" when idle.

    ``buffer`` is a bytearray that is consumed as frames are parsed; when it
    runs dry the socket is read again.
    """
    deadline = None if timeout is None else time.time() + timeout
    while True:
        if len(buffer) >= 2:
            length = buffer[1] & 0x7F
            offset = 2
            known = True
            if length == 126:
                if len(buffer) >= 4:
                    length = int.from_bytes(buffer[2:4], "big")
                    offset = 4
                else:
                    known = False
            elif length == 127:
                if len(buffer) >= 10:
                    length = int.from_bytes(buffer[2:10], "big")
                    offset = 10
                else:
                    known = False
            if known:
                masked = bool(buffer[1] & 0x80)
                key_len = 4 if masked else 0
                need = offset + key_len + length
                if len(buffer) >= need:
                    raw = bytes(buffer[:need])
                    opcode = buffer[0] & 0x0F
                    fin = bool(buffer[0] & 0x80)
                    key = bytes(buffer[offset:offset + 4]) if masked else b""
                    payload = bytearray(buffer[offset + key_len:need])
                    if masked:
                        for index in range(len(payload)):
                            payload[index] ^= key[index % 4]
                    del buffer[:need]
                    return opcode, fin, bytes(payload), raw
        if deadline is not None:
            remaining = deadline - time.time()
            if remaining <= 0:
                return "timeout"
            try:
                ready, _, _ = select.select([sock], [], [], remaining)
            except (OSError, ValueError):
                return None
            if not ready:
                return "timeout"
        try:
            chunk = sock.recv(65536)
        except OSError:
            return None
        if not chunk:
            return None
        buffer += chunk


class RouterServer(ThreadingHTTPServer):
    # Keep duplicate copies from silently sharing the port on Windows.
    allow_reuse_address = False
    daemon_threads = True


class Router(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CodexModelRouter/1.0"

    def log_message(self, fmt, *args):  # keep stderr quiet
        pass

    def do_GET(self):
        started = time.time()
        log({"event": "get", "path": self.path})
        if (self.headers.get("upgrade") or "").lower() == "websocket":
            self._relay_websocket(started)
            return
        token, account_id = read_chatgpt_auth()
        if not token:
            self._send_json(
                401,
                {"error": {"message": "no ChatGPT token in auth.json; run `codex login`", "type": "invalid_request_error"}},
            )
            return
        path = self.path
        path = upstream_path(path)
        if any(path.startswith(prefix) for prefix in browser_header_paths()):
            headers = browser_headers(token, account_id)
        else:
            headers = {
                "accept": "*/*",
                "authorization": "Bearer " + token,
                "originator": DEFAULT_ORIGINATOR,
                "user-agent": "Codex Desktop/0.159.2 (Windows) router",
            }
            if account_id:
                headers["chatgpt-account-id"] = account_id

        def renew_authorization():
            refresh_token = read_refresh_token()
            if not refresh_token:
                return None
            tokens = refresh_chatgpt_tokens(refresh_token)
            if not tokens or not tokens.get("access_token"):
                return None
            persist_chatgpt_tokens(tokens)
            renewed = dict(headers)
            renewed["authorization"] = "Bearer " + tokens["access_token"]
            return renewed

        self._relay(
            host=CHATGPT_HOST,
            path=path,
            body=None,
            headers=headers,
            leg="chatgpt-get",
            model="",
            started=started,
            use_system_proxy=True,
            renew_authorization=renew_authorization,
            method="GET",
        )

    def do_POST(self):
        started = time.time()
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8"))
        except ValueError:
            self._send_json(400, {"error": {"message": "invalid json body"}})
            return

        model = str(body.get("model") or "")
        log({"event": "post", "path": self.path, "model": model, "bytes": len(raw)})
        if model.lower().startswith("deepseek"):
            self._forward_deepseek(body, model, started)
        else:
            self._forward_chatgpt(body, model, started)

    def do_PUT(self):
        self._forward_other("PUT")

    def do_PATCH(self):
        self._forward_other("PATCH")

    def do_DELETE(self):
        self._forward_other("DELETE")

    def _forward_other(self, method):
        """Forward the less common verbs straight to the ChatGPT backend."""
        started = time.time()
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        log({"event": method.lower(), "path": self.path, "bytes": len(raw)})
        token, account_id = read_chatgpt_auth()
        if not token:
            self._send_json(
                401,
                {"error": {"message": "no ChatGPT token in auth.json; run `codex login`", "type": "invalid_request_error"}},
            )
            return
        path = self.path
        path = upstream_path(path)
        headers = {
            "accept": self.headers.get("accept") or "*/*",
            "content-type": self.headers.get("content-type") or "application/json",
            "authorization": "Bearer " + token,
            "originator": DEFAULT_ORIGINATOR,
            "user-agent": self.headers.get("user-agent") or "Codex Desktop router",
        }
        if account_id:
            headers["chatgpt-account-id"] = account_id
        self._relay(
            host=CHATGPT_HOST,
            path=path,
            body=raw,
            headers=headers,
            leg="chatgpt-" + method.lower(),
            model="",
            started=started,
            use_system_proxy=True,
            method=method,
        )

    # ---------- upstreams ----------

    def _open_upstream_websocket(self, path, access_token, account_id, client_protocol):
        """Perform the websocket handshake with chatgpt.com and return the socket."""
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        headers = [
            ("host", CHATGPT_HOST),
            ("upgrade", "websocket"),
            ("connection", "Upgrade"),
            ("sec-websocket-key", key),
            ("sec-websocket-version", "13"),
            ("authorization", "Bearer " + access_token),
            ("originator", DEFAULT_ORIGINATOR),
            ("user-agent", "Codex Desktop/0.159.2 (Windows) router"),
        ]
        if account_id:
            headers.append(("chatgpt-account-id", account_id))
        if client_protocol:
            headers.append(("sec-websocket-protocol", client_protocol))
        connection = open_https(CHATGPT_HOST, 443, read_system_proxy())
        connection.connect()
        sock = connection.sock
        request = "GET %s HTTP/1.1\r\n%s\r\n" % (
            path,
            "".join("%s: %s\r\n" % pair for pair in headers),
        )
        sock.sendall(request.encode("utf-8"))
        buffer = b""
        while b"\r\n\r\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
        head, _, rest = buffer.partition(b"\r\n\r\n")
        return connection, sock, head, rest

    def _relay_websocket(self, started):
        """Tunnel a websocket session straight through to the ChatGPT backend.

        Frames are forwarded untouched: the client masks what it sends and the
        backend does not, exactly as it would be on a direct connection.
        """
        token, account_id = read_chatgpt_auth()
        if not token:
            self._send_json(
                401,
                {"error": {"message": "no ChatGPT token in auth.json; run `codex login`", "type": "invalid_request_error"}},
            )
            return
        path = upstream_path(self.path)
        client_protocol = self.headers.get("sec-websocket-protocol")
        log({"event": "ws_open", "path": path})

        connection = None
        upstream = None
        refreshed = False
        while True:
            try:
                connection, upstream, head, rest = self._open_upstream_websocket(
                    path, token, account_id, client_protocol
                )
            except Exception as exc:
                log({"event": "ws_error", "path": path, "error": repr(exc)})
                self._send_json(
                    502,
                    {
                        "error": {
                            "message": "router could not reach the websocket upstream: %s" % exc,
                            "type": "upstream_error",
                        }
                    },
                )
                return
            try:
                status = int(head.split(b" ", 2)[1])
            except Exception:
                status = 0
            if status == 401 and not refreshed:
                refreshed = True
                log({"event": "ws_upstream_401_refreshing", "path": path})
                try:
                    connection.close()
                except Exception:
                    pass
                refresh_token = read_refresh_token()
                tokens = refresh_chatgpt_tokens(refresh_token) if refresh_token else None
                if not tokens or not tokens.get("access_token"):
                    self._send_json(
                        401,
                        {"error": {"message": "ChatGPT session expired; run `codex login`.", "type": "invalid_request_error"}},
                    )
                    return
                persist_chatgpt_tokens(tokens)
                token = tokens["access_token"]
                continue
            break

        if status != 101:
            self.wfile.write(head + b"\r\n\r\n" + rest)
            try:
                self.wfile.flush()
            except Exception:
                pass
            log({"event": "ws_rejected", "path": path, "status": status})
            try:
                connection.close()
            except Exception:
                pass
            self.close_connection = True
            return

        client_key = self.headers.get("sec-websocket-key") or ""
        accept = base64.b64encode(
            hashlib.sha1((client_key + WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        chosen_protocol = None
        for line in head.split(b"\r\n")[1:]:
            if line.lower().startswith(b"sec-websocket-protocol:"):
                chosen_protocol = line.split(b":", 1)[1].strip()
        self.wfile.write(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            b"Sec-WebSocket-Accept: " + accept.encode("ascii") + b"\r\n"
        )
        if chosen_protocol:
            self.wfile.write(b"Sec-WebSocket-Protocol: " + chosen_protocol + b"\r\n")
        self.wfile.write(b"\r\n")
        self.wfile.flush()

        client_sock = self.connection
        if rest:
            try:
                client_sock.sendall(rest)
            except OSError:
                pass
        client_buffer = bytearray()
        try:  # bytes the client pipelined after the handshake request
            client_buffer += self.rfile.peek(0)
        except Exception:
            pass

        first = read_ws_frame(client_sock, client_buffer, timeout=3)
        if first is None:
            log({"event": "ws_closed", "path": path, "ms": int((time.time() - started) * 1000)})
            try:
                connection.close()
            except Exception:
                pass
            self.close_connection = True
            return
        if first == "timeout":
            # No client frame yet: this is a server-driven tunnel (remote
            # control), so keep relaying bytes in both directions.
            log({"event": "ws_route", "path": path, "leg": "chatgpt", "model": "", "note": "server-driven"})
            pending = bytes(client_buffer)
            client_buffer.clear()
            if pending:
                try:
                    upstream.sendall(pending)
                except OSError:
                    self.close_connection = True
                    return
            first_raw = b""
        else:
            opcode, _, first_payload, first_raw = first
            model = ""
            if opcode == 0x1:
                try:
                    model = str(json.loads(first_payload.decode("utf-8")).get("model") or "")
                except Exception:
                    model = ""
            if model.lower().startswith("deepseek"):
                log({"event": "ws_route", "path": path, "leg": "deepseek", "model": model})
                try:
                    connection.close()
                except Exception:
                    pass
                self._bridge_websocket_deepseek(
                    client_sock, client_buffer, first_payload, started, path
                )
                return
            log({"event": "ws_route", "path": path, "leg": "chatgpt", "model": model})
            try:
                upstream.sendall(first_raw)
            except OSError:
                self.close_connection = True
                return

        forwarded_up = forwarded_down = 0
        debug = os.environ.get("ROUTER_WS_DEBUG")
        capture_path = os.environ.get("ROUTER_WS_CAPTURE")
        captured = 0
        previews = {"c2u": 0, "u2c": 0}
        while True:
            try:
                readable, _, errored = select.select([client_sock, upstream], [], [client_sock, upstream])
            except (OSError, ValueError):
                break
            if errored:
                break
            hole = False
            for source in readable:
                try:
                    data = source.recv(65536)
                except OSError:
                    data = b""
                if not data:
                    hole = True
                    break
                target = upstream if source is client_sock else client_sock
                try:
                    target.sendall(data)
                except OSError:
                    hole = True
                    break
                if source is client_sock:
                    forwarded_up += len(data)
                    if capture_path and captured < 262144:
                        try:
                            with open(capture_path, "ab") as handle:
                                handle.write(data)
                            captured += len(data)
                        except OSError:
                            pass
                    if debug and previews["c2u"] < 2:
                        previews["c2u"] += 1
                        log({"event": "ws_c2u", "preview": ws_preview(data, masked=True)})
                else:
                    forwarded_down += len(data)
                    if debug and previews["u2c"] < 2:
                        previews["u2c"] += 1
                        log({"event": "ws_u2c", "preview": ws_preview(data, masked=False)})
            if hole:
                break

        for sock in (client_sock, upstream):
            try:
                sock.shutdown(2)
            except Exception:
                pass
        try:
            connection.close()
        except Exception:
            pass
        log(
            {
                "event": "ws_closed",
                "path": path,
                "ms": int((time.time() - started) * 1000),
                "up": forwarded_up,
                "down": forwarded_down,
            }
        )
        self.close_connection = True

    def _bridge_websocket_deepseek(self, client_sock, client_buffer, first_payload, started, path):
        """Serve this websocket session from DeepSeek instead of ChatGPT."""
        payload = first_payload
        streamed = 0
        while True:
            current = payload
            payload = None
            while current is None:
                frame = read_ws_frame(client_sock, client_buffer)
                if frame is None:
                    log(
                        {
                            "event": "ws_closed",
                            "path": path,
                            "leg": "deepseek",
                            "ms": int((time.time() - started) * 1000),
                            "down": streamed,
                        }
                    )
                    return
                opcode, _, data, _ = frame
                if opcode == 0x8:
                    try:
                        client_sock.sendall(encode_ws_frame(0x8, b"", mask=False))
                    except OSError:
                        pass
                    return
                if opcode == 0x9:
                    try:
                        client_sock.sendall(encode_ws_frame(0xA, data, mask=False))
                    except OSError:
                        return
                    continue
                if opcode == 0xA:
                    continue
                if opcode in (0x1, 0x2):
                    current = data
            try:
                request = json.loads(current.decode("utf-8"))
            except ValueError:
                continue
            if not isinstance(request, dict) or request.get("type") != "response.create":
                continue
            streamed += self._stream_deepseek_response(request, client_sock)

    def _stream_deepseek_response(self, request, client_sock):
        """Replay a DeepSeek SSE stream as websocket text frames."""
        body = {key: value for key, value in request.items() if key != "type"}
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {
            "content-type": "application/json",
            "accept": "text/event-stream",
            "authorization": "Bearer " + (read_deepseek_key() or ""),
            "user-agent": "CodexModelRouter/1.0",
            "accept-encoding": "identity",
            "content-length": str(len(payload)),
        }
        connection = open_https(DEEPSEEK_HOST, 443, None)
        sent = 0
        try:
            connection.request("POST", "/responses", body=payload, headers=headers)
            response = connection.getresponse()
            if response.status != 200:
                raw = response.read()
                message = {
                    "type": "error",
                    "error": {
                        "type": "upstream_error",
                        "message": raw[:400].decode("utf-8", "replace"),
                    },
                }
                client_sock.sendall(
                    encode_ws_frame(0x1, json.dumps(message).encode("utf-8"), mask=False)
                )
                log(
                    {
                        "leg": "deepseek",
                        "event": "ws_upstream_error",
                        "status": response.status,
                        "model": body.get("model"),
                        "keys": sorted(body.keys()),
                        "body": raw[:300].decode("utf-8", "replace"),
                    }
                )
                return 0
            while True:
                line = response.readline()
                if not line:
                    break
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                chunk = line[5:].strip()
                if not chunk or chunk == b"[DONE]":
                    continue
                client_sock.sendall(encode_ws_frame(0x1, chunk, mask=False))
                sent += len(chunk)
        except OSError as exc:
            log({"leg": "deepseek", "event": "ws_stream_error", "error": repr(exc)})
        finally:
            try:
                connection.close()
            except Exception:
                pass
        log(
            {
                "leg": "deepseek",
                "event": "ws_stream_done",
                "model": body.get("model"),
                "bytes": sent,
            }
        )
        return sent

    def _forward_deepseek(self, body, model, started):
        key = read_deepseek_key()
        headers = {
            "content-type": "application/json",
            "accept": "text/event-stream",
            "authorization": "Bearer " + (key or ""),
            "user-agent": "CodexModelRouter/1.0",
        }
        # DeepSeek serves the Responses API at /responses; strip the ChatGPT style
        # prefix that arrives when the client talks to chatgpt_base_url.
        path = self.path
        if path.startswith(CHATGPT_PREFIX):
            path = path[len(CHATGPT_PREFIX):] or "/responses"
            if not path.startswith("/"):
                path = "/" + path
        self._relay(
            host=DEEPSEEK_HOST,
            path=path,
            body=body,
            headers=headers,
            leg="deepseek",
            model=model,
            started=started,
        )

    def _forward_chatgpt(self, body, model, started):
        token, account_id = read_chatgpt_auth()
        if not token:
            self._send_json(
                401,
                {"error": {"message": "no ChatGPT token in auth.json; run `codex login`", "type": "invalid_request_error"}},
            )
            return
        adapt_body_for_chatgpt(body)
        path = upstream_path(self.path)

        def build_headers(access_token):
            built = {
                "content-type": "application/json",
                "accept": "text/event-stream",
                "authorization": "Bearer " + access_token,
                "originator": DEFAULT_ORIGINATOR,
                "user-agent": "Codex Desktop/0.158.0-alpha.2 (Windows) router",
                "OpenAI-Beta": "responses=experimental",
                "session_id": str(uuid.uuid4()),
            }
            if account_id:
                built["chatgpt-account-id"] = account_id
            return built

        def renew_authorization():
            refresh_token = read_refresh_token()
            if not refresh_token:
                return None
            tokens = refresh_chatgpt_tokens(refresh_token)
            if not tokens or not tokens.get("access_token"):
                return None
            persist_chatgpt_tokens(tokens)
            return build_headers(tokens["access_token"])

        self._relay(
            host=CHATGPT_HOST,
            path=path,
            body=body,
            headers=build_headers(token),
            leg="chatgpt",
            model=model,
            started=started,
            use_system_proxy=True,
            renew_authorization=renew_authorization,
        )

    def _relay(self, host, path, body, headers, leg, model, started, use_system_proxy=False, renew_authorization=None, method="POST"):
        if body is None:
            payload = b""
        elif isinstance(body, (bytes, bytearray)):
            payload = bytes(body)
        else:
            payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["content-length"] = str(len(payload))
        headers["accept-encoding"] = "identity"

        proxy = read_system_proxy() if use_system_proxy else None
        refreshed = False
        while True:
            connection = open_https(host, 443, proxy)
            try:
                connection.request(method, path, body=payload, headers=headers)
                response = connection.getresponse()
            except Exception as exc:  # network / proxy failure
                log({"leg": leg, "path": path, "model": model, "error": repr(exc), "proxy": bool(proxy)})
                self._send_json(
                    502,
                    {
                        "error": {
                            "message": "router could not reach %s: %s%s"
                            % (host, exc, "" if not proxy else " (via proxy %s:%s)" % proxy),
                            "type": "upstream_error",
                        }
                    },
                )
                try:
                    connection.close()
                except Exception:
                    pass
                return

            if response.status == 401 and renew_authorization is not None and not refreshed:
                refreshed = True
                try:
                    response.read()
                except Exception:
                    pass
                try:
                    connection.close()
                except Exception:
                    pass
                log({"leg": leg, "path": path, "model": model, "event": "upstream_401_refreshing"})
                new_headers = renew_authorization()
                if new_headers is None:
                    self._send_json(
                        401,
                        {
                            "error": {
                                "message": "ChatGPT session expired and the router could not refresh it; run `codex login`.",
                                "type": "invalid_request_error",
                            }
                        },
                    )
                    return
                headers = new_headers
                headers["content-length"] = str(len(payload))
                headers["accept-encoding"] = "identity"
                continue
            break

        self.send_response(response.status)
        passthrough = {
            "content-type": response.getheader("content-type") or "text/event-stream",
            "cache-control": response.getheader("cache-control"),
        }
        for name, value in passthrough.items():
            if value:
                self.send_header(name, value)
        self.send_header("connection", "close")
        self.end_headers()

        total = 0
        try:
            while True:
                chunk = response.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                total += len(chunk)
        except Exception as exc:
            log({"leg": leg, "path": path, "model": model, "error": "stream: " + repr(exc), "bytes": total})
        finally:
            try:
                connection.close()
            except Exception:
                pass
            log(
                {
                    "leg": leg,
                    "path": path,
                    "model": model,
                    "status": response.status,
                    "bytes": total,
                    "ms": int((time.time() - started) * 1000),
                    "proxy": bool(proxy),
                }
            )
        self.close_connection = True

    def _send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True


def build_server(port, tls_context=None):
    try:
        server = RouterServer((LISTEN_HOST, port), Router)
    except OSError as exc:
        # Most likely another copy is already listening; that is fine (used as a
        # cheap watchdog check when the scheduled task runs again).
        log({"event": "bind_failed", "port": port, "error": repr(exc)})
        print("port %d unavailable: %s" % (port, exc), flush=True)
        return None
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    scheme = "https" if tls_context is not None else "http"
    log(
        {
            "listen": "%s:%d" % (LISTEN_HOST, port),
            "event": "start",
            "pid": os.getpid(),
            "scheme": scheme,
        }
    )
    print("Codex model router listening on %s://%s:%d" % (scheme, LISTEN_HOST, port), flush=True)
    return server


def load_tls_context():
    cert = os.environ.get("ROUTER_TLS_CERT") or os.path.join(TLS_DIR, "server.crt")
    key = os.environ.get("ROUTER_TLS_KEY") or os.path.join(TLS_DIR, "server.key")
    if not (os.path.exists(cert) and os.path.exists(key)):
        log({"event": "tls_skipped", "cert": cert})
        return None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    return context


def main():
    servers = []
    plain = build_server(LISTEN_PORT)
    if plain is not None:
        servers.append(plain)
    tls_context = load_tls_context()
    if tls_context is not None:
        secure = build_server(int(os.environ.get("ROUTER_TLS_PORT", "8789")), tls_context)
        if secure is not None:
            servers.append(secure)
    if not servers:
        print("router already running or ports unavailable", flush=True)
        return 0
    for extra in servers[1:]:
        threading.Thread(target=extra.serve_forever, daemon=True).start()
    try:
        servers[0].serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
