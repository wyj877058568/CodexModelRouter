# Codex 本地模型分流（DeepSeek + ChatGPT 原版）

## 它做什么

`router.py` 在本机 `127.0.0.1:8788` 上运行一个小服务。Codex 只连它一个服务商，
它按模型名把请求转发到正确的后端：

- `deepseek-*`（DeepSeek-Flash / DeepSeek-V4-Pro）→ `https://api.deepseek.com`，直连，
  用 config.toml 里 `[model_providers.deepseek]` 的密钥。
- 其它模型（GPT-6-Luna、GPT-5.6-Terra、GPT-5.6-Luna、GPT-5.5）→ ChatGPT 登录后端
  `https://chatgpt.com/backend-api/codex`，用 `~/.codex/auth.json` 里的登录令牌，
  并走系统代理（当前是 `127.0.0.1:10809`，每次请求实时读取注册表）。

令牌过期时路由器会自动刷新，并把新令牌写回 `auth.json`，不需要你重新登录。

这样模型选择器里就能同时看到两边的模型，点哪个就走哪边，不需要重启或改配置。

## 日常使用

- 开机自动启动：计划任务 `CodexModelRouter`（登录时启动，每 5 分钟自检一次；
  进程还活着时新的检查会自动跳过，进程挂了会自动拉起）。
- 手动启动：`start-router.cmd`
- 手动停止：`stop-router.cmd`
- 日志：`router.log`（每次请求一行：走哪条腿、模型、状态、耗时）
- 端口：8788，可通过环境变量 `ROUTER_PORT` 改。
- 代理：默认跟随系统代理；设 `ROUTER_PROXY=none` 可强制直连，
  设 `ROUTER_PROXY=127.0.0.1:10809` 可指定。

## 注意

- GPT 那几条模型依赖你的 ChatGPT 登录和可用的系统代理；如果代理/VPN 关了，
  GPT 模型会报错（DeepSeek 不受影响）。
- 路由器没在运行时，两条腿都不可用。先跑一次 `start-router.cmd`，
  或者执行 `schtasks /run /tn CodexModelRouter`。
- `config.toml` 里保留着 `[model_providers.deepseek]`，所以旧会话
  （它们记录的是 `deepseek` 服务商）仍然能正常工作。

## 如何还原

改动前的备份：

- `~\.codex\backup-deepseek\config.before-router.toml`
- `~\.codex\backup-deepseek\models.deepseek-only.json`

把这两个文件覆盖回 `~\.codex\config.toml` 和
`~\.codex\models.json`，再执行
`schtasks /delete /tn CodexModelRouter /f`，并结束 pythonw 进程，即回到
“只有 DeepSeek”的原始状态。

## 维护约定（重要，2026-10-03 补充）

### 现状

- `model_provider = "openai"` + `chatgpt_base_url = "https://127.0.0.1:8789/backend-api"`。
  模型分流、账号/用量显示都依赖这条路径，**不要轻易改**。
- 上游 HTTP 请求一律使用脚本自带的 Python 转发。**不要再把普通请求整体换成
  `curl.exe`**：2026-10-03 有过这样一版（留档 `router.py.paused`），每个请求都新起
  一个进程且没有隐藏窗口，结果黑窗频闪、客户端卡死。那版已停用，只作反面参考。

### 资料页 / 头像偶发 403 的真实原因（已实测）

- 现象：`/backend-api/profiles/me`、`/backend-api/settings/user`、
  `/backend-api/subscriptions/*` 返回 403（Cloudflare 挑战页），资料页停在骨架屏。
- 原因不是 TLS 指纹、也不是 DeepSeek 分流，而是**请求头太不像浏览器**。
  同一台机器、同一个令牌实测：

  | 请求头 | `/backend-api/profiles/me` |
  | --- | --- |
  | 现行最小头（Codex Desktop UA） | 403 |
  | 浏览器风格头（UA + accept-language + sec-ch-ua + sec-fetch-*） | **200** |

  连续 3 轮 × 5 个接口 = 15/15 全部 200，稳定。
- 结论：修它只需在 Python 转发里补上浏览器风格请求头（几行代码），
  **不需要 curl、不需要子进程、不需要重试风暴**；模型分流、WebSocket 透传、
  `chatgpt_base_url` 都不用动。
- 这个 403 与网络出口也有关（同样配置在家里的网络下头像正常），属于展示层小问题，
  要和“模型 / 账号主流程故障”分开判断。

### 改动流程（必须遵守）

1. 先备份当前可用文件（`router.py`、`config.toml` 各留一份带时间戳副本）。
2. 说清楚动哪些文件、可能副作用、怎么回滚，得到确认后再改。
3. 每次只做小改动；改完实际验证三件事：模型切换（DeepSeek ↔ GPT）、用量显示、客户端登录。
4. 出问题先看 `router.log`（每条带路径）和 `~/.codex/logs_2.sqlite`（app-server 日志），
   先分清是展示层接口 403 还是主流程故障。

