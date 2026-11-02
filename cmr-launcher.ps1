#Requires -Version 5.1
<#
.SYNOPSIS
  CodexModelRouter launcher: one window to pick account + mode, apply, and (re)start ChatGPT.
#>
param(
  [switch]$NoGui,
  [ValidateSet("router", "native")]
  [string]$ApplyMode,
  [switch]$NoRestart
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root       = $PSScriptRoot
$SwitchTool = Join-Path $Root "switch-mode.ps1"
$CodexHome  = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$AuthPath   = Join-Path $CodexHome "auth.json"
$ConfigPath = Join-Path $CodexHome "config.toml"

function Get-CodexExe {
  $bin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
  if (Test-Path $bin) {
    $exe = Get-ChildItem $bin -Recurse -Filter "codex.exe" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exe) { return $exe.FullName }
  }
  return $null
}

function Get-AppActivationId {
  $proc = Get-Process ChatGPT -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc -and $proc.Path -match "WindowsApps\\(OpenAI\.Codex_[^\\]+)\\") {
    $parts = $matches[1].Split("_")
    return "shell:AppsFolder\$($parts[0])_$($parts[-1])!App"
  }
  return "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
}

function Get-Account {
  if (-not (Test-Path -LiteralPath $AuthPath)) { return $null }
  try {
    $auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json
    $token = $auth.tokens.id_token
    if (-not $token) { return $null }
    $payload = $token.Split(".")[1].Replace("-", "+").Replace("_", "/")
    while ($payload.Length % 4) { $payload += "=" }
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $claim = $json.'https://api.openai.com/auth'
    $plan = if ($claim) { $claim.chatgpt_plan_type } else { "?" }
    return [pscustomobject]@{
      Email     = $json.email
      Plan      = $plan
      AccountId = $auth.tokens.account_id
    }
  } catch { return $null }
}

function Get-CurrentMode {
  $lines = Get-Content -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
  $line = $lines | Where-Object { $_ -match "^\s*chatgpt_base_url\s*=" } | Select-Object -First 1
  if (-not $line) { return "native" }
  if ($line -match "127\.0\.0\.1:8789") { return "router" }
  return "custom"
}

function Get-RouterState {
  $proc = Get-Process CodexModelRouter -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
  if (-not $proc) { return "未运行" }
  $listening = (netstat -ano | Select-String -Pattern ":8789\s+.*LISTENING") -ne $null
  return "运行中（pid $($proc.Id)，8789 监听=$listening）"
}

function Invoke-SwitchMode([string]$mode) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SwitchTool -Mode $mode | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "switch-mode.ps1 failed (exit $LASTEXITCODE)" }
}

function Ensure-Router {
  $mode = Get-CurrentMode
  if ($mode -ne "router") { return }
  $proc = Get-Process CodexModelRouter -ErrorAction SilentlyContinue
  $listening = (netstat -ano | Select-String -Pattern ":8789\s+.*LISTENING") -ne $null
  if ($proc -and $listening) { return }
  schtasks /run /tn CodexModelRouter 2>$null | Out-Null
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $listening = (netstat -ano | Select-String -Pattern ":8789\s+.*LISTENING") -ne $null
    if ($listening) { return }
  }
  throw "路由器没有启动（8789 未监听）。请运行 start-router.cmd 或检查计划任务。"
}

function Restart-ChatGpt {
  $activation = Get-AppActivationId
  Get-Process ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Ensure-Router
  Start-Process $activation
}

if ($NoGui) {
  if ($ApplyMode) { Invoke-SwitchMode $ApplyMode }
  if ($ApplyMode -and -not $NoRestart) { Restart-ChatGpt }
  return
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "CodexModelRouter · Codex 启动器"
$form.Size = New-Object System.Drawing.Size(780, 650)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "CodexModelRouter"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 17, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 16)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "一个入口：账号 + 模式 → 应用并启动 ChatGPT"
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(26, 56)
$form.Controls.Add($subtitle)

