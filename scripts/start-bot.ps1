# Builds the bot image from this repo and (re)starts the container in Docker Desktop.
# Run again after changing the code, or whenever YouTube playback breaks: it rebuilds with the newest yt-dlp.
#   powershell -ExecutionPolicy Bypass -File scripts\start-bot.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$image = 'lnn-music-bot:latest'
$container = 'lnn-music-bot'
$envFile = Join-Path $repo '.env'
$dataDir = Join-Path $repo 'data'

if (-not (Test-Path $envFile)) {
    throw "Missing .env - copy .env.example to .env and fill in the keys (see README.md#keys)."
}

# Pin the build to the newest yt-dlp release so Docker only rebuilds that layer when it changes
$ytDlpVersion = (Invoke-RestMethod https://pypi.org/pypi/yt-dlp/json).info.version
$commit = git -C $repo rev-parse --short HEAD 2>$null
if (-not $commit) { $commit = 'unknown' }
if (git -C $repo status --porcelain) { $commit = "$commit-dirty" }
$buildDate = (Get-Date).ToUniversalTime().ToString('o')

Write-Host "Building $image ($commit) with yt-dlp $ytDlpVersion..."
docker build --pull -t $image --build-arg YT_DLP_VERSION=$ytDlpVersion --build-arg COMMIT_HASH=$commit --build-arg BUILD_DATE=$buildDate $repo
if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
docker rm -f $container 2>$null | Out-Null
# INSTANCE_NAME labels this install in #bots-internal when several PCs share the bot (see README.md#several-pcs-failover)
docker run -d --name $container --restart unless-stopped `
    --env-file $envFile `
    -e "INSTANCE_NAME=$env:COMPUTERNAME" `
    -v "${dataDir}:/data" `
    $image | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker run failed' }

Write-Host "Bot started. Logs: docker logs -f $container   Stop: docker stop $container" -ForegroundColor Green
