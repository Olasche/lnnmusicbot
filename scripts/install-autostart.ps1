# Registers the sign-in task that starts Docker Desktop (and with it the bot) via docker-autostart.ps1,
# and removes Docker Desktop's own startup entry so Docker can't launch before the stale-socket cleanup.
#   powershell -ExecutionPolicy Bypass -File scripts\install-autostart.ps1
$ErrorActionPreference = 'Stop'
$taskName = 'LnnMusicBot - Docker autostart'
$script = Join-Path $PSScriptRoot 'docker-autostart.ps1'
$user = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName `
    -Description 'Starts Docker Desktop at sign-in (clearing stale socket files that crash its startup) so the Discord music bot comes back up.' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name 'Docker Desktop' -ErrorAction SilentlyContinue
Write-Host "Registered '$taskName' -> $script" -ForegroundColor Green
