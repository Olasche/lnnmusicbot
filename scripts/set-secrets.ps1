# Prompts for the bot's secrets with hidden input and writes them to .env (created from .env.example if missing).
# Values are never printed. Afterwards it checks them against Discord and YouTube and prints only the bot's
# username and a test video title. Run it in a terminal the human types into; an agent must not supply the values.
#   powershell -ExecutionPolicy Bypass -File scripts\set-secrets.ps1
param([string]$EnvFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env'))
$ErrorActionPreference = 'Stop'

function Read-Secret($name, $pattern, $hint) {
    while ($true) {
        $secure = Read-Host "Paste $name ($hint; input is hidden, just Enter keeps the current value)" -AsSecureString
        $value = [System.Net.NetworkCredential]::new('', $secure).Password.Trim()
        if (-not $value -or $value -match $pattern) {
            return $value
        }

        Write-Host "That doesn't look like a $name ($hint). Try again." -ForegroundColor Red
    }
}

function Get-EnvValue($path, $name) {
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line.StartsWith("$name=")) {
            return $line.Substring($name.Length + 1).Trim()
        }
    }
}

# Docker reads .env as an --env-file: write LF line endings and no BOM, or the first key/values get mangled
function Set-EnvValue($path, $name, $value) {
    $lines = [Collections.Generic.List[string]]::new()
    $found = $false
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line.StartsWith("$name=")) {
            $lines.Add("$name=$value")
            $found = $true
        } else {
            $lines.Add($line)
        }
    }

    if (-not $found) {
        $lines.Add("$name=$value")
    }

    [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function Test-Secrets($path) {
    $token = Get-EnvValue $path 'DISCORD_TOKEN'
    $key = Get-EnvValue $path 'YOUTUBE_API_KEY'

    try {
        $bot = Invoke-RestMethod https://discord.com/api/v10/users/@me -Headers @{Authorization = "Bot $token"}
        Write-Host "Discord token OK: bot is $($bot.username) ($($bot.id))" -ForegroundColor Green
    } catch {
        Write-Host "Discord token rejected: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        $video = Invoke-RestMethod "https://www.googleapis.com/youtube/v3/videos?part=snippet&id=jNQXAC9IVRw&key=$key"
        Write-Host "YouTube key OK: test video is '$($video.items[0].snippet.title)'" -ForegroundColor Green
    } catch {
        Write-Host "YouTube key rejected: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Allow dot-sourcing the functions (for testing) without prompting
if ($MyInvocation.InvocationName -eq '.') {
    return
}

if (-not (Test-Path $EnvFile)) {
    $template = Join-Path (Split-Path -Parent $EnvFile) '.env.example'
    [IO.File]::WriteAllText($EnvFile, (([IO.File]::ReadAllLines($template)) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Created $EnvFile from .env.example"
}

$token = Read-Secret 'DISCORD_TOKEN' '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' 'the bot token you were given; three parts separated by dots'
if ($token) { Set-EnvValue $EnvFile 'DISCORD_TOKEN' $token }
$token = $null

$key = Read-Secret 'YOUTUBE_API_KEY' '^AIza[0-9A-Za-z_-]{35}$' 'starts with AIza, 39 characters'
if ($key) { Set-EnvValue $EnvFile 'YOUTUBE_API_KEY' $key }
$key = $null

if ((Get-EnvValue $EnvFile 'CHECKPOINT_DISABLE') -ne '1') {
    Set-EnvValue $EnvFile 'CHECKPOINT_DISABLE' '1'
}

Write-Host "Saved to $EnvFile. Checking the values..."
Test-Secrets $EnvFile
Write-Host 'Run scripts\start-bot.ps1 to (re)create the container with these values.'
