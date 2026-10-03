# CodexModelRouter

**让 Codex 桌面版在一个模型下拉框里同时使用 DeepSeek 和 ChatGPT 登录模型——一个 provider，两套后端，不用来回改配置。**

[English](README.md) · [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078d4.svg)](#环境要求)
[![Python: 3.11+](https://img.shields.io/badge/Python-3.11%2B-3776ab.svg)](#开发)

`CodexModelRouter` 是一个零依赖的本地 HTTP/HTTPS 服务，夹在 Codex 客户端和模型提供方之间。
Codex 仍然使用内置的 `openai` provider（所以账号界面一切正常），由路由器按请求决定：
这个模型该发给 DeepSeek，还是发给 ChatGPT 后端。

![架构图](docs/architecture.svg)

## 为什么需要它

- Codex 的模型选择器只切换**模型名**，而 **provider 是全局设置**。正常情况下你没法在同一个
  下拉框里同时用"DeepSeek 驱动的模型"和"ChatGPT 订阅的模型"。
- ChatGPT 登录模式走的是专有协议（`chatgpt.com/backend-api/codex`，HTTP + WebSocket 的
  Responses API），LiteLLM 这类通用多provider网关接不了——它们面向的是 OpenAI 兼容的
  API key。
- 想把 `chatgpt_base_url` 指向本地服务，就必须提供 HTTPS + 被系统信任的证书，这正是本项目做的事。

效果就是：`deepseek-flash` 和 `gpt-5.6-luna` 可以并排出现在同一个下拉框里。

## 架构

```
Codex / ChatGPT 桌面客户端
        │  chatgpt_base_url = https://127.0.0.1:8789/backend-api
        ▼
CodexModelRouter.exe            ── deepseek-*       → api.deepseek.com
 127.0.0.1:8789 HTTPS           ── 其它模型          → chatgpt.com/backend-api/codex
 127.0.0.1:8788 HTTP（兼容旧会话）
```

| 组件 | 作用 |
| --- | --- |
| `router.py` | 整个路由器：按模型名分流、令牌刷新、WebSocket 透传、DeepSeek 的 WS→SSE 桥接。纯标准库。 |
| HTTPS 监听（8789） | 用本地生成的 CA 终结 TLS——因为 Codex 要求 `chatgpt_base_url` 必须是 HTTPS。 |
| HTTP 监听（8788） | 留给绑定在早期"自定义 provider"形态上的旧会话。 |
| `auth.json` | ChatGPT 登录令牌。路由器在遇到 HTTP 401 时自动刷新并写回。 |

## 环境要求

- Windows 10/11
- Codex（ChatGPT）桌面版，且已用 ChatGPT 账号登录
- Python 3.11+（生成证书与打包 exe 用）
- 一个 DeepSeek API key
- 可选：如果你的网络需要才能访问 `chatgpt.com`，则需要系统代理

## 快速开始

```powershell
git clone https://github.com/<你的用户名>/CodexModelRouter.git
cd CodexModelRouter
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` 会把所有步骤做完，并在最后打印配置片段：

1. 生成本地 CA 与服务器证书（`make-tls-cert.py`）；
2. 把 CA 装进「当前用户 → 受信任的根证书颁发机构」；
3. 创建带安全默认值的 `browser-header-paths.txt`；
4. 打包 `CodexModelRouter.exe`（PyInstaller）；
5. 注册登录自启的计划任务并启动路由器。

然后在 `%USERPROFILE%\.codex\config.toml` 里加上：

```toml
model_provider = "openai"
chatgpt_base_url = "https://127.0.0.1:8789/backend-api"
model_catalog_json = "~/.codex/models.json"

[model_providers.deepseek]
base_url = "http://127.0.0.1:8788/"
wire_api = "responses"
experimental_bearer_token = "sk-你的-deepseek-key"
```

确保 `~/.codex/models.json` 里同时包含两边的模型，然后重启客户端即可。

## 手动安装

```powershell
python make-tls-cert.py                                                    # 1. 生成证书
Import-Certificate tls\ca.crt -CertStoreLocation Cert:\CurrentUser\Root    # 2. 信任证书
powershell -ExecutionPolicy Bypass -File build-exe.ps1                     # 3. 打包（可选）
schtasks /create /tn CodexModelRouter /xml task-template.xml /f            # 4. 自启（先改里面的路径）
start-router.cmd                                                           # 5. 启动
```

## 日常使用

- **自启**：计划任务 `CodexModelRouter` 在登录时启动，并每 5 分钟自检一次。
- **手动启停**：`start-router.cmd` / `stop-router.cmd`。
- **日志**：`router.log`，每次请求一行 JSON（走哪条腿、模型、状态码、字节数、耗时、是否走代理）。
- **不要手动结束 `CodexModelRouter.exe`**：它是模型请求的唯一出口，杀掉会让 Codex 表现为
  "未登录 / 发不出消息"，直到计划任务把它拉回来。

## 配置项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ROUTER_PORT` | `8788` | HTTP 监听端口（兼容旧 provider）。 |
| `ROUTER_TLS_PORT` | `8789` | HTTPS 监听端口，`chatgpt_base_url` 指向它。 |
| `ROUTER_PROXY` | *(跟随系统代理)* | 设为 `none` 强制直连；设为 `host:port` 强制走指定代理。 |
| `ROUTER_UPSTREAM_TIMEOUT` | `900` | 上游超时（秒）。 |
| `browser-header-paths.txt` | `/backend-api/profiles/me` | 允许使用"浏览器风格请求头"的路径前缀。 |

## 设计取舍与已知问题

1. **Cloudflare 与资料类接口**：部分账号接口（`/backend-api/profiles/me`、`/settings/user` 等）
   会对"不像浏览器"的请求头返回 403。`browser-header-paths.txt` 列出允许使用浏览器风格请求头
   的路径；它每次请求都会重新读取，**改完立即生效，不用重启**。
2. **免费账号额度用尽**：如果放行**全部**账号接口，Codex 会读到"额度已用尽"并禁用发送键——
   哪怕你选的是 DeepSeek。所以默认只放行头像/资料接口；等额度恢复或升级后再清空。
3. **远程控制（手机 ↔ 桌面）**：隧道走 `chatgpt_base_url`，路由器支持服务端驱动的
   WebSocket 转发；该功能还依赖账号 MFA、套餐，以及客户端自带插件包的版本。
4. **改了 `router.py` 要重新打包**：跑 `build-exe.ps1` 再重启路由器；开发时也可以直接
   `python router.py`。

## 常见问题

| 现象 | 可能原因 / 处理 |
| --- | --- |
| Codex 什么都发不出去、像掉了登录 | 路由器没在跑。`start-router.cmd` 或 `schtasks /run /tn CodexModelRouter`。 |
| 只有 GPT 系模型失败 | 系统代理没开，或 ChatGPT 会话过期。看 `router.log`。 |
| 头像/资料页空白 | 把 `/backend-api/profiles/me` 加进 `browser-header-paths.txt`。 |
| 发送键变灰 | 有放行的接口暴露了"额度已用尽"。清空放行清单，或升级套餐。 |
| 端口被占用 | 已经有一个路由器实例在跑；8788/8789 只能被一个进程绑定。 |

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1             # 停止并删除计划任务
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveCert # 同时移除受信任证书
```

## 开发

- `router.py` —— 全部核心逻辑，纯标准库。
- `build-exe.ps1` —— PyInstaller 打包（含图标，输出 `CodexModelRouter.exe`）。
- `make-tls-cert.py` —— 生成 `tls/ca.crt`、`tls/server.crt`、`tls/server.key`。
  `tls/` 已被 git 忽略，**绝不要提交私钥**。
- 改动历史：[CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