$statusBox = New-Object System.Windows.Forms.GroupBox
$statusBox.Text = "当前状态"
$statusBox.Location = New-Object System.Drawing.Point(24, 86)
$statusBox.Size = New-Object System.Drawing.Size(712, 130)
$form.Controls.Add($statusBox)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(16, 22)
$statusLabel.Size = New-Object System.Drawing.Size(560, 96)
$statusLabel.Font = New-Object System.Drawing.Font("Consolas", 9)
$statusBox.Controls.Add($statusLabel)

$loginButton = New-Object System.Windows.Forms.Button
$loginButton.Text = "登录 / 切换账号…"
$loginButton.Location = New-Object System.Drawing.Point(584, 34)
$loginButton.Size = New-Object System.Drawing.Size(112, 30)
$statusBox.Controls.Add($loginButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "刷新"
$refreshButton.Location = New-Object System.Drawing.Point(584, 72)
$refreshButton.Size = New-Object System.Drawing.Size(112, 26)
$statusBox.Controls.Add($refreshButton)

$modeBox = New-Object System.Windows.Forms.GroupBox
$modeBox.Text = "模式"
$modeBox.Location = New-Object System.Drawing.Point(24, 226)
$modeBox.Size = New-Object System.Drawing.Size(712, 92)
$form.Controls.Add($modeBox)

$radioRouter = New-Object System.Windows.Forms.RadioButton
$radioRouter.Text = "双模型（router）— DeepSeek + GPT，共用一个下拉框"
$radioRouter.Location = New-Object System.Drawing.Point(18, 24)
$radioRouter.AutoSize = $true
$modeBox.Controls.Add($radioRouter)

$radioNative = New-Object System.Windows.Forms.RadioButton
$radioNative.Text = "官方直连（native）— 只走 ChatGPT，仅 GPT 模型"
$radioNative.Location = New-Object System.Drawing.Point(18, 54)
$radioNative.AutoSize = $true
$modeBox.Controls.Add($radioNative)

$descBox = New-Object System.Windows.Forms.TextBox
$descBox.Multiline = $true
$descBox.ReadOnly = $true
$descBox.ScrollBars = "Vertical"
$descBox.Location = New-Object System.Drawing.Point(24, 330)
$descBox.Size = New-Object System.Drawing.Size(712, 132)
$descBox.BackColor = [System.Drawing.Color]::White
$descBox.BorderStyle = "FixedSingle"
$form.Controls.Add($descBox)

$warn = New-Object System.Windows.Forms.Label
$warn.Text = "应用会关闭并重新启动 ChatGPT 客户端（当前对话窗口也会关闭）。"
$warn.ForeColor = [System.Drawing.Color]::FromArgb(200, 90, 0)
$warn.AutoSize = $true
$warn.Location = New-Object System.Drawing.Point(26, 474)
$form.Controls.Add($warn)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = "应用并启动 ChatGPT"
$applyButton.Location = New-Object System.Drawing.Point(466, 506)
$applyButton.Size = New-Object System.Drawing.Size(196, 40)
$applyButton.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($applyButton)

$applyOnlyButton = New-Object System.Windows.Forms.Button
$applyOnlyButton.Text = "仅应用配置"
$applyOnlyButton.Location = New-Object System.Drawing.Point(330, 506)
$applyOnlyButton.Size = New-Object System.Drawing.Size(126, 40)
$form.Controls.Add($applyOnlyButton)

$launchButton = New-Object System.Windows.Forms.Button
$launchButton.Text = "仅启动 ChatGPT"
$launchButton.Location = New-Object System.Drawing.Point(188, 506)
$launchButton.Size = New-Object System.Drawing.Size(126, 40)
$form.Controls.Add($launchButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "取消"
$cancelButton.Location = New-Object System.Drawing.Point(668, 506)
$cancelButton.Size = New-Object System.Drawing.Size(68, 40)
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancelButton)
$form.CancelButton = $cancelButton

function Get-Description([bool]$routerMode) {
  $acct = Get-Account
  $who = if ($acct) { "$($acct.Email) ($($acct.Plan))" } else { "未登录" }
  if ($routerMode) {
    $body = @'
 【双模型 router】
 Codex 通过本地路由器 127.0.0.1:8789 分流：
   · deepseek-*  -> DeepSeek API（config.toml 里的 DeepSeek key）
   · 其它模型     -> ChatGPT 登录后端（当前账号的令牌）

 适合：需要 DeepSeek，或想在一个下拉框里同时看到两家模型。
 代价：多一层本地代理；资料类接口依赖 browser-header-paths.txt 的放行规则。
 注意：路由器必须常驻，不要手动结束 CodexModelRouter.exe。
'@
  } else {
    $body = @'
 【官方直连 native】
 关闭本地路由器，Codex 直接连接 ChatGPT 官方后端：
   · 只有 GPT 模型（DeepSeek 会从下拉框消失）
   · 少一层代理，最接近官方原始状态

 适合：企业 / Business 账号、额度充足、主要使用 GPT 时。
 代价：需要 DeepSeek 时要切回 router 并重启客户端。
'@
  }
  $tail = "`r`n当前登录账号：$who`r`n切换账号：点「登录 / 切换账号…」，完成后再点「应用并启动」。"
  return ($body + $tail)
}

function Update-View {
  $acct = Get-Account
  $mode = Get-CurrentMode
  $lines = @(
    ("账号      : " + $(if ($acct) { $acct.Email } else { "（未登录）" })),
    ("套餐      : " + $(if ($acct) { $acct.Plan } else { "-" })),
    ("工作空间  : " + $(if ($acct -and $acct.AccountId) { $acct.AccountId } else { "-" })),
    ("当前模式  : $mode"),
    ("路由器    : " + (Get-RouterState))
  )
  $statusLabel.Text = ($lines -join "`r`n")
  if ($mode -eq "router") { $radioRouter.Checked = $true } else { $radioNative.Checked = $true }
  $descBox.Text = Get-Description $radioRouter.Checked
}

$refreshButton.Add_Click({ Update-View })
$radioRouter.Add_CheckedChanged({ if ($radioRouter.Checked) { $descBox.Text = Get-Description $true } })
$radioNative.Add_CheckedChanged({ if ($radioNative.Checked) { $descBox.Text = Get-Description $false } })

$loginButton.Add_Click({
  $codex = Get-CodexExe
  if (-not $codex) {
    [System.Windows.Forms.MessageBox]::Show("找不到 codex.exe，请先在 Codex 客户端里登录。", "提示")
    return
  }
  $msg = @'
 即将打开浏览器进行登录。

 · 用你想要的账号登录（公司账号请在浏览器里选择对应的工作空间）
 · 完成后关闭登录窗口，回到本窗口点「刷新」

 登录会替换 ~/.codex/auth.json 里的凭据；现有 ChatGPT 会话需要重启后才会切换。
'@
  $answer = [System.Windows.Forms.MessageBox]::Show($msg, "登录 / 切换账号", "OKCancel", "Information")
  if ($answer -ne "OK") { return }
  Start-Process -FilePath $codex -ArgumentList "login"
})

$applyButton.Add_Click({
  $targetMode = if ($radioRouter.Checked) { "router" } else { "native" }
  try {
    $applyButton.Enabled = $false
    Invoke-SwitchMode $targetMode
    Restart-ChatGpt
    $form.Close()
  } catch {
    [System.Windows.Forms.MessageBox]::Show("应用失败：$($_.Exception.Message)", "错误", "OK", "Error")
    $applyButton.Enabled = $true
  }
})

$applyOnlyButton.Add_Click({
  $targetMode = if ($radioRouter.Checked) { "router" } else { "native" }
  try {
    Invoke-SwitchMode $targetMode
    Update-View
    [System.Windows.Forms.MessageBox]::Show("配置已应用。请手动重启 Codex 客户端使配置生效。", "完成")
  } catch {
    [System.Windows.Forms.MessageBox]::Show("应用失败：$($_.Exception.Message)", "错误", "OK", "Error")
  }
})

$launchButton.Add_Click({
  try {
    $launchButton.Enabled = $false
    Ensure-Router
    Start-Process (Get-AppActivationId)
    $form.Close()
  } catch {
    [System.Windows.Forms.MessageBox]::Show("启动失败：$($_.Exception.Message)", "错误", "OK", "Error")
    $launchButton.Enabled = $true
  }
})

Update-View
[void]$form.ShowDialog()
