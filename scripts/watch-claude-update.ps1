# watch-claude-update.ps1
# Claude Desktop 中文补丁更新守护脚本
# 定期检测 Claude 是否更新，自动重新应用补丁

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$dataDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "ClaudeDesktopZhCn" } else { exit 0 }
$versionFile = Join-Path $dataDir "patched-version.json"
$logFile = Join-Path $dataDir "update-watcher.log"

function Write-WatcherLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    try {
        Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {}
}

function Get-CurrentClaudeVersion {
    $packages = @(Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue)
    foreach ($package in $packages) {
        if ($package.Version) {
            return [string]$package.Version
        }
    }

    $unpackagedBase = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "AnthropicClaude"
    if (Test-Path $unpackagedBase) {
        $latest = Get-ChildItem $unpackagedBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest -and $latest.Name -match '^app-(.+)$') {
            return $Matches[1]
        }
    }
    return $null
}

function Test-ResourcesPathExists {
    param([string]$InstallPath)

    $candidates = @(
        (Join-Path $InstallPath "resources"),
        (Join-Path $InstallPath "app\resources")
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

# --- 主逻辑 ---

# 读取已记录的补丁版本信息
if (-not (Test-Path $versionFile)) { exit 0 }

try {
    $recorded = Get-Content $versionFile -Raw -ErrorAction Stop | ConvertFrom-Json
}
catch {
    exit 0
}

if (-not $recorded.version -or -not $recorded.patchMode -or -not $recorded.language) {
    exit 0
}

# 获取当前 Claude 版本
$currentVersion = Get-CurrentClaudeVersion
if (-not $currentVersion) { exit 0 }

# 版本一致，无需操作
if ($currentVersion -eq $recorded.version) { exit 0 }

Write-WatcherLog "检测到 Claude 更新: $($recorded.version) -> $currentVersion"

# 等待 30 秒，让 Windows Store 更新完成
Start-Sleep -Seconds 30

# 查找安装目录
$installPath = $null
$packages = @(Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue)
foreach ($package in $packages) {
    if ($package.InstallLocation -and (Test-Path $package.InstallLocation)) {
        $installPath = $package.InstallLocation
        break
    }
}

if (-not $installPath) {
    $unpackagedBase = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "AnthropicClaude"
    if (Test-Path $unpackagedBase) {
        $latest = Get-ChildItem $unpackagedBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) { $installPath = $latest.FullName }
    }
}

if (-not $installPath) {
    Write-WatcherLog "未找到 Claude 安装目录，跳过"
    exit 0
}

# 验证 resources 路径
if (-not (Test-ResourcesPathExists $installPath)) {
    Write-WatcherLog "resources 路径不存在: $installPath，等待下次检查"
    exit 0
}

# 创建一次性管理员计划任务来重新应用补丁
$patcherScript = Join-Path $PSScriptRoot "install_windows.ps1"
if (-not (Test-Path $patcherScript)) {
    Write-WatcherLog "未找到 install_windows.ps1: $patcherScript"
    exit 0
}

$taskName = "ClaudeDesktopZhCn-ReapplyPatch"
$stdoutLog = Join-Path $dataDir "reapply-stdout.log"
$stderrLog = Join-Path $dataDir "reapply-stderr.log"

try {
    # 清理旧的一次性任务
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$patcherScript`" -PatchMode `"$($recorded.patchMode)`" -Language `"$($recorded.language)`" -Action install"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argumentList
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter (New-TimeSpan -Hours 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description "Claude Desktop 中文补丁重新应用（一次性）" `
        -RunLevel Highest `
        -Force | Out-Null

    Write-WatcherLog "已触发补丁重新应用任务: $taskName"

    # 等待任务完成（最多 5 分钟）
    $deadline = (Get-Date).AddMinutes(5)
    $completed = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            $completed = $true
            break
        }
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($info -and $info.LastRunTime -gt [datetime]::MinValue) {
            $completed = $true
            break
        }
    }

    if ($completed) {
        Write-WatcherLog "补丁重新应用完成"
    } else {
        Write-WatcherLog "补丁重新应用任务超时"
    }

    # 清理一次性任务
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-WatcherLog "触发补丁重新应用失败: $($_.Exception.Message)"
    exit 1
}

exit 0
