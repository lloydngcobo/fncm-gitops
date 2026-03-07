#Requires -Version 5.1
<#
.SYNOPSIS
    Exports live FNCM manifests from the cluster into a GitOps-ready directory.

.DESCRIPTION
    ArgoCD only shows resources in its graph that are defined in your GitOps
    repository.  This script pulls the desired-state manifests from the live
    cluster and writes them to a local directory so you can commit them to your
    GitOps repo.

    Resources exported:
      * FNCMCluster CR           (always)
      * Operator-aware ConfigMaps (always -- fncmdeploy-* prefixed CMs skipped)
      * NetworkPolicies          (-IncludeNetworkPolicies)
      * Routes                   (-IncludeRoutes)

    NOTE: Secrets are intentionally NOT exported.  Plaintext secrets must
    never be committed to Git.  Use Sealed Secrets or SOPS to manage them.

.PARAMETER OutputPath
    Directory to write the YAML files to.  Defaults to .\gitops-export\.

.PARAMETER ConfigFile
    Path to config.ps1.  Defaults to .\config.ps1.

.PARAMETER IncludeNetworkPolicies
    Also export NetworkPolicy resources from the FNCM namespace.

.PARAMETER IncludeRoutes
    Also export Route resources from the FNCM namespace.

.EXAMPLE
    # Export to the default ./gitops-export/ folder
    .\Export-FNCMGitOps.ps1

    # Export to your GitOps repo folder directly
    .\Export-FNCMGitOps.ps1 -OutputPath C:\repos\fncm-gitops\manifests

    # Export everything (CR + network policies + routes)
    .\Export-FNCMGitOps.ps1 -IncludeNetworkPolicies -IncludeRoutes
#>
[CmdletBinding()]
param(
    [string] $OutputPath              = (Join-Path $PSScriptRoot "gitops-export"),
    [string] $ConfigFile              = "$PSScriptRoot\config.ps1",
    [switch] $IncludeNetworkPolicies,
    [switch] $IncludeRoutes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}
. $ConfigFile
Import-Module "$PSScriptRoot\common.psm1" -Force -DisableNameChecking

$ns = $FNCM_NAMESPACE

# ── Helper: export one resource to a YAML file ────────────────────────────────
# Strips the `status:` top-level block and the verbose `managedFields:` block
# so the resulting file represents only desired state.  ArgoCD additionally
# ignores resourceVersion / uid / generation / creationTimestamp automatically.
function Export-Resource {
    param(
        [Parameter(Mandatory)] [string]$Kind,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$OutFile
    )
    Write-Log "  Exporting $Kind/$Name ..." "INFO"
    $raw = & oc get $Kind $Name -n $Namespace -o yaml 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "    WARNING: could not export $Kind/$Name (skipping): $raw" "WARN"
        return $false
    }

    # ── Strip blocks that should not live in a GitOps desired-state file ──────
    # We process line-by-line so we can handle indented child content of each key.
    $lines      = $raw -split "`n"
    $out        = [System.Collections.Generic.List[string]]::new()
    $skipIndent = -1   # indent level being skipped; -1 = not skipping

    foreach ($line in $lines) {
        $trimmed = $line.TrimStart()
        $indent  = $line.Length - $trimmed.Length

        if ($skipIndent -ge 0) {
            # Still inside a block we are skipping?
            if ($indent -gt $skipIndent -or $trimmed -eq "") {
                continue   # child line of the skipped block -- drop it
            } else {
                $skipIndent = -1   # back to normal level
            }
        }

        # Top-level keys to strip entirely
        if ($indent -eq 0 -and $trimmed -match '^status:\s*') {
            $skipIndent = 0; continue
        }

        # `managedFields:` appears at indent=2 (inside metadata)
        if ($trimmed -match '^managedFields:\s*') {
            $skipIndent = $indent; continue
        }

        $out.Add($line)
    }

    # Write with Unix line endings (cleaner for cross-platform git repos)
    $content = $out -join "`n"
    [System.IO.File]::WriteAllText($OutFile, $content)
    Write-Log "    -> $OutFile" "SUCCESS"
    return $true
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
Write-Log "================================================" "STEP"
Write-Log "  FNCM GitOps Manifest Export" "STEP"
Write-Log "================================================" "STEP"
Write-Log "Source namespace : $ns" "INFO"
Write-Log "Output path      : $OutputPath" "INFO"
Write-Log "" "INFO"

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$exportCount = 0

