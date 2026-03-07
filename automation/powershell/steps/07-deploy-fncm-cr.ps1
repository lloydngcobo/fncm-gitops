# Step 7 - Apply network policies, secrets, patch CR, and apply FNCM CustomResource
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── 7-pre: Restore operator if it was paused from a previous step-7 run ───────
# The operator is intentionally paused (replicas=0) at the END of every step-7
# to lock in the GraphQL XSRF fix.  On a re-run we must restore it to replicas=1
# so it can reconcile the CR and deploy any new / previously-blocked components
# (e.g. IER whose secret was missing on the first run).  It is paused again at
# the end of 7g once all components are confirmed ready.
$operatorWasRestored = $false
$operatorExists = & oc get deployment ibm-fncm-operator -n $FNCM_NAMESPACE 2>&1
if ($LASTEXITCODE -eq 0) {
    $currentReplicas = (& oc get deployment ibm-fncm-operator -n $FNCM_NAMESPACE `
        -o 'jsonpath={.spec.replicas}' 2>&1).Trim()
    if ($currentReplicas -eq "0") {
        Write-Log "Operator is paused (replicas=0). Restoring for reconciliation..." "INFO"
        & oc scale deployment ibm-fncm-operator --replicas=1 -n $FNCM_NAMESPACE 2>&1 | Out-Null
        Write-Log "Waiting for operator pod to be ready (up to 2 min)..." "INFO"
        & oc rollout status deployment/ibm-fncm-operator `
            -n $FNCM_NAMESPACE --timeout=120s 2>&1 | Out-Null
        Write-Log "Operator is running." "SUCCESS"
        $operatorWasRestored = $true
    } else {
        Write-Log "Operator already running (replicas=$currentReplicas)." "INFO"
    }
} else {
    Write-Log "Operator deployment not found (first-time deploy)." "INFO"
}

# ── 7a: Network policies ──────────────────────────────────────────────────────
Write-Log "Applying permissive egress network policies..." "INFO"

foreach ($ns in @($FNCM_NAMESPACE, $INSTALL_NAMESPACE)) {
    Apply-Yaml @"
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: custom-permit-all-egress
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: '${NETWORK_CIDR}'
            except: []
"@ "NetworkPolicy custom-permit-all-egress (${ns})"
}

# ── 7b: Patch the generated CR - change LDAP type to Custom (for OpenLDAP) ───
Write-Log "Patching ibm_fncm_cr_production.yaml - setting LDAP type to Custom..." "INFO"

$CR_PATH = "${GENERATED_FILES_PATH}/ibm_fncm_cr_production.yaml"

# Use Python to patch the CR YAML safely:
#  - Restores from .bak on re-runs so we always patch the original
#  - Sets lc_selected_ldap_type to Custom
#  - Adds a 'custom:' section as a deep copy of 'tds:' so the FNCM operator
#    Ansible code can access LDAP settings via either key (it references
#    'tds' unconditionally even when lc_selected_ldap_type is Custom)
$patchCrScript = @"
import yaml, copy, shutil, os

cr_path = '${CR_PATH}'
bak_path = cr_path + '.bak'

if os.path.exists(bak_path):
    shutil.copy(bak_path, cr_path)
    print('Restored original CR from backup')
else:
    shutil.copy(cr_path, bak_path)
    print('Created CR backup')

with open(cr_path, 'r') as fh:
    cr = yaml.safe_load(fh)

ldap = cr['spec']['ldap_configuration']
ldap['lc_selected_ldap_type'] = 'Custom'

if 'tds' in ldap and 'custom' not in ldap:
    ldap['custom'] = copy.deepcopy(ldap['tds'])
    print('Added custom: LDAP section (copy of tds:) for OpenLDAP compatibility')

with open(cr_path, 'w') as fh:
    yaml.dump(cr, fh, default_flow_style=False, allow_unicode=True,
              sort_keys=False, indent=2)

