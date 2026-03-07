# =============================================================================
# common.psm1  -  Shared utility functions for FNCM automated deployment
# =============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "STEP", "DEBUG")]
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

function Test-OCInstalled {
    try { $null = & oc version --client 2>&1; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

function Test-OCLogin {
    $result = & oc whoami 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Authenticated as: $result" "INFO"
        return $true
    }
    return $false
}

# Apply a YAML string via 'oc apply -f -'
function Apply-Yaml {
    param(
        [Parameter(Mandatory)] [string]$Yaml,
        [string]$Description = "resource"
    )
    Write-Log "Applying: $Description" "INFO"
    $output = $Yaml | & oc apply -f - 2>&1
    $output | ForEach-Object { Write-Log "  $_" "DEBUG" }
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply: $Description`n$output" }
    Write-Log "Applied: $Description" "SUCCESS"
}

# Wait for the first matching pod to have containerStatuses[0].ready == true
function Wait-PodReady {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$LabelSelector,
        [int]$TimeoutSeconds   = 600,
        [int]$PollIntervalSecs = 15
    )
    Write-Log "Waiting for pod (-l $LabelSelector) in '$Namespace' to be Ready..." "INFO"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ready = & oc get pods -n $Namespace -l $LabelSelector `
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>&1
        if ($LASTEXITCODE -eq 0 -and $ready -eq 'true') {
            Write-Log "Pod is Ready." "SUCCESS"
            return
        }
        $remaining = [int](($deadline - (Get-Date)).TotalSeconds)
        Write-Log "Not ready yet.  ${remaining}s remaining..." "INFO"
        Start-Sleep -Seconds $PollIntervalSecs
    }
    throw "Timeout: pod '$LabelSelector' in '$Namespace' did not become Ready in ${TimeoutSeconds}s"
}

function Wait-StatefulSetReady {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSeconds = 300
    )
    Write-Log "Waiting for StatefulSet '$Name' in '$Namespace'..." "INFO"
    & oc rollout status "statefulset/$Name" -n $Namespace --timeout="${TimeoutSeconds}s" 2>&1 |
        ForEach-Object { Write-Log "  $_" "DEBUG" }
    if ($LASTEXITCODE -ne 0) { throw "StatefulSet '$Name' did not become ready." }
    Write-Log "StatefulSet '$Name' is ready." "SUCCESS"
}

function Wait-DeploymentReady {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$Name,
        [int]$TimeoutSeconds = 300
    )
    Write-Log "Waiting for Deployment '$Name' in '$Namespace'..." "INFO"
    & oc rollout status "deployment/$Name" -n $Namespace --timeout="${TimeoutSeconds}s" 2>&1 |
        ForEach-Object { Write-Log "  $_" "DEBUG" }
    if ($LASTEXITCODE -ne 0) { throw "Deployment '$Name' did not become ready." }
    Write-Log "Deployment '$Name' is ready." "SUCCESS"
}

# Return the name of the first pod matching a label selector
function Get-PodName {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$LabelSelector
    )
    $name = & oc get pod -n $Namespace -l $LabelSelector `
        -o jsonpath='{.items[0].metadata.name}' 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($name)) {
        throw "No pod with label '$LabelSelector' found in namespace '$Namespace'"
    }
    return $name.Trim()
}

# Execute a bash command inside a running pod
# -Quiet : suppress the DEBUG echo of the command itself (output is still returned/thrown on error)
function Invoke-PodExec {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$PodName,
        [Parameter(Mandatory)] [string]$BashCommand,
        [switch]$Quiet
    )
    # Strip Windows CR so bash doesn't see $'\r' tokens
    $BashCommand = $BashCommand -replace "`r`n", "`n" -replace "`r", ""
    if (-not $Quiet) {
        Write-Log "exec [$PodName]: $BashCommand" "DEBUG"
    }
    $result = & oc exec -n $Namespace $PodName -- bash -c $BashCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed in pod '$PodName':`n$result"
    }
    return $result
}

# Copy a local file into a running pod  (oc cp)
function Copy-ToPod {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$PodName,
        [Parameter(Mandatory)] [string]$LocalPath,
        [Parameter(Mandatory)] [string]$RemotePath
    )
    Write-Log "Copying '$LocalPath' -> ${PodName}:${RemotePath}" "INFO"
    $parent = Split-Path $LocalPath -Parent
    $leaf   = Split-Path $LocalPath -Leaf
    Push-Location $parent
    try {
        & oc cp -n $Namespace $leaf "${PodName}:${RemotePath}" 2>&1 |
            ForEach-Object { Write-Log "  $_" "DEBUG" }
        if ($LASTEXITCODE -ne 0) { throw "oc cp failed: $LocalPath -> ${PodName}:${RemotePath}" }
    } finally {
        Pop-Location
    }
}

# Copy a file from a pod to the local machine (oc cp)
function Copy-FromPod {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$PodName,
        [Parameter(Mandatory)] [string]$RemotePath,
        [Parameter(Mandatory)] [string]$LocalPath
    )
    Write-Log "Copying ${PodName}:${RemotePath} -> '$LocalPath'" "INFO"
    $parent = Split-Path $LocalPath -Parent
    $leaf   = Split-Path $LocalPath -Leaf
    Push-Location $parent
    try {
        & oc cp -n $Namespace "${PodName}:${RemotePath}" $leaf 2>&1 |
            ForEach-Object { Write-Log "  $_" "DEBUG" }
        if ($LASTEXITCODE -ne 0) { throw "oc cp failed: ${PodName}:${RemotePath} -> $LocalPath" }
    } finally {
        Pop-Location
    }
}

# Write content to a temp file with Unix line endings; return the path
function Write-TempScript {
    param(
        [Parameter(Mandatory)] [string]$Content,
        [string]$Extension = ".sh"
    )
    $tmpFile = [System.IO.Path]::GetTempFileName() + $Extension
    # Write with Unix line endings
    $unix = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($tmpFile, $unix)
    return $tmpFile
}

# Test whether a named K8s resource exists
function Test-ResourceExists {
    param(
        [Parameter(Mandatory)] [string]$Kind,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Namespace = ""
    )
    if ($Namespace) {
        $null = & oc get $Kind $Name -n $Namespace 2>&1
    } else {
        $null = & oc get $Kind $Name 2>&1
    }
    return $LASTEXITCODE -eq 0
}

Export-ModuleMember -Function *
