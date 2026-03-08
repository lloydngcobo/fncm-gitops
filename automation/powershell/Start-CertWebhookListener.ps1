#Requires -Version 5.1
<#
.SYNOPSIS
    Lightweight HTTP webhook listener that auto-imports FNCM cluster CA
    certificates into the Windows trust store when an AWX job succeeds.

.DESCRIPTION
    Listens on http://localhost:<Port>/trigger for AWX job-completion webhooks.
    When AWX sends a POST with status="successful", the listener automatically
    invokes Add-ClusterCerts.ps1 — fetching the FNCM Root CA and OCP Router CA
    from the cluster and importing them into Cert:\LocalMachine\Root.

    Because this listener is registered as a Windows Scheduled Task with
    "Run with highest privileges" (see Register-CertWebhookTask.ps1), the
    cert import runs fully elevated — no UAC prompt is shown to the user.

    Endpoints:
      POST /trigger  — AWX webhook target; triggers cert import on "successful"
      GET  /health   — health probe (returns {"status":"ok"})

.PARAMETER Port
    TCP port to listen on.  Default: 8765.
    Must match the AWX notification URL (http://host.docker.internal:<Port>/trigger).

.EXAMPLE
    # Start manually (for testing)
    .\Start-CertWebhookListener.ps1

    # Test via PowerShell (from another window)
    Invoke-RestMethod -Method POST -Uri http://localhost:8765/trigger `
        -ContentType 'application/json' `
        -Body '{"status":"successful","name":"FNCM Full Install"}'

    # Health check
    Invoke-RestMethod http://localhost:8765/health
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
    $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    $line | Out-File -FilePath $LogFile -Append -Encoding UTF8
    Write-Log $Message $Level   # also emit to console / scheduled task output
}

if (-not (Test-Path $AddCertsScript)) {
    Write-WebhookLog "Add-ClusterCerts.ps1 not found at: $AddCertsScript" 'ERROR'
    exit 1
}

# ── Check for another instance already listening ──────────────────────────────
$testConn = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -WarningAction SilentlyContinue -InformationLevel Quiet 2>$null
if ($testConn) {
    Write-WebhookLog "Port $Port is already in use — another listener may be running. Exiting." 'WARN'
    exit 0
}

Write-WebhookLog "FNCM Cert Webhook Listener starting on $ListenUrl" 'INFO'
Write-WebhookLog "Waiting for AWX job completion notification..." 'INFO'
Write-WebhookLog "Log file: $LogFile" 'INFO'
Write-WebhookLog "" 'INFO'

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($ListenUrl)

try {
    $listener.Start()
    Write-WebhookLog "Listener active. AWX notification URL: http://host.docker.internal:${Port}/trigger" 'SUCCESS'

    while ($listener.IsListening) {

        $context  = $listener.GetContext()   # blocking — waits for next HTTP request
        $request  = $context.Request
        $response = $context.Response

        try {
            $path   = $request.Url.AbsolutePath
            $method = $request.HttpMethod
            Write-WebhookLog "Received: $method $path" 'INFO'

            if ($path -eq '/trigger' -and $method -eq 'POST') {

                # ── Read and parse JSON body ──────────────────────────────────
                $body = (New-Object System.IO.StreamReader $request.InputStream).ReadToEnd()
                Write-WebhookLog "Payload: $body" 'INFO'

                $payload = $null
                try { $payload = $body | ConvertFrom-Json } catch { }

                $jobStatus   = if ($payload -and $payload.status)   { $payload.status }   else { 'unknown' }
                $jobName     = if ($payload -and $payload.name)     { $payload.name }     else { '(unknown job)' }

                if ($jobStatus -eq 'successful') {
                    Write-WebhookLog "AWX job '$jobName' succeeded — triggering cert import..." 'SUCCESS'

                    # ── Run Add-ClusterCerts.ps1 ──────────────────────────────
                    # Since this listener runs elevated (highest privileges via
                    # scheduled task), Add-ClusterCerts.ps1 also runs elevated
                    # and imports directly into Cert:\LocalMachine\Root without UAC.
                    $proc = Start-Process -FilePath 'powershell.exe' `
                        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                      '-File', "`"$AddCertsScript`"" `
                        -WindowStyle Normal `
                        -PassThru

                    Write-WebhookLog "Add-ClusterCerts.ps1 started (PID $($proc.Id))." 'SUCCESS'

                    $responseBody = '{"result":"cert_import_triggered"}'
                    $responseCode = 200

                } else {
                    Write-WebhookLog "AWX job '$jobName' status: $jobStatus — cert import skipped." 'WARN'
                    $responseBody = "{`"result`":`"skipped`",`"status`":`"$jobStatus`"}"
                    $responseCode = 200
                }

            } elseif ($path -eq '/health' -and $method -eq 'GET') {
                $responseBody = '{"status":"ok","listener":"fncm-cert-webhook"}'
                $responseCode = 200

            } else {
                $responseBody = '{"error":"not_found"}'
                $responseCode = 404
            }

        } catch {
            Write-WebhookLog "Error handling request: $_" 'ERROR'
            $responseBody = '{"error":"internal_error"}'
            $responseCode = 500
        }

        # ── Send HTTP response ────────────────────────────────────────────────
        $response.StatusCode      = $responseCode
        $response.ContentType     = 'application/json'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.Close()
    }

} catch {
    Write-WebhookLog "Listener fatal error: $_" 'ERROR'
} finally {
    $listener.Stop()
    Write-WebhookLog "Listener stopped." 'INFO'
}
