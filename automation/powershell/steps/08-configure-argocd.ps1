# Step 8 – Configure ArgoCD (OpenShift GitOps) to monitor the FNCM namespace
#
# What this step does:
#   a) Verifies the ArgoCD instance in $ARGOCD_NAMESPACE is Available
#   b) Retrieves the ArgoCD admin credentials and server URL
#   c) Grants the ArgoCD application controller access to the FNCM namespace
#   d) Creates (or updates) an ArgoCD Application that compares live cluster
#      state against desired state stored in your GitOps repository
#   e) Exports the live FNCMCluster manifest into the local GitOps repo clone
#      (or .\gitops-export\ if ARGOCD_GITOPS_LOCAL_REPO_PATH is not set)
#      and prints the 4 git commands needed to push and trigger a refresh
#   f) Prints a summary with the ArgoCD URL and sync-status commands
#
# Controlled by config.ps1 (or wizard-generated config.session.ps1):
#   CONFIGURE_ARGOCD        = $true  (must opt-in explicitly)
#   ARGOCD_GITOPS_REPO_URL  = ""     (leave blank to skip Application creation)
#   ARGOCD_AUTO_SYNC        = $false (manual sync by default - drift alerts only)
#   ARGOCD_SELF_HEAL        = $false
#   ARGOCD_PRUNE            = $false
#
# Re-run at any time:  .\Install-FNCM.ps1 -Step 8
#
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── Guard: skip unless explicitly enabled ─────────────────────────────────────
if (-not $CONFIGURE_ARGOCD) {
    Write-Log "ArgoCD configuration skipped (CONFIGURE_ARGOCD = `$false)." "INFO"
    Write-Log "Run the wizard or set CONFIGURE_ARGOCD = `$true in config.ps1 to enable." "INFO"
    return
}

# ── 8a: Verify ArgoCD instance is Available ───────────────────────────────────
Write-Log "[8a] Verifying ArgoCD instance in namespace '$ARGOCD_NAMESPACE'..." "INFO"

$argoPhase = (& oc get argocd openshift-gitops -n $ARGOCD_NAMESPACE `
    -o 'jsonpath={.status.phase}' 2>&1).Trim()

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($argoPhase)) {
    throw @"
ArgoCD instance 'openshift-gitops' not found in namespace '$ARGOCD_NAMESPACE'.

Ensure the OpenShift GitOps operator is installed:
  oc get subscription openshift-gitops-operator -n openshift-operators
  oc get csv -n openshift-gitops

Then re-run:  .\Install-FNCM.ps1 -Step 8
"@
}

if ($argoPhase -ne "Available") {
    Write-Log "ArgoCD phase is '$argoPhase' (expected 'Available') -- waiting up to 5 min..." "WARN"
    $phaseDeadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $phaseDeadline) {
        Start-Sleep -Seconds 15
        $argoPhase = (& oc get argocd openshift-gitops -n $ARGOCD_NAMESPACE `
            -o 'jsonpath={.status.phase}' 2>&1).Trim()
        if ($argoPhase -eq "Available") { break }
        $rem = [int](($phaseDeadline - (Get-Date)).TotalSeconds / 60)
        Write-Log "  Phase: '$argoPhase'  ($rem min remaining)..." "INFO"
    }
    if ($argoPhase -ne "Available") {
        Write-Log "ArgoCD did not reach Available -- continuing anyway." "WARN"
        Write-Log "Check: oc get argocd openshift-gitops -n $ARGOCD_NAMESPACE -o yaml" "WARN"
    }
}
Write-Log "ArgoCD instance found (phase: $argoPhase)." "SUCCESS"

# ── 8b: Retrieve admin credentials and server URL ─────────────────────────────
Write-Log "[8b] Retrieving ArgoCD access information..." "INFO"

$argoRoute = (& oc get route openshift-gitops-server -n $ARGOCD_NAMESPACE `
    -o 'jsonpath={.spec.host}' 2>&1).Trim()
$argoURL   = if ($argoRoute -and $LASTEXITCODE -eq 0) { "https://$argoRoute" } else { "<route not found>" }

# Admin password lives in the 'openshift-gitops-cluster' secret (base64-encoded)
$b64Pass = (& oc get secret openshift-gitops-cluster -n $ARGOCD_NAMESPACE `
    -o 'jsonpath={.data.admin\.password}' 2>&1).Trim()
