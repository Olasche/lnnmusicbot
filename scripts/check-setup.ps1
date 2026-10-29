# Read-only check of every setup step on this machine. Prints [ OK ] / [FAIL] / [WARN] per item and never prints
# secret values. Exit code is the number of FAIL items (0 = fully set up).
#   powershell -ExecutionPolicy Bypass -File scripts\check-setup.ps1
$repo = Split-Path -Parent $PSScriptRoot
$taskName = 'LnnMusicBot - Docker autostart'
$container = 'lnn-music-bot'
$failures = 0
$env:WSL_UTF8 = '1'

function Report($status, $item, $detail = '') {
    $color = @{OK = 'Green'; FAIL = 'Red'; WARN = 'Yellow'}[$status]
    Write-Host ('[{0,4}] {1}{2}' -f $status, $item, $(if ($detail) { " - $detail" } else { '' })) -ForegroundColor $color
    if ($status -eq 'FAIL') { $script:failures++ }
}

function Check($item, [scriptblock]$test, $failDetail, $status = 'FAIL') {
    $result = try { & $test } catch { $null }
    if ($result) { Report 'OK' $item "$result" } else { Report $status $item $failDetail }
}

# --- Machine prerequisites
$os = Get-CimInstance Win32_OperatingSystem
Report 'OK' 'Windows' "$($os.Caption) build $($os.BuildNumber)"
Check 'Virtualization' {
    if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) { 'hypervisor running' }
    elseif ((Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled) { 'enabled in firmware' }
} 'not enabled - turn on Intel VT-x / AMD SVM in BIOS/UEFI'
Check 'winget' { if (Get-Command winget -ErrorAction SilentlyContinue) { (winget --version) } } 'missing - install "App Installer" from the Microsoft Store' 'WARN'
Check 'Git' { if (Get-Command git -ErrorAction SilentlyContinue) { (git --version) } } 'missing - winget install -e --id Git.Git'
Check 'WSL' { wsl.exe --status *> $null; if ($LASTEXITCODE -eq 0) { (wsl.exe --version | Select-Object -First 1) } } 'missing - wsl --install --no-distribution (admin, then reboot)'

# --- Docker Desktop
$installDir = @((Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop'), (Join-Path $env:ProgramFiles 'Docker\Docker')) |
    Where-Object { Test-Path (Join-Path $_ 'Docker Desktop.exe') } | Select-Object -First 1
Check 'Docker Desktop installed' { $installDir } 'missing - winget install -e --id Docker.DockerDesktop'
Check 'Docker engine running' { docker info --format '{{.ServerVersion}}' 2>$null } 'not reachable - start Docker Desktop (and accept its agreement on first run)'
$settingsFile = Join-Path $env:APPDATA 'Docker\settings-store.json'
Check "Docker's own autostart off" {
    $auto = if (Test-Path $settingsFile) { (Get-Content $settingsFile -Raw | ConvertFrom-Json).AutoStart } else { $false }
    if (-not $auto) { 'AutoStart=false' }
} 'Docker Settings > General > untick "Start Docker Desktop when you sign in"'
Check 'Docker Run entry removed' {
    if (-not (Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run).'Docker Desktop') { 'absent' }
} 'run scripts\install-autostart.ps1'

# --- Repo and secrets
Check 'Repo' { if (Test-Path (Join-Path $repo '.git')) { "$repo @ $(git -C $repo rev-parse --short HEAD)" } } 'not a git checkout'
$envFile = Join-Path $repo '.env'
$envValues = @{}
if (Test-Path $envFile) {
    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        if ($line -match '^([A-Z_]+)=(.*)$') { $envValues[$Matches[1]] = $Matches[2].Trim() }
    }
}
Check '.env present' { if (Test-Path $envFile) { 'found' } } 'run scripts\set-secrets.ps1'
Check 'DISCORD_TOKEN set' { if ($envValues.DISCORD_TOKEN -match '^[\w-]+\.[\w-]+\.[\w-]+$') { "$($envValues.DISCORD_TOKEN.Length) chars" } } 'empty or malformed - run scripts\set-secrets.ps1'
Check 'YOUTUBE_API_KEY set' { if ($envValues.YOUTUBE_API_KEY -match '^AIza[\w-]{35}$') { '39 chars' } } 'empty or malformed - run scripts\set-secrets.ps1'
Check 'CHECKPOINT_DISABLE=1' { if ($envValues.CHECKPOINT_DISABLE -eq '1') { 'set' } } 'add CHECKPOINT_DISABLE=1 to .env (stops Prisma usage pings)'
Check 'DATA_DIR not set in .env' { if (-not $envValues.ContainsKey('DATA_DIR')) { 'ok' } } 'remove DATA_DIR from .env - in Docker it must stay /data'

# --- Bot container
Check 'Bot image built' { docker image inspect lnn-music-bot:latest --format '{{.Created}}' 2>$null } 'run scripts\start-bot.ps1'
Check 'Bot container running' { $s = docker inspect $container --format '{{.State.Status}} (restart: {{.HostConfig.RestartPolicy.Name}})' 2>$null; if ($s -like 'running*') { $s } } 'run scripts\start-bot.ps1'
$botLog = @(docker logs $container 2>&1 | ForEach-Object { "$_" })
$failoverLine = $botLog | Where-Object { $_ -match '^Failover' } | Select-Object -Last 1
Check 'Bot connected to Discord' {
    if ($botLog -match 'Ready!') { 'Ready! in log' }
    elseif ($failoverLine -and $failoverLine -notmatch 'is now the active install') { 'standby: another install is active (see #bots-internal)' }
} 'check: docker logs lnn-music-bot'
Check 'Failover' {
    if (-not $failoverLine) { 'not reported yet' }
    elseif ($failoverLine -match '^Failover off') { 'off: no #bots-internal channel, running as the only install' }
    else { $failoverLine -replace '^Failover:?\s*', '' }
} '' 'WARN'

# --- Autostart task
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Check 'Autostart task registered' { if ($task) { "state $($task.State)" } } 'run scripts\install-autostart.ps1'
Check 'Autostart task points at this repo' {
    if ($task -and $task.Actions[0].Arguments -like "*$(Join-Path $repo 'scripts\docker-autostart.ps1')*") { 'yes' }
} 'rerun scripts\install-autostart.ps1 from this checkout'
Check 'Last autostart run' {
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
    if ($info.LastTaskResult -eq 0) { "$($info.LastRunTime) result 0" }
} 'not run yet or failed - Start-ScheduledTask -TaskName ''LnnMusicBot - Docker autostart''' 'WARN'
$stale = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Docker\run') -Force -Filter '*.stale' -ErrorAction SilentlyContinue)
Check 'No stale Docker socket files' { if ($stale.Count -eq 0) { 'none' } } "$($stale.Count) present - the autostart task removes them; see AGENTS.md" 'WARN'

Write-Host ''
if ($failures -eq 0) { Write-Host 'All required checks passed.' -ForegroundColor Green } else { Write-Host "$failures required check(s) failed." -ForegroundColor Red }
exit $failures
