#Requires -Version 5.1
<#
.SYNOPSIS
    Master orchestration script for IBM FileNet Content Manager on OpenShift.

.DESCRIPTION
    When run without flags, an interactive wizard guides you through:
      - Selecting which FNCM capabilities to deploy
      - Choosing the run mode (full run, skip step 1, single step, custom)
      - Confirming before deploying

    Behind the scenes the wizard writes a config.session.ps1 that all step
    scripts dot-source so they pick up your component selections automatically.
    The session file is removed after a successful deployment.

    Steps executed:
      1  Setup install-client  (namespace, PVC, pod)
      2  Deploy OpenLDAP
      3  Deploy PostgreSQL
      4  Deploy FNCM Operator
      5  Gather & Generate config (property files, SQL, secrets, CR)
      6  Apply database SQL scripts
      7  Deploy FNCM Custom Resource
      8  Configure ArgoCD GitOps monitoring  (optional -- requires CONFIGURE_ARGOCD = $true)
      *  Import FNCM + OCP CA certificates into the Windows trust store
         (runs automatically after step 7 via Add-ClusterCerts.ps1)

.PARAMETER Step
    Run a single step (1-8) and exit.  Bypasses the wizard.

.PARAMETER SkipSteps
    Comma-separated step numbers to skip.  Bypasses the wizard.

.PARAMETER Force
    Skip the interactive wizard and deploy with config.ps1 defaults as-is.

.PARAMETER SkipCerts
    Skip the automatic certificate import that runs after step 7.

.PARAMETER ConfigFile
    Path to config.ps1.  Defaults to .\config.ps1.

.EXAMPLE
    # Interactive wizard (recommended for first-time or new capability selection)
    .\Install-FNCM.ps1

    # Non-interactive: deploy with config.ps1 defaults, no wizard
    .\Install-FNCM.ps1 -Force

    # Re-run only step 5 (uses config.ps1 defaults, no wizard)
    .\Install-FNCM.ps1 -Step 5

    # Skip steps 1-3 (prereqs already deployed) - bypasses wizard
    .\Install-FNCM.ps1 -SkipSteps 1,2,3

    # Re-deploy after -KeepCerts teardown (certs still trusted)
    .\Install-FNCM.ps1 -SkipCerts
#>
[CmdletBinding()]
param(
    [int]    $Step       = 0,
    [int[]]  $SkipSteps  = @(),
    [switch] $Force,
    [switch] $SkipCerts,
    [string] $ConfigFile = "$PSScriptRoot\config.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Load config ────────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}
. $ConfigFile

# ── Load common module ─────────────────────────────────────────────────────────
Import-Module "$PSScriptRoot\common.psm1" -Force -DisableNameChecking

# ── Pre-flight checks ──────────────────────────────────────────────────────────
if (-not (Test-OCInstalled)) {
    Write-Log "OpenShift CLI (oc) not found. Install it and add to PATH." "ERROR"
    exit 1
}
if ($OCP_TOKEN) {
    Write-Log "Logging in with provided token..." "INFO"
    & oc login --server=$OCP_API_URL --token=$OCP_TOKEN --insecure-skip-tls-verify 2>&1 | Out-Null
}
if (-not (Test-OCLogin)) {
    Write-Log "Not logged in to OpenShift. Run 'oc login' or set OCP_TOKEN in config.ps1." "ERROR"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($IBM_ENTITLEMENT_KEY)) {
    Write-Log "IBM_ENTITLEMENT_KEY is empty in config.ps1 - operator pull will fail." "WARN"
}

# ── Helper: convert bool to PowerShell literal string ('$true' / '$false') ────
function boolStr([bool]$v) { if ($v) { '$true' } else { '$false' } }

# ── Helper: print a coloured section header ───────────────────────────────────
function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("-" * 60) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor Cyan
}

# ── Helper: interactive Y/N prompt ───────────────────────────────────────────
function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $raw = (Read-Host "  $Prompt $hint").Trim().ToLower()
        if ($raw -eq "")  { return $Default }
        if ($raw -eq "y") { return $true }
        if ($raw -eq "n") { return $false }
        Write-Host "  Please enter Y or N." -ForegroundColor Yellow
    }
}

