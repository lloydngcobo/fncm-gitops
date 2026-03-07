#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Ansible AWX on Docker Desktop Kubernetes (Windows).

.DESCRIPTION
    Deploys AWX on the Kubernetes cluster that ships with Docker Desktop.
    Uses the same AWX Operator as the OpenShift install but with settings
    appropriate for a local, non-OpenShift cluster:

      - No SecurityContextConstraints (not an OpenShift feature)
      - No OpenShift Routes -- exposes AWX via a fixed NodePort (default: 31080)
        Access URL: http://localhost:31080
      - Storage via Docker Desktop's built-in 'hostpath' StorageClass
      - Uses 'kubectl' (bundled with Docker Desktop)

    Steps:
      1. Verify Docker Desktop Kubernetes is running and the context is active
      2. Create the AWX namespace
      3. Install the AWX Operator via kustomize
      4. Wait for the AWX Operator pod to become ready
      5. Create an AWX instance CR
      6. Wait for AWX to finish provisioning
      7. Patch the web service to use a fixed NodePort
      8. Retrieve admin credentials and print the access URL

    Pre-requisites:
      - Docker Desktop with Kubernetes enabled
        (Docker Desktop → Settings → Kubernetes → Enable Kubernetes)
      - kubectl available in PATH  (Docker Desktop installs it automatically)
      - Internet access (downloads AWX Operator manifests from GitHub)

    To enable Kubernetes in Docker Desktop:
      Open Docker Desktop → Settings → Kubernetes → check "Enable Kubernetes" → Apply & Restart

.PARAMETER Uninstall
    Remove AWX and all associated resources from Docker Desktop Kubernetes.

.PARAMETER Namespace
    Kubernetes namespace for AWX. Default: awx

.PARAMETER OperatorVersion
    AWX Operator version. Check https://github.com/ansible/awx-operator/releases
    Default: 2.19.1

.PARAMETER AwxName
    Name of the AWX instance. Default: awx

