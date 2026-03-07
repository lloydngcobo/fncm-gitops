#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Ansible AWX on OpenShift using the AWX Operator.

.DESCRIPTION
    Deploys AWX (upstream Ansible Automation Platform) on your OpenShift cluster:

      1. Creates the AWX namespace
      2. Installs the AWX Operator via kustomize (bundled in oc CLI v4.x)
      3. Waits for the AWX Operator pod to become ready
      4. Grants required SecurityContextConstraints for AWX pods
      5. Creates an AWX instance CR (OpenShift Route for external access)
      6. Waits for AWX to finish provisioning
      7. Retrieves admin credentials and prints the access URL

    Pre-requisites:
      - oc CLI (v4.x) installed and logged in to your OpenShift cluster
      - Internet access from the workstation (downloads AWX Operator manifests from GitHub)
      - A StorageClass for the embedded PostgreSQL PVC (RWO is sufficient)

    To remove AWX:
      .\Install-AWX.ps1 -Uninstall

.PARAMETER Uninstall
    Remove AWX and all associated resources from the cluster.
    Deletes: AWX CR, namespace, operator CRDs, and cluster-scoped RBAC.
    The OpenShift GitOps / ArgoCD operator is NOT removed.

.PARAMETER Namespace
    Namespace to install AWX into. Default: awx

.PARAMETER OperatorVersion
    AWX Operator version to install.
    Check https://github.com/ansible/awx-operator/releases for the latest.
    Default: 2.19.1

.PARAMETER AwxName
    Name of the AWX instance and derived resource names. Default: awx

.PARAMETER StorageClass
    StorageClass for the embedded PostgreSQL PVC. Default: nfs-homelab

.PARAMETER StorageSize
    Size of the PostgreSQL PVC. Default: 8Gi

.PARAMETER AdminUser
    AWX admin username. Default: admin

.PARAMETER AdminEmail
    AWX admin contact email. Default: admin@homelab.home.nl

.PARAMETER TimeoutMinutes
    Maximum time to wait for AWX to finish provisioning. Default: 20

.EXAMPLE
    # Install with defaults
    .\Install-AWX.ps1

    # Install a specific operator version
    .\Install-AWX.ps1 -OperatorVersion 2.19.1

    # Custom namespace, storage, and timeout
    .\Install-AWX.ps1 -Namespace my-awx -StorageClass csi-nfs -StorageSize 20Gi -TimeoutMinutes 30
