#Requires -Version 5.1
<#
.SYNOPSIS
    Tear down all IBM FNCM resources for a clean re-run.

.DESCRIPTION
    Removes every Kubernetes/OpenShift resource created by Install-FNCM.ps1:
      - CA certificates from Cert:\LocalMachine\Root on this workstation (step 0)
      - FNCMCluster CR (finalizers stripped so deletion doesn't hang)
      - FNCM operator OLM objects  (Subscription, CSV, CatalogSource)
      - Namespace fncm             (CPE, GraphQL, Navigator deployments/PVCs/routes)
      - Namespace fncm-openldap    (OpenLDAP deployment/PVC)
      - Namespace fncm-postgresql  (PostgreSQL StatefulSet/PVCs)
      - Namespace fncm-install     (install pod + PVC) -- unless -KeepInstallPod
      - ClusterRoleBinding cluster-admin-fncm-install
      - FNCMCluster CRD            -- only with -DeleteCRDs

    Certificate removal runs FIRST (before cluster resources are deleted) because
    it needs 'oc' to read the cert thumbprints from the cluster.  A UAC elevation
    prompt will appear for the cert removal unless already running as Administrator.
    Use -KeepCerts to skip the cert removal (useful when the same CA will be
    reused on the next deployment).

    NOTE: Persistent Volumes whose reclaim policy is "Retain" are NOT deleted
    automatically. If your NFS provisioner uses Retain, you may need to manually
    remove Released PVs or clean up the backing NFS share before re-running step 6
    (SQL scripts expect empty databases).

.PARAMETER Force
    Skip the interactive confirmation prompt (useful in CI/automation).

.PARAMETER KeepInstallPod
    Preserve the fncm-install namespace and the install pod.
    Saves ~20 minutes on the next run because the pod setup (git clone, pip,
    JDK, oc CLI) only runs once.
    Generated files (propertyFile, generatedFiles, silent_config TOMLs) are
    cleared inside the pod so steps 4-7 run cleanly from scratch.
    Re-run with:  .\Install-FNCM.ps1 -SkipSteps 1

.PARAMETER DeleteCRDs
    Also remove the FNCMCluster CRD (and any co-installed CRDs).
    Needed only if the operator upgrade changed the CRD schema and you want
    a completely clean slate. Not required for a normal re-run.

.PARAMETER KeepCerts
    Skip removing the FNCM and OCP CA certificates from the workstation trust store.
    Useful when you plan to immediately re-deploy (the same CA cert will be reused
    and you want to avoid a second UAC prompt on the next Add-ClusterCerts.ps1 run).

.EXAMPLE
    # Interactive full teardown (removes cluster resources AND workstation certs)
    .\Teardown-FNCM.ps1

    # Keep install pod (saves 20 min setup on next run)
    .\Teardown-FNCM.ps1 -KeepInstallPod

    # Keep certs trusted (skip workstation cert removal -- useful for quick re-deploy)
    .\Teardown-FNCM.ps1 -KeepCerts

    # Non-interactive full teardown (CI)
    .\Teardown-FNCM.ps1 -Force

    # Full teardown including CRDs (clean slate for operator upgrade)
    .\Teardown-FNCM.ps1 -Force -DeleteCRDs
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $KeepInstallPod,
    [switch] $DeleteCRDs,
    [switch] $KeepCerts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "config.ps1")
Import-Module (Join-Path $PSScriptRoot "common.psm1") -Force -DisableNameChecking

# ── Confirmation ──────────────────────────────────────────────────────────────
if (-not $Force) {
    Write-Log "" "INFO"
    Write-Log "================================================" "WARN"
    Write-Log "  IBM FNCM TEARDOWN" "WARN"
    Write-Log "================================================" "WARN"
    Write-Log "This will PERMANENTLY DELETE:" "WARN"
    if (-not $KeepCerts) {
        Write-Log "  Workstation: FNCM + OCP CA certs from Cert:\LocalMachine\Root" "WARN"
    }
    Write-Log "  Namespaces : $FNCM_NAMESPACE, $OPENLDAP_NAMESPACE, $POSTGRESQL_NAMESPACE" "WARN"
    if ($KeepInstallPod) {
        Write-Log "  Install pod: PRESERVED (generated files will be cleared)" "WARN"
    } else {
        Write-Log "  Namespace  : $INSTALL_NAMESPACE (install pod + PVC)" "WARN"
    }
    if ($DeleteCRDs) {
        Write-Log "  CRDs       : fncmclusters.fncm.ibm.com (and related)" "WARN"
    }
    Write-Log "" "INFO"
    Write-Log "All FNCM application data (CPE content, Navigator) will be LOST." "WARN"
    Write-Log "" "INFO"
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Log "Teardown aborted." "INFO"
        exit 0
    }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