print('CR patched: lc_selected_ldap_type=Custom, both tds and custom sections present')
"@

$tmpPatch = Write-TempScript -Content $patchCrScript -Extension ".py"
Copy-ToPod -Namespace $INSTALL_NAMESPACE -PodName "install" `
    -LocalPath $tmpPatch `
    -RemotePath "/tmp/patch_cr.py"
Remove-Item $tmpPatch -Force

Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" `
    -BashCommand "python3 /tmp/patch_cr.py"

# ── 7c: Switch oc project to fncm ────────────────────────────────────────────
Write-Log "Setting active project to '$FNCM_NAMESPACE'..." "INFO"
& oc project $FNCM_NAMESPACE | Out-Null

# ── 7d: Apply secrets ─────────────────────────────────────────────────────────
# Apply EVERY yaml in the generated secrets directory so component-specific
# secrets (ibm-ier-secret, ibm-iccsap-secret, ...) are never missed.
Write-Log "Applying generated Kubernetes secrets (all files in secrets/)..." "INFO"
$secretsCmd = @"
cd ${GENERATED_FILES_PATH}/secrets && \
echo "Secrets to apply:" && ls -1 *.yaml && \
oc apply -f . -n ${FNCM_NAMESPACE}
"@
Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $secretsCmd
Write-Log "Secrets applied." "SUCCESS"

# ── 7e: Apply FNCM Custom Resource ────────────────────────────────────────────
Write-Log "Applying FNCM Custom Resource (ibm_fncm_cr_production.yaml)..." "INFO"
$applyCrCmd = "oc apply -f ${GENERATED_FILES_PATH}/ibm_fncm_cr_production.yaml -n ${FNCM_NAMESPACE}"
Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $applyCrCmd
Write-Log "FNCM CR applied." "SUCCESS"