# ── Step definitions ──────────────────────────────────────────────────────────
$allSteps = @(
    @{ N = 1; Name = "Setup Install Client";     Script = "$PSScriptRoot\steps\01-setup-install-client.ps1"  },
    @{ N = 2; Name = "Deploy OpenLDAP";          Script = "$PSScriptRoot\steps\02-deploy-openldap.ps1"       },
    @{ N = 3; Name = "Deploy PostgreSQL";        Script = "$PSScriptRoot\steps\03-deploy-postgresql.ps1"     },
    @{ N = 4; Name = "Deploy FNCM Operator";     Script = "$PSScriptRoot\steps\04-deploy-operator.ps1"       },
    @{ N = 5; Name = "Gather & Generate Config"; Script = "$PSScriptRoot\steps\05-gather-generate.ps1"       },
    @{ N = 6; Name = "Apply Database SQL";       Script = "$PSScriptRoot\steps\06-apply-sql.ps1"             },
    @{ N = 7; Name = "Deploy FNCM CR";           Script = "$PSScriptRoot\steps\07-deploy-fncm-cr.ps1"        },
    @{ N = 8; Name = "Configure ArgoCD GitOps"; Script = "$PSScriptRoot\steps\08-configure-argocd.ps1"      }
)

# ── Optional component definitions ────────────────────────────────────────────
# Label          = text shown in the menu
# Var            = PowerShell variable name (without $) set in config.ps1
# Default        = current value from config.ps1 (used as menu default)
$componentDefs = @(
    @{ Label = "GraphQL API";                         Var = "DEPLOY_GRAPHQL"; Default = $DEPLOY_GRAPHQL },
    @{ Label = "Business Automation Navigator (BAN)"; Var = "DEPLOY_BAN";     Default = $DEPLOY_BAN     },
    @{ Label = "Content Search Services (CSS)";       Var = "DEPLOY_CSS";     Default = $DEPLOY_CSS     },
    @{ Label = "CMIS Connector";                      Var = "DEPLOY_CMIS";    Default = $DEPLOY_CMIS    },
    @{ Label = "Task Manager (TM)";                   Var = "DEPLOY_TM";      Default = $DEPLOY_TM      },
    @{ Label = "External Share (ES)";                 Var = "DEPLOY_ES";      Default = $DEPLOY_ES      },
    @{ Label = "IBM Enterprise Records (IER)";        Var = "DEPLOY_IER";     Default = $DEPLOY_IER     },
    @{ Label = "ICC for SAP (ICCSAP)";                Var = "DEPLOY_ICCSAP";  Default = $DEPLOY_ICCSAP  }
)

$sessionCfgPath = Join-Path $PSScriptRoot "config.session.ps1"

# ══════════════════════════════════════════════════════════════════════════════
# INTERACTIVE WIZARD
# Only runs when no -Force / -Step / -SkipSteps flags are given.
# ══════════════════════════════════════════════════════════════════════════════
$runWizard = (-not $Force) -and ($Step -eq 0) -and ($SkipSteps.Count -eq 0)