$argoPassword = if ($LASTEXITCODE -eq 0 -and $b64Pass) {
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Pass))
} else {
    "<check secret 'openshift-gitops-cluster' in namespace '$ARGOCD_NAMESPACE'>"
}

Write-Log "  ArgoCD URL      : $argoURL" "SUCCESS"
Write-Log "  ArgoCD username : admin" "INFO"
Write-Log "  ArgoCD password : $argoPassword" "INFO"

# ── 8c: Grant ArgoCD controller admin access to the FNCM namespace ────────────
# The ArgoCD application controller service account needs permission to read,
# create, and patch resources in the target namespace ($FNCM_NAMESPACE).
Write-Log "[8c] Granting ArgoCD controller access to namespace '$FNCM_NAMESPACE'..." "INFO"

& oc adm policy add-role-to-user admin `
    "system:serviceaccount:${ARGOCD_NAMESPACE}:openshift-gitops-argocd-application-controller" `
    -n $FNCM_NAMESPACE 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Log "  ArgoCD controller has admin access to '$FNCM_NAMESPACE'." "SUCCESS"
} else {
    Write-Log "  Could not grant access -- Application sync may fail with permission errors." "WARN"
    Write-Log "  Run manually:" "WARN"
    Write-Log "    oc adm policy add-role-to-user admin system:serviceaccount:${ARGOCD_NAMESPACE}:openshift-gitops-argocd-application-controller -n $FNCM_NAMESPACE" "WARN"
}