#>
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [string] $Namespace       = "awx",
    [string] $OperatorVersion = "2.19.1",
    [string] $AwxName         = "awx",
    [string] $StorageClass    = "nfs-homelab",
    [string] $StorageSize     = "8Gi",
    [string] $AdminUser       = "admin",
    [string] $AdminEmail      = "admin@homelab.home.nl",
    [int]    $TimeoutMinutes  = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Logging helper ─────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","STEP","DEBUG")]
        [string]$Level = "INFO"
    )
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan"    }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        "SUCCESS" { "Green"   }
        "STEP"    { "Magenta" }
        "DEBUG"   { "Gray"    }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Apply-Yaml {
    param(
        [Parameter(Mandatory)][string]$Yaml,
        [string]$Description = "resource"
    )
    Write-Log "Applying: $Description" "INFO"
    $output = $Yaml | & oc apply -f - 2>&1
    $output | ForEach-Object { Write-Log "  $_" "DEBUG" }
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply $Description`n$output" }
    Write-Log "Applied: $Description" "SUCCESS"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
try { $null = & oc version --client 2>&1 } catch {
    Write-Log "oc CLI not found in PATH. Install it and add to PATH." "ERROR"; exit 1
}
$whoami = & oc whoami 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "Not logged in to OpenShift. Run 'oc login' first." "ERROR"; exit 1
}

# ── Uninstall path ─────────────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host ""
    Write-Log "================================================" "WARN"
    Write-Log "  Removing AWX from OpenShift" "WARN"
    Write-Log "================================================" "WARN"
    Write-Log "Namespace : $Namespace   AWX instance : $AwxName" "INFO"
    Write-Host ""

    # Strip finalizer so CR deletion doesn't block waiting for the operator
    Write-Log "[1/4] Stripping AWX CR finalizer..." "INFO"
    & oc patch awx $AwxName -n $Namespace --type=json `
        -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>&1 | Out-Null
    & oc delete awx $AwxName -n $Namespace --ignore-not-found=true 2>&1 | Out-Null
    Write-Log "AWX CR deleted." "SUCCESS"

    Write-Log "[2/4] Deleting namespace '$Namespace' (removes all namespaced resources)..." "INFO"
    & oc delete namespace $Namespace --wait=false --ignore-not-found=true 2>&1 | Out-Null
    Write-Log "Namespace deletion initiated (runs async)." "SUCCESS"

    Write-Log "[3/4] Removing cluster-scoped RBAC created by the AWX Operator..." "INFO"
    & oc delete clusterrolebinding awx-operator-proxy-rolebinding --ignore-not-found=true 2>&1 | Out-Null
    & oc delete clusterrole awx-operator-metrics-reader awx-operator-proxy-role --ignore-not-found=true 2>&1 | Out-Null
    Write-Log "Cluster RBAC removed." "SUCCESS"

    Write-Log "[4/4] Removing AWX CRDs..." "INFO"
    $crdNames = @(
        "awxbackups.awx.ansible.com",
        "awxmeshingresses.awx.ansible.com",
        "awxrestores.awx.ansible.com",
        "awxs.awx.ansible.com"
    )
    foreach ($crd in $crdNames) {
        & oc delete crd $crd --ignore-not-found=true 2>&1 | Out-Null
        Write-Log "  Deleted CRD: $crd" "DEBUG"
    }
    Write-Log "CRDs removed." "SUCCESS"

    Write-Log "" "INFO"
    Write-Log "AWX removed from OpenShift." "SUCCESS"
    Write-Log "Note: namespace '$Namespace' terminates asynchronously." "INFO"
    Write-Log "Check: oc get namespace $Namespace" "INFO"
    exit 0
}

# Auto-detect cluster ingress domain for the AWX Route
$clusterDomain = (& oc get ingresses.config.openshift.io cluster `
    -o jsonpath='{.spec.domain}' 2>&1).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clusterDomain)) {
    $clusterDomain = "apps.homelab.home.nl"
    Write-Log "Could not detect ingress domain -- using: $clusterDomain" "WARN"
}
$awxHostname = "${AwxName}.${clusterDomain}"

Write-Host ""
Write-Log "================================================" "STEP"
Write-Log "  Ansible AWX on OpenShift" "STEP"
Write-Log "================================================" "STEP"
Write-Log "Authenticated as : $whoami" "INFO"
Write-Log "Namespace        : $Namespace" "INFO"
Write-Log "Operator version : $OperatorVersion" "INFO"
Write-Log "AWX instance     : $AwxName" "INFO"
Write-Log "AWX hostname     : $awxHostname" "INFO"
Write-Log "Storage class    : $StorageClass  ($StorageSize)" "INFO"
Write-Host ""

# ── 1. Create namespace ────────────────────────────────────────────────────────
Write-Log "[1/6] Creating namespace '$Namespace'..." "STEP"
$null = & oc create namespace $Namespace 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Log "Namespace '$Namespace' created." "SUCCESS"
} else {
    Write-Log "Namespace '$Namespace' already exists -- continuing." "INFO"
}

# ── 2. Install AWX Operator via kustomize ─────────────────────────────────────
Write-Log "[2/6] Installing AWX Operator $OperatorVersion via kustomize..." "STEP"
Write-Log "  (Downloads AWX Operator manifests from GitHub -- requires internet)" "INFO"

# Write kustomization.yaml to a temp folder and apply with the oc-bundled kustomize
$tempDir = Join-Path $env:TEMP "awx-operator-$OperatorVersion"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

[System.IO.File]::WriteAllText("$tempDir\kustomization.yaml", @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $Namespace
resources:
  - github.com/ansible/awx-operator/config/default?ref=$OperatorVersion
images:
  - name: quay.io/ansible/awx-operator
    newTag: $OperatorVersion
  # gcr.io/kubebuilder was deprecated; kube-rbac-proxy moved to quay.io/brancz
  - name: gcr.io/kubebuilder/kube-rbac-proxy
    newName: quay.io/brancz/kube-rbac-proxy
    newTag: v0.15.0
"@)

Write-Log "  Applying kustomize from: $tempDir" "DEBUG"
$output = & oc apply -k $tempDir 2>&1
$output | ForEach-Object { Write-Log "  $_" "DEBUG" }
if ($LASTEXITCODE -ne 0) {
    throw "AWX Operator installation failed.`n$output"
}
Write-Log "AWX Operator manifests applied." "SUCCESS"