# If the operator was just restored, force a reconciliation by touching the
# FNCMCluster annotation.  When 'oc apply' returns "unchanged" (spec hasn't
# changed) the operator will not automatically reconcile -- the annotation
# change causes its watch to fire immediately.
if ($operatorWasRestored) {
    Write-Log "Triggering operator reconciliation via annotation..." "INFO"
    $ts = Get-Date -Format 'yyyyMMddHHmmss'
    & oc annotate fncmcluster/fncmdeploy -n $FNCM_NAMESPACE `
        "fncm.automation/last-applied=$ts" --overwrite 2>&1 | Out-Null
    Write-Log "Giving operator 90s to detect changes and begin reconciliation..." "INFO"
    Start-Sleep -Seconds 90
}

# ── 7f: Wait for FNCMCluster to reach Ready state ─────────────────────────────
Write-Log "Waiting for FNCMCluster 'fncmdeploy' to be Ready (up to 90 min)..." "INFO"
$deadline = (Get-Date).AddMinutes(90)
$clusterReady = $false
while ((Get-Date) -lt $deadline) {
    $conditions = & oc get FNCMCluster fncmdeploy -n $FNCM_NAMESPACE `
        -o 'jsonpath={.status.conditions[*].type}' 2>&1
    if ($conditions -match "Ready") {
        Write-Log "FNCMCluster is Ready!" "SUCCESS"
        $clusterReady = $true
        break
    }
    $compStatus = & oc get FNCMCluster fncmdeploy -n $FNCM_NAMESPACE `
        -o 'jsonpath={.status.components}' 2>&1
    $remaining = [int](($deadline - (Get-Date)).TotalSeconds / 60)
    Write-Log "Still deploying (${remaining} min remaining)..." "INFO"
    Write-Log "  Components: $compStatus" "DEBUG"
    Start-Sleep -Seconds 60
}

if (-not $clusterReady) {
    Write-Log "FNCMCluster did not reach Ready within 90 min." "WARN"
    Write-Log "Check: oc get FNCMCluster fncmdeploy -n $FNCM_NAMESPACE -o yaml" "WARN"
}

# ── 7f-init: Wait for CPE object store initialization to match expected count ──
# When IER is deployed the operator must:
#   1. Add ibm_OS2.xml + ibm_OS3.xml to the CPE configmap (FNOS2DS / FNOS3DS)
#   2. Roll CPE to pick up the new JDBC datasources
#   3. Run the content-init job to bootstrap OS2 (ROS) and OS3 (FPOS)
# This is tracked by fncmdeploy-initialization-config.cpe_os_number.
# We MUST wait here, otherwise 7g pauses the operator before any of this happens.
$expectedOsCount = if ($DEPLOY_IER) { 3 } else { 1 }

if ($expectedOsCount -gt 1) {
    Write-Log "" "INFO"
    Write-Log "IER requires $expectedOsCount object stores -- waiting for CPE init to complete..." "INFO"
    Write-Log "  Tracking: fncmdeploy-initialization-config  cpe_os_number -> $expectedOsCount" "INFO"
    $initDeadline = (Get-Date).AddMinutes(30)
    $initDone = $false
    while ((Get-Date) -lt $initDeadline) {
        $cpeOsNum = (& oc get configmap fncmdeploy-initialization-config `
            -n $FNCM_NAMESPACE `
            -o 'jsonpath={.data.cpe_os_number}' 2>&1).Trim()
        if ($cpeOsNum -eq "$expectedOsCount") {
            Write-Log "CPE initialization complete: cpe_os_number = $cpeOsNum." "SUCCESS"
            $initDone = $true
            break
        }
        $remaining = [int](($initDeadline - (Get-Date)).TotalSeconds / 60)
        Write-Log ("  cpe_os_number = '$cpeOsNum' (waiting for '$expectedOsCount')" +
                   " -- $remaining min remaining...") "INFO"
        Start-Sleep -Seconds 60
    }
    if (-not $initDone) {
        Write-Log "WARNING: CPE object store init did not complete within 30 min." "WARN"
        Write-Log "  Check: oc get configmap fncmdeploy-initialization-config -n $FNCM_NAMESPACE -o yaml" "WARN"
        Write-Log "  Check: oc get pods -n $FNCM_NAMESPACE | grep -i init" "WARN"
    }
}

# ── 7f-extra: Wait for optional component pods that have their own secrets ────
# IER and ICCSAP require a separate Kubernetes secret that the operator needs
# before it can create the pod.  Even after FNCMCluster shows Ready, these pods
# may still be starting.  We wait for them here so the GraphQL pause in 7g
# does not cut off a still-initialising pod.

function Wait-ComponentPod {
    param([string]$ComponentName, [string]$SearchFragment, [int]$TimeoutMin = 30)
    Write-Log "" "INFO"
    Write-Log "Waiting for $ComponentName pod to reach Running state (up to $TimeoutMin min)..." "INFO"
    $podDeadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $podDeadline) {
        # Find pods whose name contains the search fragment (case-insensitive)
        $podLines = @(& oc get pods -n $FNCM_NAMESPACE --no-headers 2>&1 |
            Where-Object { $_ -match $SearchFragment })
        if ($podLines.Count -gt 0) {
            $running = @($podLines | Where-Object { $_ -match '\s+1/1\s+Running\s+' })
            if ($running.Count -gt 0) {
                Write-Log "$ComponentName pod is Running and Ready." "SUCCESS"
                return $true
            }
            # Pod exists but not yet 1/1 Running - show status
            Write-Log "  $ComponentName pod found, waiting for Ready: $($podLines[0])" "DEBUG"
        } else {
            $remaining = [int](($podDeadline - (Get-Date)).TotalSeconds / 60)
            Write-Log "  $ComponentName pod not yet created ($remaining min remaining)..." "DEBUG"
        }
        Start-Sleep -Seconds 30
    }
    Write-Log "$ComponentName pod did not reach Running within $TimeoutMin min." "WARN"
    Write-Log "Check: oc get pods -n $FNCM_NAMESPACE | grep $SearchFragment" "WARN"
    return $false
}

if ($DEPLOY_IER) {
    Wait-ComponentPod -ComponentName "IER" -SearchFragment "ier" -TimeoutMin 30 | Out-Null
}
if ($DEPLOY_ICCSAP) {
    Wait-ComponentPod -ComponentName "ICCSAP" -SearchFragment "iccsap" -TimeoutMin 30 | Out-Null
}

# ── 7g: Permanently fix GraphQL XSRF / auth ───────────────────────────────────
# Root cause: the FNCM operator hardcodes three env vars on every reconcile:
#   DISABLE_BASIC_AUTH=true      -> all direct requests return HTTP 401
#   ENABLE_GRAPHIQL=false        -> browser playground disabled
#   IBM_ICS_DISABLE_XSRF_CHECK   -> absent -> XSRF validation on -> Error 500
#
# Fix: scale the operator to 0 (stop reconciliation) then patch the GraphQL
# Deployment with the corrected values.  The Kubernetes Deployment controller
# still manages pod restarts, and the env vars live in the Deployment spec so
# they survive restarts even with the operator paused.
if ($DEPLOY_GRAPHQL) {
    Write-Log "" "INFO"
    Write-Log "Applying permanent GraphQL XSRF/auth fix..." "INFO"

    Write-Log "  Scaling FNCM operator to 0 (pausing reconciliation)..." "INFO"
    & oc scale deployment ibm-fncm-operator --replicas=0 -n $FNCM_NAMESPACE 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  Could not scale operator. Proceeding." "WARN"
    } else {
        Write-Log "  Operator scaled to 0." "SUCCESS"
    }

    Write-Log "  Patching GraphQL deployment env vars..." "INFO"
    & oc set env deployment/fncmdeploy-graphql-deploy `
        IBM_ICS_DISABLE_XSRF_CHECK=true `
        ENABLE_GRAPHIQL=true `
        DISABLE_BASIC_AUTH=false `
        -n $FNCM_NAMESPACE 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  GraphQL deployment not found - re-run Step 7 once GraphQL is deployed." "WARN"
    } else {
        Write-Log "  Waiting for GraphQL pod to roll out (up to 5 min)..." "INFO"
        & oc rollout status deployment/fncmdeploy-graphql-deploy `
            -n $FNCM_NAMESPACE --timeout=300s 2>&1 |
            ForEach-Object { Write-Log "    $_" "DEBUG" }
        Write-Log "  GraphQL XSRF fix applied." "SUCCESS"
    }

    Write-Log "" "INFO"
    Write-Log "FNCM operator is paused (replicas=0) to preserve the GraphQL fix." "INFO"
    Write-Log "This is intentional -- Kubernetes still manages pod restarts." "INFO"
    Write-Log "To restore the operator (resets GraphQL env vars back to defaults):" "INFO"
    Write-Log "  oc scale deployment ibm-fncm-operator --replicas=1 -n $FNCM_NAMESPACE" "INFO"
} else {
    # No GraphQL - still pause the operator so it doesn't undo any customisations
    Write-Log "GraphQL not deployed -- pausing operator to prevent unwanted reconciliation." "INFO"
    & oc scale deployment ibm-fncm-operator --replicas=0 -n $FNCM_NAMESPACE 2>&1 | Out-Null
}

Write-Log "" "INFO"
Write-Log "=== FNCM Deployment Summary ===" "SUCCESS"
Write-Log "Check component status:" "INFO"
Write-Log "  oc get FNCMCluster fncmdeploy -n $FNCM_NAMESPACE -o jsonpath='{.status.components}' | jq" "INFO"
Write-Log "Operator logs:" "INFO"
Write-Log "  oc logs deployment/ibm-fncm-operator -n $FNCM_NAMESPACE" "INFO"
Write-Log "Access URLs (ConfigMap):" "INFO"
Write-Log "  oc get cm fncmdeploy-fncm-access-info -n $FNCM_NAMESPACE -o yaml" "INFO"
