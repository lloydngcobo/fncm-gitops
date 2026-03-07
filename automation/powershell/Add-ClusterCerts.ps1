#Requires -Version 5.1
<#
.SYNOPSIS
    Import IBM FNCM and OpenShift cluster CA certificates into the Windows
    Machine trust store so that all FNCM HTTPS endpoints are trusted by browsers.

.DESCRIPTION
    FNCM 5.7.0 creates its own internal certificate authority
    ("fncmdeploy ICP4A Root CA") and uses it to sign TLS certificates for every
    route it exposes (CPE, GraphQL, Navigator).  Until this CA is trusted by the
    workstation, browsers show NET::ERR_CERT_AUTHORITY_INVALID.

    The OpenShift Ingress Router CA signs the OCP web console and other built-in
    routes.  Importing it removes certificate warnings when opening OCP URLs too.

    What this script does
    1. Reads both CA certs directly from the cluster via 'oc' (no admin needed).
    2. Shows cert details (subject, issuer, thumbprint, expiry) and whether each
       is already trusted.
    3. Imports untrusted certs into Cert:\LocalMachine\Root (requires local admin).
       If not already running as Administrator, the script saves .cer (DER) files
       to a temp folder and launches a self-contained elevated helper via a single
       UAC prompt.  The elevated process does NOT need the oc CLI.
    4. Verifies trust by making an HTTPS request to the FNCM Navigator URL.

    Use -Uninstall to remove the imported CAs (e.g. before decommissioning the
    cluster or after rotating certificates).

.PARAMETER Namespace
    FNCM namespace where the fncm-root-ca secret lives.
    Default: read from config.ps1 ($FNCM_NAMESPACE).

.PARAMETER SkipRouterCA
    Skip importing the OCP Ingress Router CA; import only the FNCM ICP4A Root CA.

.PARAMETER Uninstall
    Remove the FNCM and OCP Ingress CA certificates from Cert:\LocalMachine\Root.

.EXAMPLE
    # Import both CAs (FNCM + OCP Router) -- standard first-run usage
    .\Add-ClusterCerts.ps1

    # Import FNCM CA only
    .\Add-ClusterCerts.ps1 -SkipRouterCA

    # Remove the imported CAs
    .\Add-ClusterCerts.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [switch] $SkipRouterCA,
    [string] $Namespace = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "config.ps1")
Import-Module (Join-Path $PSScriptRoot "common.psm1") -Force -DisableNameChecking

if (-not $Namespace) { $Namespace = $FNCM_NAMESPACE }

# ── Helper: k8s secret value (base64) → PEM string ───────────────────────────
function ConvertTo-PemString {
    param([string]$KubeBase64)
    $bytes = [System.Convert]::FromBase64String($KubeBase64.Trim())
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# ── Helper: PEM string → X509Certificate2 (DER bytes; .NET Framework compat.) ─
# Handles multi-cert PEM chains by extracting only the first certificate block.
function ConvertFrom-PemToX509 {
    param([string]$Pem)
    if ($Pem -match '-----BEGIN CERTIFICATE-----\r?\n?([\s\S]+?)\r?\n?-----END CERTIFICATE-----') {
        $innerB64 = $Matches[1] -replace '\s+', ''
    } else {
        throw "No '-----BEGIN CERTIFICATE-----' block found in the PEM input."
    }
    $derBytes = [System.Convert]::FromBase64String($innerB64)
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($derBytes)
}

# ── Helper: Is the cert already in Cert:\LocalMachine\Root? ──────────────────
function Test-CertTrusted {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $hits = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Cert.Thumbprint }
    return ($null -ne $hits -and @($hits).Count -gt 0)
}