if (-not (Test-OCLogin)) {
    Write-Log "Not logged in to OpenShift. Run 'oc login' first." "ERROR"
    exit 1
}
Write-Log "" "INFO"
Write-Log "Starting FNCM teardown on $OCP_API_URL ..." "INFO"

# ── Helper: silent oc delete ──────────────────────────────────────────────────
function Remove-OCResource {
    param([string]$Kind, [string]$Name, [string]$Namespace = "")
    $args = @("delete", $Kind, $Name, "--ignore-not-found=true", "--wait=false")
    if ($Namespace) { $args += @("-n", $Namespace) }
    & oc @args 2>&1 | Out-Null
    Write-Log "  Removed $Kind/$Name$(if ($Namespace) { " (-n $Namespace)" })" "DEBUG"
}

# ── 0. Remove CA certificates from workstation trust store ───────────────────
# Must run BEFORE cluster resources are deleted -- Add-ClusterCerts.ps1 needs
# 'oc' to read the cert thumbprints from the fncm-root-ca secret.
if ($KeepCerts) {
    Write-Log "[0/8] Skipping workstation cert removal (-KeepCerts specified)." "INFO"
} else {
    Write-Log "[0/8] Removing FNCM + OCP CA certs from workstation trust store..." "INFO"
    $certScript = Join-Path $PSScriptRoot "Add-ClusterCerts.ps1"
    if (Test-Path $certScript) {
        try {
            & $certScript -Uninstall -Namespace $FNCM_NAMESPACE
            Write-Log "Workstation certificates removed." "SUCCESS"
        } catch {
            Write-Log "Certificate removal encountered an error: $_" "WARN"
            Write-Log "Continuing teardown. Re-run 'Add-ClusterCerts.ps1 -Uninstall' manually if needed." "WARN"
        }
    } else {
        Write-Log "Add-ClusterCerts.ps1 not found -- skipping cert removal." "WARN"
    }
}
Write-Log "" "INFO"

# ── 1. Strip FNCMCluster finalizers (prevents namespace-delete hang) ──────────
Write-Log "[1/8] Removing FNCMCluster finalizers..." "INFO"
& oc patch FNCMCluster fncmdeploy -n $FNCM_NAMESPACE `
    --type=merge -p '{"metadata":{"finalizers":[]}}' 2>&1 | Out-Null

# ── 2. Delete FNCMCluster CR ──────────────────────────────────────────────────
Write-Log "[2/8] Deleting FNCMCluster CR..." "INFO"
Remove-OCResource "FNCMCluster" "fncmdeploy" $FNCM_NAMESPACE

# ── 3. Delete Subscription (stops operator from reinstalling OLM objects) ─────
Write-Log "[3/8] Deleting FNCM operator OLM objects (Subscription, CSV)..." "INFO"
$subs = & oc get subscription -n $FNCM_NAMESPACE -o name 2>&1
if ($subs -match "^subscription") {
    $subs -split "`n" | Where-Object { $_ -match "^subscription" } | ForEach-Object {
        & oc delete $_ -n $FNCM_NAMESPACE --ignore-not-found=true 2>&1 | Out-Null
        Write-Log "  Removed $_" "DEBUG"
    }
}

# ── 4. Delete ClusterServiceVersion ───────────────────────────────────────────
$csvs = & oc get csv -n $FNCM_NAMESPACE -o name 2>&1
if ($csvs -match "^clusterserviceversion") {
    $csvs -split "`n" | Where-Object { $_ -match "^clusterserviceversion" } | ForEach-Object {
        & oc delete $_ -n $FNCM_NAMESPACE --ignore-not-found=true 2>&1 | Out-Null
        Write-Log "  Removed $_" "DEBUG"
    }
}

# ── 5. Delete namespaces (handles all namespaced resources including PVCs) ────
Write-Log "[4/8] Initiating namespace deletion (async)..." "INFO"
$nsToDelete = @($FNCM_NAMESPACE, $OPENLDAP_NAMESPACE, $POSTGRESQL_NAMESPACE)
if (-not $KeepInstallPod) {
    $nsToDelete += $INSTALL_NAMESPACE
}

foreach ($ns in $nsToDelete) {
    Write-Log "  Deleting namespace: $ns" "INFO"
    & oc delete namespace $ns --ignore-not-found=true --wait=false 2>&1 | Out-Null
}

# ── 6. Delete cluster-scoped resources ────────────────────────────────────────
Write-Log "[5/8] Deleting cluster-scoped resources..." "INFO"
Remove-OCResource "clusterrolebinding" "cluster-admin-fncm-install"