.PARAMETER StorageClass
    StorageClass for the embedded PostgreSQL PVC.
    Default: hostpath  (Docker Desktop's built-in provisioner)

.PARAMETER StorageSize
    PostgreSQL PVC size. Default: 8Gi

.PARAMETER WebPort
    NodePort for the AWX web UI. Must be in range 30000-32767. Default: 31080
    Access AWX at http://localhost:<WebPort>

.PARAMETER AdminUser
    AWX admin username. Default: admin

.PARAMETER AdminEmail
    AWX admin email. Default: admin@localhost

.PARAMETER TimeoutMinutes
    Maximum minutes to wait for AWX to provision. Default: 20

.PARAMETER KubeContext
    Kubernetes context to use. Default: docker-desktop
    Run 'kubectl config get-contexts' to list available contexts.

.EXAMPLE
    # Install with defaults -- opens at http://localhost:31080
    .\Install-AWX-Docker.ps1

    # Use a custom port
    .\Install-AWX-Docker.ps1 -WebPort 30800

    # Remove AWX from Docker Desktop
    .\Install-AWX-Docker.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [string] $Namespace       = "awx",
    [string] $OperatorVersion = "2.19.1",
    [string] $AwxName         = "awx",
    [string] $StorageClass    = "hostpath",
    [string] $StorageSize     = "8Gi",
    [int]    $WebPort         = 31080,
    [string] $AdminUser       = "admin",
    [string] $AdminEmail      = "admin@localhost",
    [int]    $TimeoutMinutes  = 20,
    [string] $KubeContext     = "docker-desktop"
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

# Wrapper: run kubectl with the target context.
# IMPORTANT: this must be a *simple* function (no param() block, no [CmdletBinding()]).
# A simple function receives all arguments in the automatic $args variable and passes
# them straight through to kubectl WITHOUT PowerShell's parameter binding.  If we used
# [Parameter(ValueFromRemainingArguments)] the function would become an "advanced function"
# and PowerShell would try to bind -o as an abbreviation of -OutVariable / -OutBuffer.
function Invoke-Kubectl {
    # $input forwards any pipeline data (e.g. YAML piped to 'apply -f -') to kubectl stdin.
    # For non-piped calls $input is an empty enumerator -> kubectl gets EOF immediately (harmless).
    $input | & kubectl --context $KubeContext @args
}

function Apply-Yaml {
    param(
        [Parameter(Mandatory)][string]$Yaml,
        [string]$Description = "resource"
    )
    Write-Log "Applying: $Description" "INFO"
    $output = $Yaml | Invoke-Kubectl apply -f - 2>&1
    $output | ForEach-Object { Write-Log "  $_" "DEBUG" }
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply $Description`n$output" }
    Write-Log "Applied: $Description" "SUCCESS"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
try { $null = & kubectl version --client 2>&1 } catch {
    Write-Log "kubectl not found in PATH." "ERROR"
    Write-Log "Install Docker Desktop and enable Kubernetes, or install kubectl separately." "ERROR"
    exit 1
}

# Check the target context exists
$contexts = & kubectl config get-contexts -o name 2>&1
if ($contexts -notcontains $KubeContext) {
    Write-Log "Kubernetes context '$KubeContext' not found." "ERROR"
    Write-Log "Available contexts:" "INFO"
    $contexts | ForEach-Object { Write-Log "  $_" "INFO" }
    Write-Log "" "INFO"
    Write-Log "To enable Kubernetes in Docker Desktop:" "WARN"
    Write-Log "  Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & Restart" "WARN"
    exit 1
}

# Switch to the target context for this session
& kubectl config use-context $KubeContext 2>&1 | Out-Null
Write-Log "Using Kubernetes context: $KubeContext" "INFO"

# Verify cluster is reachable
$null = Invoke-Kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "Cannot reach Kubernetes cluster. Is Docker Desktop running with Kubernetes enabled?" "ERROR"
    exit 1
}

# ── Uninstall path ─────────────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host ""
    Write-Log "================================================" "WARN"
    Write-Log "  Removing AWX from Docker Desktop Kubernetes" "WARN"
    Write-Log "================================================" "WARN"
    Write-Log "Namespace : $Namespace   AWX instance : $AwxName" "INFO"
    Write-Host ""

    Write-Log "[1/3] Removing AWX CR and namespace..." "INFO"
    Invoke-Kubectl patch awx $AwxName -n $Namespace --type=json `
        -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>&1 | Out-Null
    Invoke-Kubectl delete awx $AwxName -n $Namespace --ignore-not-found=true 2>&1 | Out-Null
    Invoke-Kubectl delete namespace $Namespace --wait=false --ignore-not-found=true 2>&1 | Out-Null
    Write-Log "Namespace deletion initiated." "SUCCESS"

    Write-Log "[2/3] Removing cluster-scoped RBAC..." "INFO"
    Invoke-Kubectl delete clusterrolebinding awx-operator-proxy-rolebinding --ignore-not-found=true 2>&1 | Out-Null
    Invoke-Kubectl delete clusterrole awx-operator-metrics-reader awx-operator-proxy-role --ignore-not-found=true 2>&1 | Out-Null
    Write-Log "Cluster RBAC removed." "SUCCESS"

    Write-Log "[3/3] Removing AWX CRDs..." "INFO"
    @("awxbackups.awx.ansible.com","awxmeshingresses.awx.ansible.com",
      "awxrestores.awx.ansible.com","awxs.awx.ansible.com") | ForEach-Object {
        Invoke-Kubectl delete crd $_ --ignore-not-found=true 2>&1 | Out-Null
        Write-Log "  Deleted: $_" "DEBUG"
    }
    Write-Log "CRDs removed." "SUCCESS"

    Write-Log "" "INFO"
    Write-Log "AWX removed from Docker Desktop Kubernetes." "SUCCESS"
    exit 0
}

# ── Banner ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Log "================================================" "STEP"
Write-Log "  Ansible AWX on Docker Desktop Kubernetes" "STEP"
Write-Log "================================================" "STEP"
Write-Log "Context          : $KubeContext" "INFO"
Write-Log "Namespace        : $Namespace" "INFO"
Write-Log "Operator version : $OperatorVersion" "INFO"
Write-Log "AWX instance     : $AwxName" "INFO"
Write-Log "Access URL       : http://localhost:$WebPort" "INFO"
Write-Log "Storage class    : $StorageClass  ($StorageSize)" "INFO"
Write-Host ""

# ── 1. Create namespace ────────────────────────────────────────────────────────
Write-Log "[1/7] Creating namespace '$Namespace'..." "STEP"
$null = Invoke-Kubectl create namespace $Namespace 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Log "Namespace '$Namespace' created." "SUCCESS"
} else {
    Write-Log "Namespace '$Namespace' already exists -- continuing." "INFO"
}