# ── Export: FNCMCluster CR (primary desired state) ────────────────────────────
Write-Log "[1] FNCMCluster Custom Resource..." "STEP"

$fncmCRName = (& oc get fncmcluster -n $ns -o jsonpath='{.items[0].metadata.name}' 2>&1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fncmCRName)) {
    Write-Log "No FNCMCluster CR found in namespace '$ns'." "WARN"
    Write-Log "Ensure Step 7 (Deploy FNCM CR) has completed successfully first." "WARN"
} else {
    $ok = Export-Resource "fncmcluster" $fncmCRName $ns (Join-Path $OutputPath "fncmcluster.yaml")
    if ($ok) { $exportCount++ }
}

# ── Export: user-managed ConfigMaps (opt-in only) ────────────────────────────
# ConfigMaps in the FNCM namespace are almost exclusively operator-generated.
# Exporting them causes permanent OutOfSync noise because the FNCM operator
# continuously reconciles their content.  They are intentionally skipped by
# default and only exported when -IncludeConfigMaps is passed explicitly.
#
# The FNCM operator generates ConfigMaps with these (and other) prefixes:
#   fncmdeploy-   ibm-   kube-   openshift-   ef7f18*
# There is typically no user-managed ConfigMap in the fncm namespace that needs
# to be tracked via GitOps -- desired state belongs in the FNCMCluster CR.
$SKIP_CM_PATTERN = '^(fncmdeploy-|ibm-|kube-|openshift-|[0-9a-f]{8,})'

# Note: this block intentionally does nothing when -IncludeConfigMaps is absent.
# Passing -IncludeConfigMaps exports ConfigMaps that don't match the skip pattern,
# but expect ArgoCD OutOfSync if the operator manages any of them.
Write-Log "" "INFO"
Write-Log "[2] ConfigMaps..." "STEP"
if (-not $IncludeConfigMaps) {
    Write-Log "  Skipped (operator owns all ConfigMaps in this namespace)." "INFO"
    Write-Log "  Pass -IncludeConfigMaps to export them anyway." "DEBUG"
} else {
    Write-Log "  WARNING: FNCM operator manages most ConfigMaps -- expect OutOfSync noise." "WARN"
    $allCMs = & oc get configmap -n $ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($cm in ($allCMs -split "`n" | Where-Object { $_ -ne "" })) {
            if ($cm -match $SKIP_CM_PATTERN) {
                Write-Log "  Skipping operator-managed ConfigMap: $cm" "DEBUG"
                continue
            }
            $ok = Export-Resource "configmap" $cm $ns (Join-Path $OutputPath "cm-${cm}.yaml")
            if ($ok) { $exportCount++ }
        }
    } else {
        Write-Log "  Could not list ConfigMaps -- skipping." "WARN"
    }
}

# ── Export: NetworkPolicies ───────────────────────────────────────────────────
if ($IncludeNetworkPolicies) {
    Write-Log "" "INFO"
    Write-Log "[3] NetworkPolicies..." "STEP"
    $nps = & oc get networkpolicy -n $ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($np in ($nps -split "`n" | Where-Object { $_ -ne "" })) {
            $ok = Export-Resource "networkpolicy" $np $ns (Join-Path $OutputPath "netpol-${np}.yaml")
            if ($ok) { $exportCount++ }
        }
    } else {
        Write-Log "  No NetworkPolicies found or could not list them." "WARN"
    }
}