# ── Helper: Display certificate metadata ─────────────────────────────────────
function Show-CertInfo {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [string]$Source
    )
    $trusted = Test-CertTrusted $Cert
    if ($trusted) {
        Write-Log "  $Source  [ALREADY TRUSTED]" "SUCCESS"
    } else {
        Write-Log "  $Source  [NOT YET TRUSTED]" "WARN"
    }
    Write-Log "    Subject    : $($Cert.Subject)" "INFO"
    Write-Log "    Issuer     : $($Cert.Issuer)" "INFO"
    Write-Log "    Thumbprint : $($Cert.Thumbprint)" "INFO"
    $notBefore = $Cert.NotBefore.ToString('yyyy-MM-dd')
    $notAfter  = $Cert.NotAfter.ToString('yyyy-MM-dd')
    Write-Log "    Valid      : $notBefore to $notAfter" "INFO"
    Write-Log "" "INFO"
}

# ── Helper: Write an elevated helper .ps1, launch via UAC, then clean up ──────
# $Lines is an array of strings; each is one line of PowerShell code.
function Invoke-Elevated {
    param([string[]]$Lines)

    # Prefix + suffix lines added around the caller-supplied code
    $prefix = @(
        'Set-StrictMode -Version Latest'
        '$ErrorActionPreference = "Stop"'
        ''
    )
    $suffix = @(
        ''
        'Write-Host ""'
        'Write-Host "--- Done. Press any key to close ---"'
        '$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")'
    )

    $allLines  = $prefix + $Lines + $suffix
    $tmpScript = [System.IO.Path]::GetTempFileName() + ".ps1"
    [System.IO.File]::WriteAllText($tmpScript, ($allLines -join "`r`n"))

    Write-Log "" "INFO"
    Write-Log "Administrator rights required to modify Cert:\LocalMachine\Root." "WARN"
    Write-Log "A UAC elevation prompt will appear -- please accept it." "WARN"
    Write-Log "(One prompt handles all certificate changes.)" "INFO"
    Write-Log "" "INFO"

    $proc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tmpScript `
        -Verb RunAs -PassThru -Wait

    Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue

    if ($null -ne $proc -and $proc.ExitCode -ne 0) {
        Write-Log "Elevated process exited with code $($proc.ExitCode). Check the elevated window." "WARN"
    }
}

# =============================================================================
# Pre-flight
# =============================================================================

if (-not (Test-OCLogin)) {
    Write-Log "Not logged in to OpenShift. Run 'oc login' first." "ERROR"
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# =============================================================================
# Fetch FNCM Root CA
# =============================================================================

Write-Log "Fetching FNCM Root CA (secret: fncm-root-ca  ns: $Namespace)..." "INFO"

$fncmCaB64 = & oc get secret fncm-root-ca -n $Namespace -o 'jsonpath={.data.tls\.crt}' 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fncmCaB64)) {
    Write-Log "Could not read secret 'fncm-root-ca' in namespace '$Namespace'." "ERROR"
    Write-Log "Verify FNCM is deployed:  oc get secret fncm-root-ca -n $Namespace" "ERROR"
    exit 1
}
$fncmCaPem  = ConvertTo-PemString $fncmCaB64
$fncmCaCert = ConvertFrom-PemToX509 $fncmCaPem
Write-Log "FNCM Root CA fetched." "SUCCESS"

# =============================================================================
# Fetch OCP Ingress Router CA (optional)
# =============================================================================

$routerCaCert = $null
$routerCaPem  = $null

if (-not $SkipRouterCA) {
    Write-Log "Fetching OCP Ingress Router CA (secret: router-ca  ns: openshift-ingress-operator)..." "INFO"
    $routerCaB64 = & oc get secret router-ca -n openshift-ingress-operator `
        -o 'jsonpath={.data.tls\.crt}' 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($routerCaB64)) {
        $routerCaPem  = ConvertTo-PemString $routerCaB64
        $routerCaCert = ConvertFrom-PemToX509 $routerCaPem
        Write-Log "OCP Ingress Router CA fetched." "SUCCESS"
    } else {
        Write-Log "Could not read router-ca secret (may need cluster-admin). Skipping." "WARN"
    }
}