# ── 2. Install AWX Operator via kustomize ─────────────────────────────────────
Write-Log "[2/7] Installing AWX Operator $OperatorVersion via kustomize..." "STEP"
Write-Log "  (Downloads AWX Operator manifests from GitHub -- requires internet)" "INFO"

$tempDir = Join-Path $env:TEMP "awx-docker-operator-$OperatorVersion"
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
$output = & kubectl --context $KubeContext apply -k $tempDir 2>&1
$output | ForEach-Object { Write-Log "  $_" "DEBUG" }
if ($LASTEXITCODE -ne 0) {
    throw "AWX Operator installation failed.`n$output"
}
Write-Log "AWX Operator manifests applied." "SUCCESS"

# ── 3. Wait for AWX Operator to be ready ──────────────────────────────────────
Write-Log "[3/7] Waiting for AWX Operator to become ready (up to 10 min)..." "STEP"
$opDeadline = (Get-Date).AddMinutes(10)
$opReady    = $false
while ((Get-Date) -lt $opDeadline) {
    $ready = [string](Invoke-Kubectl get deployment awx-operator-controller-manager -n $Namespace `
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
    Write-Log "Check: kubectl --context $KubeContext get pods -n $Namespace" "WARN"
}

# ── 4. Create AWX Custom Resource ─────────────────────────────────────────────
# Note: No ingress_type: Route (not OpenShift) -- we use NodePort instead.
#       No SCC grants needed -- standard Kubernetes doesn't use SCCs.
Write-Log "[4/7] Creating AWX instance '$AwxName'..." "STEP"

Apply-Yaml @"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: $AwxName
  namespace: $Namespace
  labels:
    app.kubernetes.io/managed-by: Install-AWX-Docker.ps1
spec:
  # NodePort exposes AWX on the node (localhost in Docker Desktop)
  service_type: NodePort
  ingress_type: none

  # Admin credentials
  admin_user: $AdminUser
  admin_email: $AdminEmail

  # Docker Desktop's built-in storage class
  postgres_storage_class: $StorageClass
  postgres_storage_requirements:
    requests:
      storage: $StorageSize
    limits:
      storage: $StorageSize

  # Single replicas for a local install
  web_replicas: 1
  task_replicas: 1
"@ "AWX/$AwxName"

# ── 5. Wait for AWX web deployment to become ready ────────────────────────────
Write-Log "[5/7] Waiting for AWX to finish provisioning (up to $TimeoutMinutes min)..." "STEP"
Write-Log "  Includes: PostgreSQL init, database migrations, AWX container pull." "INFO"

$awxDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
$webReady    = $false

while ((Get-Date) -lt $awxDeadline) {
    $ready = [string](Invoke-Kubectl get deployment "${AwxName}-web" -n $Namespace `
        -o jsonpath='{.status.readyReplicas}' 2>&1)
    if ($LASTEXITCODE -eq 0 -and $ready.Trim() -eq "1") {
        $webReady = $true
        Write-Log "AWX web deployment is ready." "SUCCESS"
        break
    }
    $pods = Invoke-Kubectl get pods -n $Namespace --no-headers 2>&1
    $rem  = [int](($awxDeadline - (Get-Date)).TotalSeconds / 60)
    Write-Log "  Still provisioning...  ($rem min remaining)" "INFO"
    $pods -split "`n" | Where-Object { $_ -ne "" } |
        ForEach-Object { Write-Log "    $_" "DEBUG" }
    Start-Sleep -Seconds 30
}