if ($runWizard) {

    Clear-Host
    Write-Host ""
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host "  |    IBM FileNet Content Manager  --  Deployment Wizard     |" -ForegroundColor Cyan
    Write-Host "  |                OpenShift Automation  v1.0                 |" -ForegroundColor Cyan
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Cluster  : $OCP_API_URL"  -ForegroundColor DarkGray
    Write-Host "  Target   : namespace '$FNCM_NAMESPACE'" -ForegroundColor DarkGray
    Write-Host "  Storage  : $STORAGE_CLASS_NAME" -ForegroundColor DarkGray

    # ── [1/4] Component selection ─────────────────────────────────────────────
    Write-Section "[1/4]  COMPONENT SELECTION"
    Write-Host ""
    Write-Host "  Content Platform Engine (CPE)  :  REQUIRED  (always included)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  For each optional component, press Enter to keep the default" -ForegroundColor DarkGray
    Write-Host "  shown in [brackets], or type Y / N to change it." -ForegroundColor DarkGray
    Write-Host ""

    $selections = @{}
    foreach ($c in $componentDefs) {
        $answer = Read-YesNo -Prompt $c.Label -Default $c.Default
        $selections[$c.Var] = $answer
    }

    # ── [2/4] Run mode ────────────────────────────────────────────────────────
    Write-Section "[2/4]  RUN MODE"
    Write-Host ""
    Write-Host "  1)  Full deployment          (steps 1 - 8, fresh start from scratch)"
    Write-Host "  2)  Skip Step 1              (install pod is already running, saves ~20 min)"
    Write-Host "  3)  Single step only         (re-run one specific step)"
    Write-Host "  4)  Custom skip              (specify which steps to skip)"
    Write-Host ""

    $modeChoice = ""
    while ($modeChoice -notin @("1","2","3","4")) {
        $modeChoice = (Read-Host "  Select run mode [1-4]").Trim()
    }

    $wizardStep      = 0
    $wizardSkipSteps = @()

    switch ($modeChoice) {
        "1" { }   # Full run - no changes needed
        "2" { $wizardSkipSteps = @(1) }
        "3" {
            $singleStep = 0
            while ($singleStep -lt 1 -or $singleStep -gt 8) {
                $raw = (Read-Host "  Enter step number [1-8]").Trim()
                if ($raw -match '^\d+$') { $singleStep = [int]$raw }
            }
            $wizardStep = $singleStep
        }
        "4" {
            Write-Host ""
            Write-Host "  Enter step numbers to skip, comma-separated (e.g. 1,2,3):" -ForegroundColor DarkGray
            $raw = (Read-Host "  Skip steps").Trim()
            if ($raw -ne "") {
                $wizardSkipSteps = @($raw -split '\s*,\s*' | ForEach-Object { [int]$_ })
            }
        }
    }

    # ── [3/4] Certificate trust ───────────────────────────────────────────────
    # Only prompt if step 7 will actually execute in this run
    $step7WillRun = ($wizardStep -eq 0 -or $wizardStep -eq 7) -and (7 -notin $wizardSkipSteps)
    $importCerts  = $false

    if ($step7WillRun) {
        Write-Section "[3/4]  CERTIFICATE TRUST"
        Write-Host ""
        Write-Host "  After Step 7, FNCM and OCP CA certificates can be imported" -ForegroundColor DarkGray
        Write-Host "  into the Windows workstation trust store so all FNCM endpoints" -ForegroundColor DarkGray
        Write-Host "  are trusted by your browser and tools automatically." -ForegroundColor DarkGray
        Write-Host "  (Requires a single UAC elevation prompt.)" -ForegroundColor DarkGray
        Write-Host ""
        $importCerts = Read-YesNo -Prompt "Auto-import CA certificates after Step 7?" -Default $true
        if (-not $importCerts) { $SkipCerts = $true }
    } else {
        $SkipCerts = $true   # Step 7 not running - no cert import needed
    }

    # ── [4/4] ArgoCD GitOps integration ──────────────────────────────────────
    Write-Section "[4/4]  ARGOCD GITOPS INTEGRATION"
    Write-Host ""
    Write-Host "  ArgoCD (OpenShift GitOps) continuously compares the live cluster" -ForegroundColor DarkGray
    Write-Host "  state against manifests stored in your Git repository, alerting" -ForegroundColor DarkGray
    Write-Host "  you when configuration drifts from the desired state." -ForegroundColor DarkGray
    Write-Host "  (Requires an existing OpenShift GitOps / ArgoCD installation.)" -ForegroundColor DarkGray
    Write-Host ""

    $wizardArgoCD = Read-YesNo -Prompt "Configure ArgoCD GitOps monitoring?" -Default $false

    # Initialize ArgoCD wizard variables with config.ps1 defaults
    $wizardArgoCDRepo      = $ARGOCD_GITOPS_REPO_URL
    $wizardArgoCDPath      = $ARGOCD_GITOPS_REPO_PATH
    $wizardArgoCDRevision  = $ARGOCD_GITOPS_REVISION
    $wizardArgoCDLocalPath = if ($null -ne (Get-Variable 'ARGOCD_GITOPS_LOCAL_REPO_PATH' -ErrorAction SilentlyContinue)) { $ARGOCD_GITOPS_LOCAL_REPO_PATH } else { "" }
    $wizardArgoCDAutoSync  = $ARGOCD_AUTO_SYNC
    $wizardArgoCDSelfHeal  = $ARGOCD_SELF_HEAL
    $wizardArgoCDPrune     = $ARGOCD_PRUNE

    if ($wizardArgoCD) {
        Write-Host ""
        Write-Host "  Leave the repository URL blank to configure access only (no Application created)." -ForegroundColor DarkGray
        Write-Host ""
        $raw = (Read-Host "  GitOps repository URL").Trim()
        $wizardArgoCDRepo = $raw   # may be empty -- step 8 handles that gracefully

        if ($wizardArgoCDRepo) {
            $raw = (Read-Host "  Repository path  [$ARGOCD_GITOPS_REPO_PATH]").Trim()
            if ($raw) { $wizardArgoCDPath = $raw }

            $raw = (Read-Host "  Branch / revision  [$ARGOCD_GITOPS_REVISION]").Trim()
            if ($raw) { $wizardArgoCDRevision = $raw }

            $localDefault = if ($wizardArgoCDLocalPath) { $wizardArgoCDLocalPath } else { "C:\repos\fncm-gitops" }
            Write-Host "  Local clone path is used to auto-export the manifest into your repo." -ForegroundColor DarkGray
            $raw = (Read-Host "  Local clone path  [$localDefault]").Trim()
            if ($raw) { $wizardArgoCDLocalPath = $raw } elseif (-not $wizardArgoCDLocalPath) { $wizardArgoCDLocalPath = $localDefault }

            $wizardArgoCDAutoSync = Read-YesNo -Prompt "Auto-sync when Git changes are detected?" -Default $false
            if ($wizardArgoCDAutoSync) {
                $wizardArgoCDSelfHeal = Read-YesNo -Prompt "Self-heal drift (revert manual cluster edits to Git state)?" -Default $false
                $wizardArgoCDPrune    = Read-YesNo -Prompt "Prune resources deleted from Git?" -Default $false
            }
        }
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Section "DEPLOYMENT SUMMARY"
    Write-Host ""

    $selectedLabels = [System.Collections.Generic.List[string]]::new()
    $selectedLabels.Add("CPE (required)")
    foreach ($c in $componentDefs) {
        if ($selections[$c.Var]) { $selectedLabels.Add($c.Label) }
    }
    Write-Host ("  Components : " + ($selectedLabels -join ", ")) -ForegroundColor White

    $modeStr = switch ($modeChoice) {
        "1" { "Full deployment  (steps 1 - 8)" }
        "2" { "Steps 2 - 8  (Step 1 skipped, install pod reused)" }
        "3" { "Step $wizardStep only" }
        "4" {
            if ($wizardSkipSteps.Count -gt 0) {
                "Steps 1-8 skipping: $($wizardSkipSteps -join ', ')"
            } else {
                "Full deployment  (steps 1 - 8)"
            }
        }
    }
    Write-Host "  Run mode   : $modeStr" -ForegroundColor White

    if ($step7WillRun) {
        $certStr = if ($importCerts) { "Import after Step 7  (UAC prompt)" } else { "Skip" }
        Write-Host "  Certs      : $certStr" -ForegroundColor White
    }

    $argoStr = if ($wizardArgoCD) {
        if ($wizardArgoCDRepo) { "Monitor '$FNCM_NAMESPACE'  <--  $wizardArgoCDRepo @ $wizardArgoCDRevision" }
        else                   { "Enabled (access configured only -- no repo URL, Application skipped)" }
    } else { "Skipped" }
    Write-Host "  ArgoCD     : $argoStr" -ForegroundColor White

    Write-Host ""

    if (-not (Read-YesNo -Prompt "Proceed with deployment?" -Default $true)) {
        Write-Host ""
        Write-Host "  Deployment cancelled." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    # Apply wizard choices as the active run parameters
    $Step      = $wizardStep
    $SkipSteps = $wizardSkipSteps

    # ── Write config.session.ps1 with selected component flags ────────────────
    $sessionContent = [System.Collections.Generic.List[string]]::new()
    $sessionContent.Add("# Session overrides - auto-generated by Install-FNCM.ps1 wizard")
    $sessionContent.Add("# DO NOT EDIT - managed by the installer")
    $sessionContent.Add("")
    $sessionContent.Add('$DEPLOY_CPE     = $true')
    foreach ($c in $componentDefs) {
        $tf     = boolStr $selections[$c.Var]
        $varPad = $c.Var.PadRight(14)
        $sessionContent.Add("`$$varPad = $tf")
    }
    $sessionContent.Add("")
    $sessionContent.Add("# ArgoCD / GitOps")
    $sessionContent.Add("`$CONFIGURE_ARGOCD               = $(boolStr $wizardArgoCD)")
    $sessionContent.Add("`$ARGOCD_GITOPS_REPO_URL         = `"$wizardArgoCDRepo`"")
    $sessionContent.Add("`$ARGOCD_GITOPS_REPO_PATH        = `"$wizardArgoCDPath`"")
    $sessionContent.Add("`$ARGOCD_GITOPS_REVISION         = `"$wizardArgoCDRevision`"")
    $sessionContent.Add("`$ARGOCD_GITOPS_LOCAL_REPO_PATH  = `"$wizardArgoCDLocalPath`"")
    $sessionContent.Add("`$ARGOCD_AUTO_SYNC               = $(boolStr $wizardArgoCDAutoSync)")
    $sessionContent.Add("`$ARGOCD_SELF_HEAL               = $(boolStr $wizardArgoCDSelfHeal)")
    $sessionContent.Add("`$ARGOCD_PRUNE                   = $(boolStr $wizardArgoCDPrune)")
    $sessionContent | Set-Content -Path $sessionCfgPath -Encoding UTF8
    Write-Host ""
    Write-Log "Component selections written to config.session.ps1." "INFO"

} else {
    # ── Non-wizard path ────────────────────────────────────────────────────────
    # -Force / -Step / -SkipSteps given: mirror config.ps1 values into
    # config.session.ps1 so step scripts are consistent.
    $sessionContent = [System.Collections.Generic.List[string]]::new()
    $sessionContent.Add("# Session overrides - auto-generated by Install-FNCM.ps1")
    $sessionContent.Add("# Mirrors config.ps1 component flags for this run")
    $sessionContent.Add("")
    $sessionContent.Add('$DEPLOY_CPE     = $true')
    $sessionContent.Add("`$DEPLOY_GRAPHQL = $(boolStr $DEPLOY_GRAPHQL)")
    $sessionContent.Add("`$DEPLOY_BAN     = $(boolStr $DEPLOY_BAN)")
    $sessionContent.Add("`$DEPLOY_CSS     = $(boolStr $DEPLOY_CSS)")
    $sessionContent.Add("`$DEPLOY_CMIS    = $(boolStr $DEPLOY_CMIS)")
    $sessionContent.Add("`$DEPLOY_TM      = $(boolStr $DEPLOY_TM)")
    $sessionContent.Add("`$DEPLOY_ES      = $(boolStr $DEPLOY_ES)")
    $sessionContent.Add("`$DEPLOY_IER     = $(boolStr $DEPLOY_IER)")
    $sessionContent.Add("`$DEPLOY_ICCSAP  = $(boolStr $DEPLOY_ICCSAP)")
    $sessionContent.Add("")
    $sessionContent.Add("# ArgoCD / GitOps")
    $sessionContent.Add("`$CONFIGURE_ARGOCD               = $(boolStr $CONFIGURE_ARGOCD)")
    $sessionContent.Add("`$ARGOCD_GITOPS_REPO_URL         = `"$ARGOCD_GITOPS_REPO_URL`"")
    $sessionContent.Add("`$ARGOCD_GITOPS_REPO_PATH        = `"$ARGOCD_GITOPS_REPO_PATH`"")
    $sessionContent.Add("`$ARGOCD_GITOPS_REVISION         = `"$ARGOCD_GITOPS_REVISION`"")
    $localPathVal = if ($null -ne (Get-Variable 'ARGOCD_GITOPS_LOCAL_REPO_PATH' -ErrorAction SilentlyContinue)) { $ARGOCD_GITOPS_LOCAL_REPO_PATH } else { "" }
    $sessionContent.Add("`$ARGOCD_GITOPS_LOCAL_REPO_PATH  = `"$localPathVal`"")
    $sessionContent.Add("`$ARGOCD_AUTO_SYNC               = $(boolStr $ARGOCD_AUTO_SYNC)")
    $sessionContent.Add("`$ARGOCD_SELF_HEAL               = $(boolStr $ARGOCD_SELF_HEAL)")
    $sessionContent.Add("`$ARGOCD_PRUNE                   = $(boolStr $ARGOCD_PRUNE)")
    $sessionContent | Set-Content -Path $sessionCfgPath -Encoding UTF8
}

# ── Banner ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Log "================================================" "STEP"
Write-Log "  IBM FNCM Automated Deployment" "STEP"
Write-Log "================================================" "STEP"
Write-Log "Cluster   : $OCP_API_URL" "INFO"
Write-Log "Namespace : $FNCM_NAMESPACE" "INFO"
Write-Log "Storage   : $STORAGE_CLASS_NAME" "INFO"

# ── Run steps ──────────────────────────────────────────────────────────────────
$deployFailed    = $false
$failedStepNum   = 0

try {
    foreach ($s in $allSteps) {
        if ($Step -ne 0 -and $s.N -ne $Step)  { continue }
        if ($s.N -in $SkipSteps) {
            Write-Log "Skipping Step $($s.N): $($s.Name)" "WARN"
            continue
        }

        Write-Log "" "INFO"
        Write-Log "--- Step $($s.N): $($s.Name) ---" "STEP"
        try {
            & $s.Script
            Write-Log "Step $($s.N) completed." "SUCCESS"
        } catch {
            Write-Log "Step $($s.N) FAILED: $_" "ERROR"
            $deployFailed  = $true
            $failedStepNum = $s.N
            break
        }
    }
} finally {
    # Always clean up the session config on exit (success or failure)
    if (Test-Path $sessionCfgPath) {
        Remove-Item $sessionCfgPath -Force -ErrorAction SilentlyContinue
    }
}

if ($deployFailed) {
    Write-Log "" "INFO"
    Write-Log "Deployment stopped at Step $failedStepNum." "ERROR"
    Write-Log "Resolve the error above, then re-run the step:" "WARN"
    Write-Log "  .\Install-FNCM.ps1 -Step $failedStepNum             (uses config.ps1 defaults)" "WARN"
    Write-Log "  .\Install-FNCM.ps1                                  (re-run the interactive wizard)" "WARN"
    exit 1
}

Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  FNCM Deployment Complete!" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "Access URLs are in ConfigMap 'fncmdeploy-fncm-access-info':" "INFO"
Write-Log "  oc get cm fncmdeploy-fncm-access-info -n $FNCM_NAMESPACE -o yaml" "INFO"

# ── Post-deploy: import CA certificates into the workstation trust store ───────
$step7Ran = (-not $SkipCerts) -and ($Step -eq 0 -or $Step -eq 7) -and (7 -notin $SkipSteps)
if ($step7Ran) {
    Write-Log "" "INFO"
    Write-Log "--- Post-deploy: Importing CA certificates into workstation trust store ---" "STEP"
    $certScript = Join-Path $PSScriptRoot "Add-ClusterCerts.ps1"
    if (Test-Path $certScript) {
        try {
            & $certScript -Namespace $FNCM_NAMESPACE
        } catch {
            Write-Log "Certificate import encountered an error: $_" "WARN"
            Write-Log "Run manually to trust FNCM endpoints:  .\Add-ClusterCerts.ps1" "WARN"
        }
    } else {
        Write-Log "Add-ClusterCerts.ps1 not found -- run it manually to trust FNCM endpoints." "WARN"
    }
} elseif ($SkipCerts) {
    Write-Log "" "INFO"
    Write-Log "Certificate import skipped (-SkipCerts).  Run when ready:" "INFO"
    Write-Log "  .\Add-ClusterCerts.ps1" "INFO"
}