# ── 3. Wait for AWX Operator to be ready ──────────────────────────────────────
Write-Log "[3/6] Waiting for AWX Operator to become ready (up to 10 min)..." "STEP"
$opDeadline = (Get-Date).AddMinutes(10)
$opReady    = $false
while ((Get-Date) -lt $opDeadline) {
    $ready = [string](& oc get deployment awx-operator-controller-manager -n $Namespace `
        -o jsonpath='{.status.readyReplicas}' 2>&1)
    if ($LASTEXITCODE -eq 0 -and $ready.Trim() -eq "1") {
        $opReady = $true
        Write-Log "AWX Operator is ready." "SUCCESS"
        break
    }
    $rem = [int](($opDeadline - (Get-Date)).TotalSeconds / 60)
    Write-Log "  Waiting for operator pod... ($rem min remaining)" "INFO"
    Start-Sleep -Seconds 15
}
if (-not $opReady) {
    Write-Log "Operator did not become ready in 10 min -- continuing anyway." "WARN"
    Write-Log "Check: oc get pods -n $Namespace" "WARN"
}

# ── 4. Grant SecurityContextConstraints ───────────────────────────────────────
# AWX task/web/ee containers run as specific UIDs -- anyuid is required on OCP.
# Grant to both 'default' and 'awx' service accounts (operator creates 'awx' SA).
Write-Log "[4/6] Granting 'anyuid' SCC to AWX service accounts..." "STEP"
$sas = @("default", $AwxName)
foreach ($sa in $sas) {
    & oc adm policy add-scc-to-user anyuid `
        "system:serviceaccount:${Namespace}:${sa}" 2>&1 | Out-Null
    Write-Log "  anyuid granted to serviceaccount/$sa" "INFO"
}
Write-Log "SCC grants applied." "SUCCESS"

# ── 5. Create AWX Custom Resource ─────────────────────────────────────────────
Write-Log "[5/6] Creating AWX instance '$AwxName'..." "STEP"

Apply-Yaml @"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: $AwxName
  namespace: $Namespace
  labels:
    app.kubernetes.io/managed-by: Install-AWX.ps1
spec:
  # OpenShift Route for external HTTPS access (auto-created by the operator)
  service_type: ClusterIP
  ingress_type: Route
  hostname: $awxHostname

  # Admin credentials
  admin_user: $AdminUser
  admin_email: $AdminEmail

  # Embedded PostgreSQL storage
  postgres_storage_class: $StorageClass
  postgres_storage_requirements:
    requests:
      storage: $StorageSize
    limits:
      storage: $StorageSize

  # Single replicas for a homelab install (increase for production)
  web_replicas: 1
  task_replicas: 1
"@ "AWX/$AwxName"

# ── 6. Wait for AWX web deployment to become ready ────────────────────────────
Write-Log "[6/6] Waiting for AWX to finish provisioning (up to $TimeoutMinutes min)..." "STEP"
Write-Log "  Includes: PostgreSQL init, database migrations, AWX container pull." "INFO"

$awxDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
$webReady    = $false

while ((Get-Date) -lt $awxDeadline) {
    $ready = [string](& oc get deployment "${AwxName}-web" -n $Namespace `
        -o jsonpath='{.status.readyReplicas}' 2>&1)
    if ($LASTEXITCODE -eq 0 -and $ready.Trim() -eq "1") {
        $webReady = $true
        Write-Log "AWX web deployment is ready." "SUCCESS"
        break
    }

    # Show pod table so the user can see what is happening
    $pods = & oc get pods -n $Namespace --no-headers 2>&1
    $rem  = [int](($awxDeadline - (Get-Date)).TotalSeconds / 60)
    Write-Log "  Still provisioning...  ($rem min remaining)" "INFO"
    $pods -split "`n" | Where-Object { $_ -ne "" } |
        ForEach-Object { Write-Log "    $_" "DEBUG" }
    Start-Sleep -Seconds 30
}

if (-not $webReady) {
    Write-Log "" "INFO"
    Write-Log "AWX did not become ready within $TimeoutMinutes min." "WARN"
    Write-Log "Check with:" "WARN"
    Write-Log "  oc get pods -n $Namespace" "WARN"
    Write-Log "  oc describe awx $AwxName -n $Namespace" "WARN"
    Write-Log "  oc logs -n $Namespace deployment/${AwxName}-web" "WARN"
}

# ── Retrieve admin credentials ─────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "Retrieving admin credentials..." "INFO"

$secretName = "${AwxName}-admin-password"
$b64Pass    = (& oc get secret $secretName -n $Namespace `
    -o jsonpath='{.data.password}' 2>&1).Trim()
$adminPass  = if ($LASTEXITCODE -eq 0 -and $b64Pass) {
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Pass))
} else {
    "<run: oc get secret $secretName -n $Namespace -o jsonpath='{.data.password}' | base64 -d>"
}

# The AWX Operator creates the Route named '<awxname>-<namespace>' when a
# custom hostname is set; fall back to auto-generated host if needed.
$routeHost = [string](& oc get route $AwxName -n $Namespace `
    -o jsonpath='{.spec.host}' 2>&1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($routeHost)) {
    # Try the '<name>-<namespace>' route name that OpenShift auto-creates
    $routeHost = [string](& oc get route "${AwxName}-${Namespace}" -n $Namespace `
        -o jsonpath='{.spec.host}' 2>&1)
}
$awxURL = if (-not [string]::IsNullOrWhiteSpace($routeHost)) {
    "https://$($routeHost.Trim())"
} else {
    "https://$awxHostname"
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  Ansible AWX Installation Complete" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "" "INFO"
Write-Log "  AWX URL      : $awxURL" "SUCCESS"
Write-Log "  Username     : $AdminUser" "INFO"
Write-Log "  Password     : $adminPass" "INFO"
Write-Log "" "INFO"
Write-Log "  Namespace    : $Namespace" "INFO"
Write-Log "  Operator ver : $OperatorVersion" "INFO"
Write-Log "" "INFO"
Write-Log "  Useful commands:" "INFO"
Write-Log "    oc get pods -n $Namespace                           # pod status" "INFO"
Write-Log "    oc get awx -n $Namespace                           # AWX CR status" "INFO"
Write-Log "    oc describe awx $AwxName -n $Namespace             # provisioning detail" "INFO"
Write-Log "    oc logs -n $Namespace -l app.kubernetes.io/name=${AwxName}-web  # web logs" "INFO"
Write-Log "" "INFO"
Write-Log "  To remove AWX completely:" "INFO"
Write-Log "    oc delete awx $AwxName -n $Namespace" "INFO"
Write-Log "    oc delete namespace $Namespace" "INFO"
Write-Log "    oc delete clusterrolebinding awx-operator-controller-manager-rolebinding" "INFO"
Write-Log "    oc delete clusterrole awx-operator-controller-manager-role" "INFO"