# ── Export: Routes ────────────────────────────────────────────────────────────
if ($IncludeRoutes) {
    Write-Log "" "INFO"
    Write-Log "[4] Routes..." "STEP"
    $routes = & oc get route -n $ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($r in ($routes -split "`n" | Where-Object { $_ -ne "" })) {
            $ok = Export-Resource "route" $r $ns (Join-Path $OutputPath "route-${r}.yaml")
            if ($ok) { $exportCount++ }
        }
    } else {
        Write-Log "  No Routes found or could not list them." "WARN"
    }
}

# ── Write README.md ───────────────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "Writing README.md..." "INFO"
$readmeContent = @"
# FNCM GitOps Manifests

Generated by `Export-FNCMGitOps.ps1` on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
Source namespace: ``$ns``

## File listing

| File | Kind | Description |
|------|------|-------------|
| fncmcluster.yaml | FNCMCluster | Primary desired state -- the FNCM Custom Resource |

> Operator-created resources (Pods, Deployments, Services, ReplicaSets) are
> managed automatically by the FNCM operator in response to the FNCMCluster CR.
> They do NOT need to be stored in Git.

## How ArgoCD uses these files

ArgoCD compares each file in this directory against the corresponding live
resource in the ``$ns`` namespace.  Any difference in ``spec:`` is reported
as **OutOfSync** in the ArgoCD UI.

Click **DIFF** in the ArgoCD dashboard to see exactly what changed.
Click **SYNC** to apply the Git state to the cluster (manual sync mode).

## Secrets -- important

Secrets are NOT exported here. **Never commit plaintext secrets to Git.**

To track secrets in GitOps use one of:
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) -- encrypts
  the secret so only the cluster can decrypt it
- [SOPS](https://github.com/mozilla/sops) -- file-level encryption with
  age/GPG keys

## Re-exporting

Re-run the export script at any time to refresh these files from the live cluster:

``````powershell
.\Export-FNCMGitOps.ps1 -OutputPath .\gitops-export
``````

Then commit and push the changes to keep the GitOps repo up to date.
"@
[System.IO.File]::WriteAllText((Join-Path $OutputPath "README.md"), $readmeContent)

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  Export Complete  ($exportCount resource(s) exported)" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "" "INFO"

$files = Get-ChildItem $OutputPath -File | Sort-Object Name
Write-Log "  Files in $OutputPath :" "INFO"
foreach ($f in $files) {
    $kb = [math]::Round($f.Length / 1KB, 1)
    Write-Log ("    {0,-38} {1,6} KB" -f $f.Name, $kb) "INFO"
}

Write-Log "" "INFO"
Write-Log "  Next steps to populate the ArgoCD graph:" "INFO"
Write-Log "" "INFO"
Write-Log "  1. Copy these files to your GitOps repository:" "INFO"
Write-Log "       \$ARGOCD_GITOPS_REPO_URL  = $ARGOCD_GITOPS_REPO_URL" "INFO"
Write-Log "       \$ARGOCD_GITOPS_REPO_PATH = $ARGOCD_GITOPS_REPO_PATH" "INFO"
Write-Log "" "INFO"
Write-Log "  2. Commit and push:" "INFO"
Write-Log "       git add ." "INFO"
Write-Log "       git commit -m 'Add FNCM desired-state manifests'" "INFO"
Write-Log "       git push" "INFO"
Write-Log "" "INFO"
Write-Log "  3. In the ArgoCD UI click REFRESH on 'fncm-deploy'" "INFO"
Write-Log "     All exported resources will now appear in the graph." "INFO"
Write-Log "" "INFO"
Write-Log "  4. Click SYNC (or wait for auto-sync) to reconcile." "INFO"
Write-Log "" "INFO"
Write-Log "  !! Do not commit plaintext secrets to Git !!" "WARN"
Write-Log "     Use Sealed Secrets or SOPS for secret management." "WARN"
