#Requires -Version 5.1
<#
.SYNOPSIS
    Toggle IBM Content Services GraphQL dev-mode settings.

.DESCRIPTION
    By default the FNCM operator deploys GraphQL with:
      ENABLE_GRAPHIQL=false       (browser playground disabled)
      DISABLE_BASIC_AUTH=true     (LDAP Basic Auth disabled → 401 on direct access)

    Because the operator reconciles and resets these env vars, a simple
    "oc set env" is not persistent.  This script scales the operator to 0
    first (stopping reconciliation), applies the dev settings, then waits
    for the GraphQL pod to roll out.

    Use -Disable to reverse the change and restore the operator.

.PARAMETER Disable
    Restore production defaults and bring the operator back up.

.PARAMETER Namespace
    FNCM namespace (default: read from config.ps1 → $FNCM_NAMESPACE).

.EXAMPLE
    # Enable GraphiQL + Basic Auth + disable XSRF check
    .\Enable-GraphQL-DevMode.ps1

    # Restore production defaults
    .\Enable-GraphQL-DevMode.ps1 -Disable
#>
[CmdletBinding()]
param(
    [switch] $Disable,
    [string] $Namespace = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "config.ps1")
Import-Module (Join-Path $PSScriptRoot "common.psm1") -Force -DisableNameChecking

if (-not $Namespace) { $Namespace = $FNCM_NAMESPACE }
$deployment = "fncmdeploy-graphql-deploy"
$operator   = "ibm-fncm-operator"

if (-not (Test-OCLogin)) {
    Write-Log "Not logged in. Run 'oc login' first." "ERROR"; exit 1
}

if ($Disable) {
    # ── Restore production defaults ───────────────────────────────────────────
    Write-Log "Restoring GraphQL production defaults..." "INFO"

    Write-Log "  Applying production env vars..." "INFO"
    & oc set env deployment/$deployment `
        ENABLE_GRAPHIQL=false `
        DISABLE_BASIC_AUTH=true `
        -n $Namespace 2>&1 | Out-Null

    # Remove IBM_ICS_DISABLE_XSRF_CHECK if it was added
    & oc set env deployment/$deployment IBM_ICS_DISABLE_XSRF_CHECK- `
        -n $Namespace 2>&1 | Out-Null

    Write-Log "  Rolling out production GraphQL pod..." "INFO"
    & oc rollout status deployment/$deployment -n $Namespace --timeout=120s 2>&1 | Out-Null
    Write-Log "  GraphQL pod updated." "SUCCESS"

    Write-Log "  Scaling FNCM operator back to 1 replica..." "INFO"
    & oc scale deployment/$operator --replicas=1 -n $Namespace 2>&1 | Out-Null
    Wait-DeploymentReady -Namespace $Namespace -Name $operator -TimeoutSeconds 120
    Write-Log "FNCM operator restored and running." "SUCCESS"

} else {
    # ── Enable dev mode ───────────────────────────────────────────────────────
    Write-Log "Enabling GraphQL dev mode (GraphiQL + Basic Auth + no XSRF check)..." "INFO"
    Write-Log "" "INFO"
    Write-Log "  WARNING: The FNCM operator will be scaled to 0 to prevent it from" "WARN"
    Write-Log "  reverting these settings.  Run with -Disable when done." "WARN"
    Write-Log "" "INFO"

    Write-Log "  Scaling FNCM operator to 0 (pausing reconciliation)..." "INFO"
    & oc scale deployment/$operator --replicas=0 -n $Namespace 2>&1 | Out-Null
    # Wait for operator pods to terminate
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $pods = & oc get pods -n $Namespace -l name=$operator --no-headers 2>&1
        if ($pods -match "No resources|not found" -or [string]::IsNullOrWhiteSpace($pods)) { break }
        Start-Sleep -Seconds 5
    }
    Write-Log "  Operator scaled down." "SUCCESS"

    Write-Log "  Applying dev env vars to GraphQL deployment..." "INFO"
    & oc set env deployment/$deployment `
        ENABLE_GRAPHIQL=true `
        DISABLE_BASIC_AUTH=false `
        IBM_ICS_DISABLE_XSRF_CHECK=true `
        -n $Namespace 2>&1 | Out-Null

    Write-Log "  Waiting for GraphQL pod to roll out..." "INFO"
    & oc rollout status deployment/$deployment -n $Namespace --timeout=180s 2>&1 | Out-Null

    Write-Log "" "INFO"
    Write-Log "GraphQL dev mode ENABLED." "SUCCESS"
    Write-Log "" "INFO"

    # Look up the route
    $gqlHost = & oc get route -n $Namespace -l "app=$deployment" `
        -o jsonpath='{.items[0].spec.host}' 2>&1
    if (-not $gqlHost) {
        $gqlHost = & oc get route -n $Namespace `
            -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>&1 |
            Select-String "graphql" | Select-Object -First 1
    }

    Write-Log "  GraphQL Playground : https://${gqlHost}/content-services-graphql/" "SUCCESS"
    Write-Log "  Login credentials  : $FNCM_ADMIN_USER / $FNCM_ADMIN_PASSWORD" "INFO"
    Write-Log "" "INFO"
    Write-Log "  The FNCM operator is paused (replicas=0). When finished:" "WARN"
    Write-Log "    .\Enable-GraphQL-DevMode.ps1 -Disable" "WARN"
}
