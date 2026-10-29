# Runs at Windows sign-in (scheduled task "LnnMusicBot - Docker autostart") and starts Docker Desktop;
# the bot container (restart policy unless-stopped) comes back up on its own once Docker is running.
#
# Works around a Docker Desktop startup crash: a leftover socket placeholder in Docker\run (*.stale)
# makes the backend fail with "rename ...\sailor-ingest.sock ...\sailor-ingest.sock.stale: The file
# cannot be accessed by the system". Windows can't delete these AF_UNIX socket files; WSL can.
# See AGENTS.md (Autostart).
$repo = Split-Path -Parent $PSScriptRoot
$run = Join-Path $env:LOCALAPPDATA 'Docker\run'
$log = Join-Path $repo 'autostart.log'

function Write-Log($message) {
    "$(Get-Date -Format s) $message" | Add-Content -Path $log
}

# Docker Desktop is either a per-user install (LOCALAPPDATA) or the standard machine-wide one (Program Files)
$installDir = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop'),
    (Join-Path $env:ProgramFiles 'Docker\Docker')
) | Where-Object { Test-Path (Join-Path $_ 'Docker Desktop.exe') } | Select-Object -First 1

if (-not $installDir) {
    Write-Log 'Docker Desktop is not installed'
    exit 1
}

$dockerDesktop = Join-Path $installDir 'Docker Desktop.exe'
$docker = Join-Path $installDir 'resources\bin\docker.exe'

function Get-StaleSockets {
    Get-ChildItem -Path $run -Force -Filter '*.stale' -ErrorAction SilentlyContinue
}

function Remove-StaleSockets {
    foreach ($file in Get-StaleSockets) {
        # C:\Users\... -> /mnt/host/c/Users/... inside the docker-desktop WSL distro
        $wslPath = '/mnt/host/' + $file.FullName.Substring(0, 1).ToLower() + ($file.FullName.Substring(2) -replace '\\', '/')
        wsl.exe -d docker-desktop -e rm -f $wslPath | Out-Null
        Write-Log "removed $($file.Name)"
    }
}

if (-not (Get-Process -Name 'com.docker.backend' -ErrorAction SilentlyContinue)) {
    if (Get-StaleSockets) {
        Remove-StaleSockets
    }

    Write-Log 'starting Docker Desktop'
    Start-Process -FilePath $dockerDesktop
}

# Wait up to 5 minutes for the engine, then clear the placeholder this start left behind
for ($i = 0; $i -lt 60; $i++) {
    & $docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -eq 0) {
        break
    }

    Start-Sleep -Seconds 5
}

if ($LASTEXITCODE -ne 0) {
    Write-Log 'Docker engine did not come up within 5 minutes'
    exit 1
}

Remove-StaleSockets
Write-Log "Docker is up; bot container is $(& $docker inspect lnn-music-bot --format '{{.State.Status}}' 2>$null)"