if (-not $webReady) {
    Write-Log "AWX did not become ready within $TimeoutMinutes min." "WARN"
    Write-Log "Check: kubectl --context $KubeContext get pods -n $Namespace" "WARN"
    Write-Log "Check: kubectl --context $KubeContext describe awx $AwxName -n $Namespace" "WARN"
}

# ── 6. Pin the NodePort to a fixed port number ────────────────────────────────
Write-Log "[6/7] Patching AWX service to use fixed NodePort $WebPort..." "STEP"

# Find the service name (AWX Operator names it '<awxname>-service')
$svcName = "${AwxName}-service"
$svcExists = [string](Invoke-Kubectl get svc $svcName -n $Namespace 2>&1)
if ($LASTEXITCODE -ne 0) {
    # Fallback: try just the AWX name
    $svcName = $AwxName
    $svcExists = [string](Invoke-Kubectl get svc $svcName -n $Namespace 2>&1)
}

if ($LASTEXITCODE -eq 0) {
    # Patch the first port entry to set a fixed nodePort
    $patch = @"
{"spec":{"ports":[{"port":80,"targetPort":8052,"nodePort":$WebPort}],"type":"NodePort"}}
"@
    Invoke-Kubectl patch svc $svcName -n $Namespace --type=merge -p $patch 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "NodePort $WebPort pinned on service '$svcName'." "SUCCESS"
    } else {
        Write-Log "Could not pin NodePort -- AWX will be on a random port." "WARN"
        Write-Log "Run: kubectl --context $KubeContext get svc -n $Namespace" "WARN"
    }
} else {
    Write-Log "Service '$svcName' not found -- AWX may use a random NodePort." "WARN"
    Write-Log "Run: kubectl --context $KubeContext get svc -n $Namespace" "WARN"
}

# ── 7. Retrieve admin credentials ─────────────────────────────────────────────
Write-Log "[7/7] Retrieving admin credentials..." "STEP"

$secretName = "${AwxName}-admin-password"
$b64Pass    = [string](Invoke-Kubectl get secret $secretName -n $Namespace `
    -o jsonpath='{.data.password}' 2>&1)
$adminPass  = if ($LASTEXITCODE -eq 0 -and $b64Pass.Trim()) {
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Pass.Trim()))
} else {
    "<run: kubectl --context $KubeContext get secret $secretName -n $Namespace -o jsonpath='{.data.password}' | base64 -d>"
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  Ansible AWX on Docker Desktop -- Ready!" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "" "INFO"
Write-Log "  AWX URL   : http://localhost:$WebPort" "SUCCESS"
Write-Log "  Username  : $AdminUser" "INFO"
Write-Log "  Password  : $adminPass" "INFO"
Write-Log "" "INFO"
Write-Log "  Context   : $KubeContext" "INFO"
Write-Log "  Namespace : $Namespace" "INFO"
Write-Log "  Version   : AWX Operator $OperatorVersion" "INFO"
Write-Log "" "INFO"
Write-Log "  Useful commands:" "INFO"
Write-Log "    kubectl --context $KubeContext get pods -n $Namespace" "INFO"
Write-Log "    kubectl --context $KubeContext get awx -n $Namespace" "INFO"
Write-Log "    kubectl --context $KubeContext describe awx $AwxName -n $Namespace" "INFO"
Write-Log "" "INFO"
Write-Log "  To remove AWX from Docker Desktop:" "INFO"
Write-Log "    .\Install-AWX-Docker.ps1 -Uninstall" "INFO"