# =============================================================================
# Build certificate list and display summary
# =============================================================================

$allCerts = @(
    @{ Cert = $fncmCaCert;   Label = "FNCM ICP4A Root CA       (fncm/fncm-root-ca)" }
)
if ($null -ne $routerCaCert) {
    $allCerts += @{ Cert = $routerCaCert; Label = "OCP Ingress Router CA    (openshift-ingress-operator/router-ca)" }
}

Write-Log "" "INFO"
Write-Log "=== Certificate Summary ===" "INFO"
Write-Log "" "INFO"
foreach ($item in $allCerts) {
    Show-CertInfo -Cert $item.Cert -Source $item.Label
}

# =============================================================================
# UNINSTALL – remove certs from Cert:\LocalMachine\Root
# =============================================================================

if ($Uninstall) {
    Write-Log "Removing CA certificates from Cert:\LocalMachine\Root..." "INFO"

    if ($isAdmin) {
        # Direct removal using .NET
        foreach ($item in $allCerts) {
            $existing = Get-ChildItem Cert:\LocalMachine\Root |
                Where-Object { $_.Thumbprint -eq $item.Cert.Thumbprint }
            if ($null -ne $existing -and @($existing).Count -gt 0) {
                $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
                    [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
                $store.Open("ReadWrite")
                foreach ($c in @($existing)) { $store.Remove($c) }
                $store.Close()
                Write-Log "  Removed: $($item.Label)" "SUCCESS"
            } else {
                Write-Log "  Not found (already removed): $($item.Label)" "INFO"
            }
        }
    } else {
        # Build lines for the elevated helper script
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(''Root'', ''LocalMachine'')')
        $lines.Add('$store.Open(''ReadWrite'')')

        foreach ($item in $allCerts) {
            $tp  = $item.Cert.Thumbprint
            $lbl = $item.Label
            $lines.Add('$cert = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq ''' + $tp + ''' })')
            $lines.Add('if ($cert.Count -gt 0) { $store.Remove($cert[0]); Write-Host "[SUCCESS] Removed: ' + $lbl + '" -ForegroundColor Green }')
            $lines.Add('else { Write-Host "[INFO]    Not found (already removed): ' + $lbl + '" -ForegroundColor Cyan }')
        }
        $lines.Add('$store.Close()')

        Invoke-Elevated -Lines $lines.ToArray()
    }

    Write-Log "" "INFO"
    Write-Log "Done. Restart your browser for the changes to take effect." "SUCCESS"
    exit 0
}

# =============================================================================
# INSTALL – import untrusted certs into Cert:\LocalMachine\Root
# =============================================================================

$toImport = @($allCerts | Where-Object { -not (Test-CertTrusted $_.Cert) })

if ($toImport.Count -eq 0) {
    Write-Log "All certificates are already trusted. Nothing to import." "SUCCESS"
    Write-Log "Run with -Uninstall to remove them." "INFO"
    exit 0
}

Write-Log "Importing $($toImport.Count) certificate(s) into Cert:\LocalMachine\Root..." "INFO"

if ($isAdmin) {
    # --- Running as admin: use .NET directly ---------------------------------
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open("ReadWrite")
    foreach ($item in $toImport) {
        $store.Add($item.Cert)
        Write-Log "  Imported: $($item.Label)" "SUCCESS"
    }
    $store.Close()
} else {
    # --- Not admin: save DER files to temp dir, run elevated helper ----------
    # The elevated process reads pre-saved .cer (DER binary) files -- no oc needed.
    $tmpDir = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(), "fncm-certs-$(Get-Random)")
    [System.IO.Directory]::CreateDirectory($tmpDir) | Out-Null

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(''Root'', ''LocalMachine'')')
    $lines.Add('$store.Open(''ReadWrite'')')

    foreach ($item in $toImport) {
        # Save DER bytes so the elevated process can load without PEM parsing
        $safeName = ($item.Label -replace '[^\w]', '_') + ".cer"
        $cerPath  = [System.IO.Path]::Combine($tmpDir, $safeName)
        [System.IO.File]::WriteAllBytes($cerPath, $item.Cert.RawData)

        $lbl = $item.Label
        $lines.Add('$c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([System.IO.File]::ReadAllBytes(''' + $cerPath + '''))')
        $lines.Add('$store.Add($c)')
        $lines.Add('Write-Host "[SUCCESS] Imported: ' + $lbl + '" -ForegroundColor Green')
    }
    $lines.Add('$store.Close()')
    $lines.Add('Remove-Item ''' + $tmpDir + ''' -Recurse -Force -ErrorAction SilentlyContinue')

    Invoke-Elevated -Lines $lines.ToArray()

    # Clean up in case the elevated script exited before reaching Remove-Item
    if (Test-Path $tmpDir) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Verify – confirm Navigator endpoint is now TLS-trusted
# =============================================================================

Write-Log "" "INFO"
Write-Log "Verifying HTTPS trust for FNCM Navigator..." "INFO"

# Use a simple jsonpath query (single-quoted, no embedded PS expansion needed)
$allHosts = & oc get route -n $Namespace -o 'jsonpath={range .items[*]}{.spec.host}{" "}{end}' 2>&1
$navHost   = ($allHosts -split ' ') | Where-Object { $_ -match 'navigator' } | Select-Object -First 1

if ($navHost) {
    $navUrl = "https://" + $navHost.Trim() + "/"
    Write-Log "  URL: $navUrl" "INFO"
    try {
        $resp = Invoke-WebRequest -Uri $navUrl -UseBasicParsing -TimeoutSec 15 `
            -MaximumRedirection 0 -ErrorAction Stop
        Write-Log "  TLS OK (HTTP $($resp.StatusCode)) -- certificate is TRUSTED." "SUCCESS"
    } catch {
        $msg   = $_.Exception.Message
        $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "" }
        $tlsErr = ($msg -match 'certificate|SSL|TLS|trust|valid') -or
                  ($inner -match 'certificate|SSL|TLS|trust|valid')
        if ($tlsErr) {
            Write-Log "  Certificate still not trusted: $msg" "WARN"
            Write-Log "  If the UAC window was cancelled, re-run the script." "WARN"
            Write-Log "  If running in the same shell as the import, try opening a" "WARN"
            Write-Log "  new PowerShell window (cert store cache may need refresh)." "WARN"
        } else {
            # HTTP-level error (401, 302, 404...) = TLS handshake succeeded
            Write-Log "  TLS OK (server responded with HTTP error -- auth required)." "SUCCESS"
            Write-Log "  Certificate IS trusted." "SUCCESS"
        }
    }
} else {
    Write-Log "  Navigator route not found. Verify manually in your browser." "WARN"
}

# =============================================================================
# Summary
# =============================================================================

Write-Log "" "INFO"
Write-Log "================================================" "SUCCESS"
Write-Log "  CA Certificates Imported Successfully" "SUCCESS"
Write-Log "================================================" "SUCCESS"
Write-Log "" "INFO"
Write-Log "ACTION REQUIRED: Restart your browser for changes to take effect." "WARN"
Write-Log "" "INFO"

# Print FNCM access URLs from the operator ConfigMap if available
$cmJson = & oc get configmap fncmdeploy-fncm-access-info -n $Namespace `
    -o 'jsonpath={range .data.*}{@}{" "}{end}' 2>&1
if ($LASTEXITCODE -eq 0 -and $cmJson -match 'https://') {
    Write-Log "FNCM access URLs (all should now be trusted):" "INFO"
    ($cmJson -split ' ') | Where-Object { $_ -match 'https://' } |
        ForEach-Object { Write-Log "  $_" "INFO" }
    Write-Log "" "INFO"
}

Write-Log "To remove these certificates later:" "INFO"
Write-Log "  .\Add-ClusterCerts.ps1 -Uninstall" "INFO"
