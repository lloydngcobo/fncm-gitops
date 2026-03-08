#Requires -Version 5.1
<#
.SYNOPSIS
    HTTP webhook listener. Runs Add-ClusterCerts.ps1 when AWX job succeeds.

.DESCRIPTION
    Listens on http://localhost:<Port>/
      POST /trigger  - AWX webhook target; imports certs when status=successful
      GET  /health   - liveness probe

    Registered as a Windows Scheduled Task (elevated) by Register-CertWebhookTask.ps1
    so cert import happens with no UAC prompt.
    Log: %TEMP%\fncm-cert-webhook.log

.PARAMETER Port
    TCP port. Default: 18765.

.EXAMPLE
    .\Start-CertWebhookListener.ps1

    Invoke-RestMethod http://localhost:18765/health

    Invoke-RestMethod -Method POST http://localhost:18765/trigger `
        -ContentType application/json `
        -Body '{"status":"successful","name":"test"}'
#>
[CmdletBinding()]
param(
    [int]$Port = 18765
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'config.ps1')
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force -DisableNameChecking

$ListenUrl      = "http://localhost:${Port}/"
$AddCertsScript = Join-Path $PSScriptRoot 'Add-ClusterCerts.ps1'
$LogFile        = Join-Path $env:TEMP 'fncm-cert-webhook.log'

function Write-WebhookLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8
    Write-Log $Message $Level
}

# Validate cert script exists
if (-not (Test-Path $AddCertsScript)) {
    Write-WebhookLog "Add-ClusterCerts.ps1 not found: $AddCertsScript" 'ERROR'
    exit 1
}

# Port-in-use check (TcpClient is more reliable than Test-NetConnection)
$portInUse = $false
$tcpCheck = New-Object System.Net.Sockets.TcpClient
try {
    $tcpCheck.Connect('127.0.0.1', $Port)
    $portInUse = $true
    $tcpCheck.Close()
} catch {
    $portInUse = $false
}

if ($portInUse) {
    Write-WebhookLog "Port $Port already in use - another listener may be running. Exiting." 'WARN'
    exit 0
}

Write-WebhookLog "FNCM Cert Webhook Listener starting on $ListenUrl" 'INFO'
Write-WebhookLog "Log: $LogFile" 'INFO'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($ListenUrl)
$listener.Start()
Write-WebhookLog "Ready. AWX webhook URL: http://host.docker.internal:${Port}/trigger" 'SUCCESS'

try {
    while ($true) {

        $ctx      = $listener.GetContext()
        $req      = $ctx.Request
        $res      = $ctx.Response
        $path     = $req.Url.AbsolutePath
        $method   = $req.HttpMethod
        Write-WebhookLog "$method $path" 'INFO'

        $respCode = 200
        $respBody = '{}'

        if ($method -eq 'POST' -and $path -eq '/trigger') {

            $body = (New-Object System.IO.StreamReader($req.InputStream)).ReadToEnd()
            Write-WebhookLog "Body: $body" 'INFO'

            $pl = $null
            try   { $pl = $body | ConvertFrom-Json }
            catch { Write-WebhookLog "JSON parse failed - treating as unknown status." 'WARN' }

            $jobStatus = 'unknown'
            $jobName   = '(unknown)'
            if ($pl -ne $null -and $pl.PSObject.Properties['status']) { $jobStatus = $pl.status }
            if ($pl -ne $null -and $pl.PSObject.Properties['name'])   { $jobName   = $pl.name   }

            if ($jobStatus -eq 'successful') {
                Write-WebhookLog "AWX job '$jobName' succeeded - triggering Add-ClusterCerts.ps1..." 'SUCCESS'
                $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$AddCertsScript`""
                Start-Process -FilePath powershell.exe -ArgumentList $psArgs -WindowStyle Normal
                $respBody = '{"result":"cert_import_triggered"}'
            } else {
                Write-WebhookLog "Job '$jobName' status=$jobStatus - cert import skipped." 'WARN'
                $respBody = '{"result":"skipped"}'
            }

        } elseif ($path -eq '/health') {
            $respBody = '{"status":"ok","listener":"fncm-cert-webhook"}'
        } else {
            $respCode = 404
            $respBody = '{"error":"not_found"}'
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($respBody)
        $res.StatusCode      = $respCode
        $res.ContentType     = 'application/json'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
    }

} finally {
    $listener.Stop()
    Write-WebhookLog "Listener stopped." 'INFO'
}