# ── 8d: Create / update the ArgoCD Application ────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ARGOCD_GITOPS_REPO_URL)) {
    Write-Log "" "INFO"
    Write-Log "[8d] No GitOps repo URL configured -- skipping Application creation." "INFO"
    Write-Log "  Store your FNCMCluster CR and related manifests in a Git repo, then" "INFO"
    Write-Log "  set ARGOCD_GITOPS_REPO_URL in config.ps1 and re-run:  .\Install-FNCM.ps1 -Step 8" "INFO"
} else {
    Write-Log "[8d] Creating / updating ArgoCD Application '$ARGOCD_APP_NAME'..." "INFO"

    # Build the sync-policy 'automated' block only when AUTO_SYNC is enabled.
    # Using backtick-n so the block can be cleanly embedded inside a here-string.
    $pruneStr    = if ($ARGOCD_PRUNE)     { "true" } else { "false" }
    $selfHealStr = if ($ARGOCD_SELF_HEAL) { "true" } else { "false" }
    $automatedBlock = if ($ARGOCD_AUTO_SYNC) {
        "`n    automated:`n      prune: $pruneStr`n      selfHeal: $selfHealStr"
    } else { "" }
    # Retry block -- always included.
    # The FNCM operator reconciles the FNCMCluster CR continuously, bumping its
    # resourceVersion on every reconcile cycle.  ArgoCD's apply PATCH can arrive
    # with a stale resourceVersion and receive a 409 Conflict ("the object has
    # been modified").  A retry policy with exponential back-off lets ArgoCD
    # land between two reconcile cycles and succeed.
    $retryBlock = "`n    retry:`n      limit: 5`n      backoff:`n        duration: 5s`n        factor: 2`n        maxDuration: 3m"

    Apply-Yaml @"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    fncm.ibm.com/managed-by: fncm-install-automation
spec:
  project: default
  source:
    repoURL: ${ARGOCD_GITOPS_REPO_URL}
    targetRevision: ${ARGOCD_GITOPS_REVISION}
    path: ${ARGOCD_GITOPS_REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${FNCM_NAMESPACE}
  # The FNCM operator (field manager: OpenAPI-Generator) continuously stamps fields
  # onto the FNCMCluster CR during every reconcile cycle.  Without ignoreDifferences,
  # ArgoCD would see perpetual OutOfSync and fight the operator with every sync.
  # managedFieldsManagers skips fields owned by OpenAPI-Generator when diffing, so
  # ArgoCD only compares the spec fields it declared in Git (desired state).
  ignoreDifferences:
    - group: fncm.ibm.com
      kind: FNCMCluster
      managedFieldsManagers:
        - OpenAPI-Generator
      jsonPointers:
        - /metadata/annotations
        - /metadata/generation
        - /metadata/resourceVersion
        - /metadata/finalizers
  syncPolicy:${automatedBlock}${retryBlock}
    syncOptions:
      - CreateNamespace=false
      - ApplyOutOfSyncOnly=true
      - ServerSideApply=true
"@ "Application/${ARGOCD_APP_NAME}"

    # ── Strip the client-side apply annotation from the FNCMCluster CR ───────────
    # The install script creates the CR with 'oc apply' (client-side apply), which
    # stamps a kubectl.kubernetes.io/last-applied-configuration annotation on the
    # object.  When ArgoCD (with ServerSideApply=true) first syncs, it attempts a
    # migration PATCH to convert that annotation to managed fields.  If the FNCM
    # operator has updated the CR in the meantime, the resourceVersion will have
    # changed and the migration fails with "the object has been modified".
    # Removing the annotation before ArgoCD's first sync sidesteps the migration
    # entirely and lets ArgoCD do a clean server-side apply from the start.
    # Resolve the FNCMCluster CR name from config (falls back to 'fncmdeploy')
    $fncmCRName = if ($null -ne (Get-Variable 'FNCM_CR_NAME' -ErrorAction SilentlyContinue) `
                      -and -not [string]::IsNullOrWhiteSpace($FNCM_CR_NAME)) {
        $FNCM_CR_NAME
    } else { "fncmdeploy" }

    Write-Log "  Stripping client-side apply annotation from FNCMCluster CR '$fncmCRName'..." "INFO"

    # Use the full API group name -- the shortname 'fncmcluster' is not always registered.
    # Also clear managedFields so ArgoCD can do a clean server-side apply from scratch.
    $annotateOut = & oc annotate fncmclusters.fncm.ibm.com $fncmCRName `
        "kubectl.kubernetes.io/last-applied-configuration-" `
        -n $FNCM_NAMESPACE 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Annotation removed." "SUCCESS"
    } else {
        Write-Log "  Could not remove annotation (may already be absent): $annotateOut" "DEBUG"
    }

    # Clear managedFields so ArgoCD skips the client-side→server-side migration entirely.
    $patchOut = & oc patch fncmclusters.fncm.ibm.com $fncmCRName -n $FNCM_NAMESPACE `
        --type=json -p '[{"op":"remove","path":"/metadata/managedFields"}]' 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  managedFields cleared -- ArgoCD server-side apply will start clean." "SUCCESS"
    } else {
        Write-Log "  Could not clear managedFields: $patchOut" "DEBUG"
    }

    Write-Log "" "INFO"
    Write-Log "Application '${ARGOCD_APP_NAME}' configured:" "SUCCESS"
    Write-Log "  Repository : $ARGOCD_GITOPS_REPO_URL" "INFO"
    Write-Log "  Path       : $ARGOCD_GITOPS_REPO_PATH" "INFO"
    Write-Log "  Revision   : $ARGOCD_GITOPS_REVISION" "INFO"
    Write-Log "  Target NS  : $FNCM_NAMESPACE" "INFO"
    Write-Log "  Auto-sync  : $(if ($ARGOCD_AUTO_SYNC) { 'enabled' } else { 'disabled -- manual sync required' })" "INFO"
    Write-Log "  Self-heal  : $(if ($ARGOCD_SELF_HEAL) { 'enabled (drift auto-reverted)' } else { 'disabled' })" "INFO"
    Write-Log "  Prune      : $(if ($ARGOCD_PRUNE)     { 'enabled (extra resources removed)' } else { 'disabled' })" "INFO"
}

# ── 8e: Export FNCMCluster manifest to the GitOps repo ────────────────────────
# Keeps the desired-state manifest in Git current with the live cluster spec so
# ArgoCD shows Synced (not OutOfSync) immediately after a fresh deploy/reinstall.
if ([string]::IsNullOrWhiteSpace($ARGOCD_GITOPS_REPO_URL)) {
    Write-Log "" "INFO"
    Write-Log "[8e] Skipping manifest export (no GitOps repo URL configured)." "INFO"
} else {
    Write-Log "" "INFO"
    Write-Log "[8e] Exporting FNCMCluster manifest to GitOps repo path..." "INFO"

    # Resolve the local repo root.  ARGOCD_GITOPS_LOCAL_REPO_PATH may not exist
    # in older session files generated before this variable was introduced.
    $localRepoRoot = ""
    if ($null -ne (Get-Variable 'ARGOCD_GITOPS_LOCAL_REPO_PATH' -ErrorAction SilentlyContinue)) {
        $localRepoRoot = $ARGOCD_GITOPS_LOCAL_REPO_PATH
    }

    # Choose export destination: local repo clone > fallback gitops-export/
    if (-not [string]::IsNullOrWhiteSpace($localRepoRoot) -and (Test-Path $localRepoRoot)) {
        $exportDest = Join-Path $localRepoRoot $ARGOCD_GITOPS_REPO_PATH
        Write-Log "  Target : $exportDest  (local GitOps repo)" "INFO"
    } else {
        if (-not [string]::IsNullOrWhiteSpace($localRepoRoot)) {
            Write-Log "  Local repo path '$localRepoRoot' not found -- exporting to .\gitops-export\ instead." "WARN"
            Write-Log "  Clone your GitOps repo to that path and re-run:  .\Install-FNCM.ps1 -Step 8" "WARN"
        }
        $exportDest = Join-Path $PSScriptRoot ".." "gitops-export"
        Write-Log "  Target : $exportDest" "INFO"
    }

    $exportScript = Join-Path $PSScriptRoot ".." "Export-FNCMGitOps.ps1"
    $configFile   = Join-Path $PSScriptRoot ".." "config.ps1"

    if (Test-Path $exportScript) {
        try {
            & $exportScript -OutputPath $exportDest -ConfigFile $configFile
        } catch {
            Write-Log "Manifest export failed: $_" "WARN"
            Write-Log "Run manually after deployment:  .\Export-FNCMGitOps.ps1" "WARN"
        }
    } else {
        Write-Log "Export-FNCMGitOps.ps1 not found -- skipping manifest export." "WARN"
    }

    # ── Print git commands ─────────────────────────────────────────────────────
    Write-Log "" "INFO"
    if (-not [string]::IsNullOrWhiteSpace($localRepoRoot) -and (Test-Path $localRepoRoot)) {
        Write-Log "  Manifest exported.  Push to Git to complete ArgoCD setup:" "INFO"
        Write-Log "" "INFO"
        Write-Log "    git -C `"$localRepoRoot`" add $ARGOCD_GITOPS_REPO_PATH/" "INFO"
        Write-Log "    git -C `"$localRepoRoot`" status" "INFO"
        Write-Log "    git -C `"$localRepoRoot`" diff --stat HEAD" "INFO"
        Write-Log "    git -C `"$localRepoRoot`" commit -m `"chore: refresh FNCMCluster manifest`"" "INFO"
        Write-Log "    git -C `"$localRepoRoot`" push" "INFO"
        Write-Log "" "INFO"
        Write-Log "  ArgoCD detects the push within ~3 min, or click REFRESH in the UI." "INFO"
    } else {
        Write-Log "  Copy $exportDest\ to your GitOps repo's $ARGOCD_GITOPS_REPO_PATH\ folder, then:" "INFO"
        Write-Log "    git add $ARGOCD_GITOPS_REPO_PATH/" "INFO"
        Write-Log "    git commit -m `"chore: refresh FNCMCluster manifest`"" "INFO"
        Write-Log "    git push" "INFO"
    }
}

# ── 8f: Summary ───────────────────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  ArgoCD GitOps Configuration Complete" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "" "INFO"
Write-Log "  ArgoCD UI   : $argoURL" "INFO"
Write-Log "  Login       : admin  /  $argoPassword" "INFO"

if (-not [string]::IsNullOrWhiteSpace($ARGOCD_GITOPS_REPO_URL)) {
    Write-Log "" "INFO"
    Write-Log "  ArgoCD is monitoring namespace '$FNCM_NAMESPACE' against:" "INFO"
    Write-Log "    $ARGOCD_GITOPS_REPO_URL  @ $ARGOCD_GITOPS_REVISION  (path: $ARGOCD_GITOPS_REPO_PATH)" "INFO"
    Write-Log "" "INFO"
    Write-Log "  Check sync status:" "INFO"
    Write-Log "    oc get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE" "INFO"
    Write-Log "    oc get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE -o jsonpath='{.status.sync.status}'" "INFO"
    Write-Log "" "INFO"
    Write-Log "  Trigger a manual sync from the ArgoCD UI or CLI:" "INFO"
    Write-Log "    argocd app sync $ARGOCD_APP_NAME  (requires argocd CLI)" "INFO"
    Write-Log "  Or via the ArgoCD UI: $argoURL" "INFO"
}
