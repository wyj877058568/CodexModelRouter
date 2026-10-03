# CodexModelRouter

让 **Codex 桌面版（ChatGPT 客户端）在一个模型下拉框里同时使用 DeepSeek 和 ChatGPT 登录模型**的本地分流器。

## 为什么需要它

Codex 的模型选择器只切换「模型名」，而 provider（后端）是全局配置；ChatGPT 登录模式走的又是
`chatgpt.com/backend-api/codex` 这套协议（Responses + WebSocket），不是标准 OpenAI API，
所以通用网关（LiteLLM、one-api 之类）接不了。

本项目在本地起一个 HTTPS 服务，把 Codex 的 `chatgpt_base_url` 指向它，再按模型名分流：

| 请求的模型 | 实际去向 |
| --- | --- |
| `deepseek-*`（DeepSeek-Flash / DeepSeek-V4-Pro） | `https://api.deepseek.com`，用 config.toml 里的 DeepSeek key |
| 其它（GPT-6-Luna、GPT-5.6-* 等） | ChatGPT 登录后端，用 `~/.codex/auth.json` 里的令牌（可选走系统代理） |

顺带的好处：因为 provider 仍是内置的 `openai`，客户端的**头像、个人资料、用量面板**都能正常显示。

## 架构

```
Codex 客户端
   |  chatgpt_base_url = https://127.0.0.1:8789/backend-api
   v
CodexModelRouter.exe  -- deepseek-*  -> api.deepseek.com
   |  (8789 HTTPS / 8788 HTTP)
   +-- 其它模型 / 账号接口 -> chatgpt.com（HTTP + WebSocket 透传）
```

- **8789 HTTPS**：给 `chatgpt_base_url` 用，证书是本机自签 CA（`tls/`，需装入「当前用户 → 受信任的根证书颁发机构」）。
- **8788 HTTP**：兼容早期「自定义 provider」形态的会话。
- ChatGPT 令牌过期时自动刷新，并写回 `~/.codex/auth.json`。
- WebSocket 双向透传（模型请求 + 远程控制隧道）；DeepSeek 侧做 WS -> SSE 桥接。
- 纯 Python 标准库，单文件 `router.py`。

## 快速开始

要求：Windows、已安装并登录 ChatGPT/Codex 桌面版、Python 3.11（生成证书 / 打包用）、DeepSeek API key。

```powershell
# 一键安装（生成证书 -> 信任证书 -> 打包 exe -> 注册开机自启任务 -> 启动）
powershell -ExecutionPolicy Bypass -File install.ps1
```

然后按 `install.ps1` 结尾打印的提示修改 `~/.codex/config.toml`（关键是这两行）：

```toml
model_provider = "openai"
chatgpt_base_url = "https://127.0.0.1:8789/backend-api"
```

并保证 `~/.codex/models.json`（模型目录）里同时包含 DeepSeek 与 ChatGPT 的模型。最后重启 Codex 客户端即可。

## 日常使用

- **开机自启**：计划任务 `CodexModelRouter`（登录时启动 + 每 5 分钟自检）。
- **手动启停**：`start-router.cmd` / `stop-router.cmd`。
- **日志**：`router.log`（每行一条：走哪条腿、模型、状态码、耗时、是否走代理）。
- **不要手动结束 `CodexModelRouter.exe`**：它是模型请求的唯一出口，杀掉等于让 Codex 断网
  （表现为登录不上、发不出消息）。计划任务会在 5 分钟内自动把它拉回来。

## 已知问题与设计取舍

1. **头像 / 个人资料接口偶发 403**
   Cloudflare 会对「不太像浏览器」的请求头返回挑战页。用 `browser-header-paths.txt` 按路径放行
   指定接口（默认只放行 `/backend-api/profiles/me`）。改这个文件**立即生效，无需重启**。
2. **免费账号额度用尽时会禁用发送键**
   如果放行全部接口，Codex 会读到「Codex 额度已用尽」，于是把发送按钮置灰——哪怕你用的是 DeepSeek。
   因此默认只放行头像接口。等额度恢复或升级后，可以把放行清单清空。
3. **远程控制（手机连接）**
   隧道走 `chatgpt_base_url`，本项目已支持服务端驱动的 WebSocket 转发；但该功能还受账号 MFA、
   套餐、以及客户端自带插件包版本影响。
4. **打包后改代码需要重新打包**：`build-exe.ps1` 一键重建；也可以直接用 `python router.py` 跑。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1             # 停止 + 删除计划任务
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveCert # 同时移除受信任证书
```

## 开发

- `router.py`：唯一的核心代码，纯标准库。
- `build-exe.ps1`：PyInstaller 打包成 `CodexModelRouter.exe`（带图标）。
- `make-tls-cert.py`：生成本地 CA 与服务器证书（仅本机使用，不要提交 `tls/`）。
- 改动历史见 [CHANGELOG.md](CHANGELOG.md)。

## License

MIT，见 [LICENSE](LICENSE)。