### 可用状态快照

2026-10-03 的可用状态快照（含 `router.py`、`router.py.paused`、`config.toml`、
`models.json`、证书、计划任务定义、启动/停止脚本）：

- `~\Documents\Codex\codex-router-backup-20261003\`
- 注意：副本里的 `config.toml` 含明文 DeepSeek key，不要外传。

## 2026-10-03 头像 / 资料页修复（已应用并验证）

### 改了什么

只改 `router.py` 的 **HTTP GET 请求头**（模型分流、WebSocket 透传、`config.toml`、
证书、计划任务一律未动）：

1. 新增常量 `BROWSER_USER_AGENT` 与函数 `browser_headers(token, account_id)`
   （浏览器风格 UA + `accept-language` + `sec-ch-ua` + `sec-fetch-*`）。
2. `do_GET` 由原来的 4 行最小请求头改为调用 `browser_headers(...)`。

没有引入 `curl`、子进程或 403 重试循环。

### 验证结果

| 项目 | 结果 |
| --- | --- |
| 5 个接口 × 3 轮（`profiles/me`、`settings/user`、`subscriptions/*`、`wham/usage`、`accounts/check`） | 15/15 全部 200 |
| DeepSeek 真实请求（走 8789） | 200，`response.created` → `response.completed` |
| 账号 / 用量面板数据源 | 200（登录状态未变） |
| 用户确认 | 个人资料 / 头像页正常显示 |

### 回滚

```powershell
Copy-Item '~\.codex\router\router.py.bak-20261003-175958' '~\.codex\router\router.py' -Force
```

复制后结束 pythonw 进程并跑 `start-router.cmd` 重启路由器。
同一份旧文件也留存在 `~\Documents\Codex\codex-router-backup-20261003\router.py.before-header-fix`。

### 备注

- 本次重启路由器是在沙箱里手动完成的：当时 `schtasks` 在这个受限环境里连只读查询都报
  “找不到路径”，`stop-router.cmd` 也没跑起来。计划任务定义本身正常（指向存在的
  `pythonw.exe` 和 `router.py`），在正常桌面环境里应可照常使用。
- 浏览器扩展 / native host 缺失属于另一条线，与本次改动无关。

## 2026-10-04 打包成独立 exe（已应用并验证）

### 现状

- 路由器现在是一个独立可执行文件：`~\.codex\router\CodexModelRouter.exe`
  （PyInstaller onefile，约 8 MB，带自定义图标）。任务管理器里显示为
  **CodexModelRouter.exe**，不再是裸的 `pythonw.exe`。
- 计划任务 `CodexModelRouter` 的动作已改为该 exe（登录时启动 + 每 5 分钟自检）。
- `router.py` 增加了 `BASE_DIR`：打包运行时以"exe 所在目录"为基准解析
  `router.log`、`tls/`、`browser-header-paths.txt`；用 Python 直接跑时行为不变。
- 进程管理器里会看到**两个** CodexModelRouter.exe：父进程是 PyInstaller 的引导器，
  子进程才是真正在监听 8788 / 8789 的实体。这是 onefile 模式的正常现象。

### 验证结果

| 项目 | 结果 |
| --- | --- |
| 备用端口试跑（8798 / 8799） | HTTP + HTTPS 均监听，证书校验通过 |
| `/backend-api/profiles/me`（放行清单） | 200（头像 / 个人资料正常） |
| `/backend-api/settings/user`（未放行） | 403（保持最小改动） |
| `/backend-api/wham/usage` | 200（用量面板正常） |
| DeepSeek 真实请求（走 8789） | 200，`response.completed`，回答 OK |
| Windows Defender | 无告警（`Get-MpThreatDetection` 为空） |

### 防火墙 / 证书说明

- 路由器只绑定 `127.0.0.1`（回环地址），**流量不经过 Windows 防火墙**，
  因此不需要（也没有）任何防火墙放行规则。
- HTTPS 用的是本地自签 CA（`tls/ca.crt`，已装入"当前用户 → 受信任的根证书颁发机构"）。
  exe 与 python 版本共用同一份证书，已验证握手正常。
- 未做任何需要管理员权限的改动（当前会话不是管理员）。

### 以后改了代码要重新打包

```powershell
powershell -ExecutionPolicy Bypass -File ~\.codex\router\build-exe.ps1
```

打包脚本会自动覆盖 `CodexModelRouter.exe`；之后重启路由器即可生效。
（也可以临时用 Python 直接跑：`python.exe router.py`，两条路都支持。）

### 回滚到 pythonw 版本

任务定义备份：`~\.codex\router\task.backup-20261004.xml`

```powershell
schtasks /change /tn CodexModelRouter /tr "`"~\AppData\Local\Programs\Python\Python311\pythonw.exe`" `"~\.codex\router\router.py`""
```

`router.py` 的打包前备份：`router.py.bak-20261004-031231`。