# Remove the ArgoCD Application if one was registered for this deployment.
# The OpenShift GitOps operator itself is NOT removed -- it is cluster-level
# infrastructure that other applications may depend on.
$null = & oc get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Log "  Removing ArgoCD Application '$ARGOCD_APP_NAME' from '$ARGOCD_NAMESPACE'..." "INFO"
    # Strip the finalizer first -- it blocks deletion until ArgoCD cleans up managed
    # resources, but the target namespace is already being deleted concurrently.
    & oc patch application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE `
        --type=merge -p '{"metadata":{"finalizers":[]}}' 2>&1 | Out-Null
    Remove-OCResource "application" $ARGOCD_APP_NAME $ARGOCD_NAMESPACE
    Write-Log "  ArgoCD Application removed." "SUCCESS"
} else {
    Write-Log "  ArgoCD Application '$ARGOCD_APP_NAME' not found -- skipping." "DEBUG"
}

# ── 7. Optionally delete CRDs ─────────────────────────────────────────────────
if ($DeleteCRDs) {
    Write-Log "[6/8] Deleting FNCM CRDs..." "INFO"
    $crds = & oc get crd -o name 2>&1 | Select-String "fncm.ibm.com"
    if ($crds) {
        $crds | ForEach-Object {
            & oc delete $_.ToString().Trim() --ignore-not-found=true 2>&1 | Out-Null
            Write-Log "  Removed CRD: $($_.ToString().Trim())" "DEBUG"
        }
    } else {
        Write-Log "  No FNCM CRDs found." "DEBUG"
    }
} else {
    Write-Log "[6/8] Skipping CRD deletion (use -DeleteCRDs to also remove CRDs)." "INFO"
}

# ── 8. Wait for namespace deletion ────────────────────────────────────────────
Write-Log "[7/8] Waiting for namespaces to terminate (up to 15 min)..." "INFO"
$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
    $stillPresent = @($nsToDelete | Where-Object {
        $nsName = $_
        $result = & oc get namespace $nsName 2>&1
        $result -notmatch "not found|NotFound"
    })
    if ($stillPresent.Count -eq 0) {
        Write-Log "All namespaces deleted." "SUCCESS"
        break
    }
    $remaining = [int](($deadline - (Get-Date)).TotalSeconds / 60)
    Write-Log "  Still terminating: $($stillPresent -join ', ')  ($remaining min left)" "INFO"
    Start-Sleep -Seconds 15
}
if ((Get-Date) -ge $deadline) {
    Write-Log "Namespace deletion timed out. Check: oc get namespace" "WARN"
    Write-Log "Stuck namespaces may have PVs with Retain policy - investigate with:" "WARN"
    Write-Log "  oc get namespace <ns> -o yaml" "WARN"
}

# ── 9. Clear generated files in preserved install pod ─────────────────────────
if ($KeepInstallPod) {
    Write-Log "[8/8] Clearing generated files inside install pod..." "INFO"
    $installPodPhase = & oc get pod install -n $INSTALL_NAMESPACE `
        -o jsonpath='{.status.phase}' 2>&1
    if ($installPodPhase -eq "Running") {
        $clearCmd = @"
rm -rf /usr/install/ibm-fncm-containers/scripts/generatedFiles
rm -rf /usr/install/ibm-fncm-containers/scripts/propertyFile
rm -f  /usr/install/ibm-fncm-containers/scripts/silent_config/silent_install_deployoperator.toml
rm -f  /usr/install/ibm-fncm-containers/scripts/silent_config/silent_install_prerequisites.toml
echo "Generated files cleared."
"@
        Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $clearCmd
        Write-Log "Generated files cleared." "SUCCESS"
    } else {
        Write-Log "Install pod not Running (phase: $installPodPhase). Clear files manually if needed." "WARN"
    }
} else {
    Write-Log "[8/8] Install pod namespace deleted." "INFO"
}

# ── Check for Released PVs that may need manual cleanup ───────────────────────
$releasedPVs = & oc get pv --no-headers 2>&1 | Select-String "Released"
if ($releasedPVs) {
    Write-Log "" "INFO"
    Write-Log "Released PVs found (reclaim policy may be Retain - data persists on NFS):" "WARN"
    $releasedPVs | ForEach-Object { Write-Log "  $_" "WARN" }
    Write-Log "Delete them manually if you need a completely clean re-run:" "WARN"
    Write-Log "  oc delete pv <pv-name>" "WARN"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  FNCM Teardown Complete" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "" "INFO"
if ($KeepCerts) {
    Write-Log "Workstation CA certs preserved (-KeepCerts).  After re-deploying," "INFO"
    Write-Log "the same CA will be reused -- no need to run Add-ClusterCerts.ps1 again." "INFO"
} else {
    Write-Log "Workstation CA certs removed.  After re-deploying run:" "INFO"
    Write-Log "  .\Add-ClusterCerts.ps1" "INFO"
}
Write-Log "" "INFO"
if ($KeepInstallPod) {
    Write-Log "Install pod preserved.  Next run (skips step 1):" "INFO"
    Write-Log "  .\Install-FNCM.ps1 -SkipSteps 1" "INFO"
} else {
    Write-Log "Full re-run from scratch:" "INFO"
    Write-Log "  .\Install-FNCM.ps1" "INFO"
}
