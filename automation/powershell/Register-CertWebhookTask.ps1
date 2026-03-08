#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup: register the FNCM Cert Webhook Listener as a Windows
    Scheduled Task so it starts automatically at logon.

.DESCRIPTION
    Creates a Scheduled Task that launches Start-CertWebhookListener.ps1 when
    the current user logs on.  The task runs with "highest privileges" so the
    cert import (into Cert:\LocalMachine\Root) happens without a UAC prompt.

    After registration, start the listener immediately without rebooting:
        Start-ScheduledTask -TaskName 'FNCM Cert Webhook Listener'

    When AWX completes the "FNCM Full Install" job successfully, it POSTs to
        http://host.docker.internal:8765/trigger
    The listener receives the webhook and automatically runs Add-ClusterCerts.ps1.

    A Windows Firewall inbound rule is also created for port 8765 so that the
    Docker container (via host.docker.internal) can reach the listener.

.PARAMETER Unregister
    Remove the scheduled task and firewall rule instead of creating them.

.PARAMETER Port
    Listener port.  Default: 8765.  Must match the AWX notification URL.

.EXAMPLE
    # Register (run once — accepts UAC if needed)
    .\Register-CertWebhookTask.ps1

    # Start the listener immediately after registration
    Start-ScheduledTask -TaskName 'FNCM Cert Webhook Listener'

    # Verify health
    Invoke-RestMethod http://localhost:8765/health

    # Remove
    .\Register-CertWebhookTask.ps1 -Unregister
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Unregister,
    [int]$Port = 8765
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'config.ps1')
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force -DisableNameChecking

$TaskName        = 'FNCM Cert Webhook Listener'
$TaskDescription = 'Listens on localhost:{0} for AWX FNCM deployment webhooks and auto-imports cluster CA certificates.' -f $Port
$FwRuleName      = 'FNCM Cert Webhook (port {0})' -f $Port
$ListenerScript  = Join-Path $PSScriptRoot 'Start-CertWebhookListener.ps1'

# ── Elevation check ───────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Log "Administrator rights required. Re-launching elevated..." 'WARN'
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    if ($Unregister)    { $psArgs += ' -Unregister' }
    if ($Port -ne 8765) { $psArgs += " -Port $Port" }
    Start-Process powershell.exe -ArgumentList $psArgs -Verb RunAs -Wait
    exit 0
}

# ── Unregister ────────────────────────────────────────────────────────────────
if ($Unregister) {
    Write-Log "Removing scheduled task '$TaskName'..." 'INFO'
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Task removed." 'SUCCESS'

    Write-Log "Removing firewall rule '$FwRuleName'..." 'INFO'
    Remove-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
    Write-Log "Firewall rule removed." 'SUCCESS'
    exit 0
}

# ── Validate listener script path ─────────────────────────────────────────────
if (-not (Test-Path $ListenerScript)) {
    Write-Log "Listener script not found: $ListenerScript" 'ERROR'
    exit 1
}

# ── Create / update Windows Firewall inbound rule ─────────────────────────────
Write-Log "Configuring Windows Firewall: allow inbound TCP $Port (Docker → listener)..." 'INFO'
$existingRule = Get-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
if ($existingRule) {
    Write-Log "  Firewall rule already exists — updating." 'INFO'
    Set-NetFirewallRule -DisplayName $FwRuleName -LocalPort $Port -Protocol TCP
} else {
    New-NetFirewallRule `
        -DisplayName  $FwRuleName `
        -Direction    Inbound `
        -Protocol     TCP `
        -LocalPort    $Port `
        -Action       Allow `
        -Profile      Private, Domain `
        -Description  "Allow Docker Desktop (host.docker.internal) to reach the FNCM cert webhook listener." `
        | Out-Null
    Write-Log "  Firewall rule created." 'SUCCESS'
}

# ── Register Scheduled Task ───────────────────────────────────────────────────
Write-Log "Registering scheduled task '$TaskName'..." 'INFO'

$psExe  = (Get-Command powershell.exe).Source
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ListenerScript`" -Port $Port"

$action    = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal `
    -UserId   $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Highest         # elevated — cert import works without UAC

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0)   # run indefinitely

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Description $TaskDescription `
    -Action      $action `
    -Trigger     $trigger `
    -Principal   $principal `
    -Settings    $settings `
    -Force | Out-Null

Write-Log "Scheduled task '$TaskName' registered successfully." 'SUCCESS'

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Log "" 'INFO'
Write-Log "================================================" 'SUCCESS'
Write-Log "  FNCM Cert Webhook Listener — Setup Complete" 'SUCCESS'
Write-Log "================================================" 'INFO'
Write-Log "" 'INFO'
Write-Log "  Task name  : $TaskName" 'INFO'
Write-Log "  Trigger    : At logon for $env:USERNAME (elevated, no UAC)" 'INFO'
Write-Log "  Script     : $ListenerScript" 'INFO'
Write-Log "  Port       : $Port" 'INFO'
Write-Log "  Webhook URL: http://host.docker.internal:${Port}/trigger" 'INFO'
Write-Log "  Log file   : $env:TEMP\fncm-cert-webhook.log" 'INFO'
Write-Log "" 'INFO'
Write-Log "  Start now (without rebooting):" 'INFO'
Write-Log "    Start-ScheduledTask -TaskName '$TaskName'" 'INFO'
Write-Log "" 'INFO'
Write-Log "  Test the listener (after starting):" 'INFO'
Write-Log "    Invoke-RestMethod http://localhost:${Port}/health" 'INFO'
Write-Log "    Invoke-RestMethod -Method POST -Uri http://localhost:${Port}/trigger \" 'INFO'
Write-Log "      -ContentType application/json -Body '{\"status\":\"successful\",\"name\":\"test\"}'" 'INFO'
Write-Log "" 'INFO'
Write-Log "  AWX notification: already configured by awx-bootstrap.yml" 'INFO'
Write-Log "  Every successful 'FNCM Full Install' will now trigger cert import automatically." 'INFO'
