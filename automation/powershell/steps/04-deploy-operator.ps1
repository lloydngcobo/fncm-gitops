# Step 4 - Deploy the FNCM Operator into the fncm namespace
# Runs deployoperator.py inside the install pod using silent mode.
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── Create FNCM namespace ─────────────────────────────────────────────────────
Apply-Yaml @"
kind: Project
apiVersion: project.openshift.io/v1
metadata:
  name: ${FNCM_NAMESPACE}
  labels:
    app: fncm
"@ "Project ${FNCM_NAMESPACE}"

# ── Build silent deployoperator config from our variables ─────────────────────
$deployOpToml = @"
LICENSE_ACCEPT = true
PLATFORM = 1
NAMESPACE = "${FNCM_NAMESPACE}"
ENTITLEMENT_KEY = "${IBM_ENTITLEMENT_KEY}"
PRIVATE_REGISTRY = false
PRIVATE_REGISTRY_URL = ""
PRIVATE_REGISTRY_USERNAME = ""
PRIVATE_REGISTRY_PASSWORD = ""
PRIVATE_REGISTRY_SSL_ENABLED = false
PRIVATE_REGISTRY_SSL_CRT_PATH = ""
GLOBAL_CATALOG = false
"@

# ── Write to temp file with Unix line endings and copy to pod ─────────────────
$tmpToml = Write-TempScript -Content $deployOpToml -Extension ".toml"
Write-Log "Copying deployoperator silent config to install pod..." "INFO"
$silentConfigRemote = "${CONTAINER_SAMPLES_PATH}/scripts/silent_config/silent_install_deployoperator.toml"
Copy-ToPod -Namespace $INSTALL_NAMESPACE -PodName "install" `
    -LocalPath $tmpToml `
    -RemotePath $silentConfigRemote
Remove-Item $tmpToml -Force

# ── Run deployoperator.py inside the install pod ──────────────────────────────
Write-Log "Running deployoperator.py in silent mode (namespace: $FNCM_NAMESPACE)..." "INFO"
$deployCmd = "cd ${CONTAINER_SAMPLES_PATH}/scripts && python3 deployoperator.py --silent"
Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $deployCmd

# ── Wait for the FNCM operator deployment to be ready ────────────────────────
Write-Log "Waiting for FNCM operator deployment..." "INFO"
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    $csv = & oc get csv -n $FNCM_NAMESPACE -o jsonpath='{.items[0].status.phase}' 2>&1
    if ($csv -eq "Succeeded") {
        Write-Log "CSV is Succeeded." "SUCCESS"
        break
    }
    Write-Log "CSV phase: $csv  - waiting..." "INFO"
    Start-Sleep -Seconds 20
}

Wait-DeploymentReady -Namespace $FNCM_NAMESPACE -Name "ibm-fncm-operator" -TimeoutSeconds 300

Write-Log "FNCM Operator deployed successfully in namespace '$FNCM_NAMESPACE'." "SUCCESS"
