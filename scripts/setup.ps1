# One-command setup of LnnMusicBot on a Windows PC: installs Git, WSL 2 and Docker Desktop if needed, asks for the
# Discord bot token and YouTube API key (hidden input), builds and starts the bot, and sets it to start at sign-in.
# Safe to run again at any time; it skips whatever is already done and continues after a required restart.
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
#
# Must run in a terminal a person can see and type into: it asks for the keys and for consent to restart.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$self = $MyInvocation.MyCommand.Path
$runOnce = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Done($text) { Write-Host "    $text" -ForegroundColor Green }
function Note($text) { Write-Host "    $text" -ForegroundColor Yellow }

function Test-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Reboot or sign-out needed: come back to this script automatically after the next sign-in
function Stop-ForRestart($reason, [switch]$SignOutIsEnough) {
    Set-ItemProperty -Path $runOnce -Name 'LnnMusicBotSetup' -Value "powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$self`""
    Note $reason
    Note 'Setup continues by itself after you sign back in.'
    $what = if ($SignOutIsEnough) { 'Sign out now' } else { 'Restart now' }
    if ((Read-Host "    $what? [y/N]") -match '^[yY]') {
        if ($SignOutIsEnough) { shutdown.exe /l } else { Restart-Computer -Force }
    }
    exit 0
}

function Get-DockerInstallDir {
    @((Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop'), (Join-Path $env:ProgramFiles 'Docker\Docker')) |
        Where-Object { Test-Path (Join-Path $_ 'Docker Desktop.exe') } | Select-Object -First 1
}

function Test-DockerEngine {
    if (-not (Test-Command docker)) { return $false }
    docker info --format '{{.ServerVersion}}' *> $null
    return $LASTEXITCODE -eq 0
}

if ([Console]::IsInputRedirected) {
    throw 'Run this in an interactive terminal: it needs a person to paste the keys and approve restarts.'
}

Write-Host 'LnnMusicBot setup' -ForegroundColor Cyan
Write-Host "Repo: $repo"

# 1. Machine checks
Step 'Checking this PC'
$virtualization = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent -or
    (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
if (-not $virtualization) {
    throw 'Virtualization is turned off. Enable Intel VT-x / AMD SVM in the BIOS/UEFI settings, then run this again.'
}
if (-not (Test-Command winget)) {
    throw 'winget is missing. Install "App Installer" from the Microsoft Store, then run this again.'
}
Done 'Virtualization and winget OK'

# 2. Git (used for updates and to label builds)
Step 'Git'
if (Test-Command git) {
    Done (git --version)
} else {
    winget install -e --id Git.Git --source winget
    Update-Path
    Done 'Installed Git'
}

# 3. WSL 2 (Docker Desktop runs its engine there)
Step 'WSL 2'
wsl.exe --status *> $null
if ($LASTEXITCODE -eq 0) {
    Done 'WSL is installed'
} else {
    Note 'Installing WSL. Windows asks for administrator permission.'
    Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait
    Stop-ForRestart 'WSL was installed and Windows needs a restart to finish.'
}

# 4. Docker Desktop
Step 'Docker Desktop'
$dockerDir = Get-DockerInstallDir
if ($dockerDir) {
    Done "Installed at $dockerDir"
} else {
    Note 'Installing Docker Desktop. Windows asks for administrator permission; accept the prompts winget shows.'
    winget install -e --id Docker.DockerDesktop --source winget
    Stop-ForRestart 'Docker Desktop was installed. Windows needs you to sign out (or restart) to finish.' -SignOutIsEnough
}

# Docker's own "start at sign-in" must stay off: our sign-in task starts it after clearing files that crash it
function Disable-DockerAutoStart {
    foreach ($file in (Join-Path $env:APPDATA 'Docker\settings-store.json'), (Join-Path $env:APPDATA 'Docker\settings.json')) {
        if (-not (Test-Path $file)) { continue }
        $settings = Get-Content $file -Raw | ConvertFrom-Json
        if ($settings.AutoStart -ne $true) { continue }

        if (Test-DockerEngine) {
            docker desktop stop | Out-Null
        }
        $settings.AutoStart = $false
        [IO.File]::WriteAllText($file, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Done "Turned off Docker's own start-at-sign-in ($([IO.Path]::GetFileName($file)))"
    }
}

Step 'Starting Docker'
Disable-DockerAutoStart
Update-Path
if (-not (Test-DockerEngine)) {
    Start-Process -FilePath (Join-Path (Get-DockerInstallDir) 'Docker Desktop.exe')
    Note 'Waiting for Docker to start. First time: in the Docker window, accept the Docker Subscription Service'
    Note 'Agreement (free for personal use) and skip signing in.'
    $deadline = (Get-Date).AddMinutes(15)
    while (-not (Test-DockerEngine)) {
        if ((Get-Date) -gt $deadline) {
            throw 'Docker did not start within 15 minutes. Open Docker Desktop, fix what it shows, then run this again.'
        }
        Start-Sleep -Seconds 5
    }
}
Disable-DockerAutoStart
if (-not (Test-DockerEngine)) {
    Start-Process -FilePath (Join-Path (Get-DockerInstallDir) 'Docker Desktop.exe')
    while (-not (Test-DockerEngine)) { Start-Sleep -Seconds 5 }
}
Done "Docker engine $(docker info --format '{{.ServerVersion}}') is running"

# 5. Keys
Step 'Bot token and YouTube key'
$envFile = Join-Path $repo '.env'
$haveKeys = $false
if (Test-Path $envFile) {
    $text = [IO.File]::ReadAllText($envFile)
    $haveKeys = $text -match '(?m)^DISCORD_TOKEN=[\w-]+\.[\w-]+\.[\w-]+\s*$' -and $text -match '(?m)^YOUTUBE_API_KEY=AIza[\w-]{35}\s*$'
}
if ($haveKeys -and (Read-Host '    Keys are already saved. Enter new ones? [y/N]') -notmatch '^[yY]') {
    Done 'Keeping the saved keys'
} else {
    Note 'Paste the Discord bot token and the YouTube API key you were given.'
    Note 'Do NOT click "Reset Token" in the Discord Developer Portal: that logs out every other copy of the bot.'
    & (Join-Path $PSScriptRoot 'set-secrets.ps1')
}

# 6. Build and start the bot
Step 'Building and starting the bot (first build takes a few minutes)'
& (Join-Path $PSScriptRoot 'start-bot.ps1')

# 7. Start at sign-in
Step 'Start automatically at sign-in'
& (Join-Path $PSScriptRoot 'install-autostart.ps1')

# 8. Check
Step 'Checking everything'
Remove-ItemProperty -Path $runOnce -Name 'LnnMusicBotSetup' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 15
& (Join-Path $PSScriptRoot 'check-setup.ps1')
$failures = $LASTEXITCODE

$failover = docker logs lnn-music-bot 2>&1 | Select-String 'Failover' | Select-Object -Last 1
if ($failover) { Note "Failover: $($failover.Line.Trim())" }

if ($failures -eq 0) {
    Write-Host "`nAll set. The bot runs in Docker and starts by itself whenever you sign in." -ForegroundColor Green
} else {
    Write-Host "`nSetup finished with $failures problem(s) listed above. Fix them and run this script again." -ForegroundColor Red
}
