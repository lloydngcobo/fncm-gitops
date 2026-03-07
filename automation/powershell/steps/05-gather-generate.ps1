# Step 5 - Gather configuration, patch property files, then generate SQL/secrets/CR
# Uses prerequisites.py silent mode for gather, then sed-patches connection details.
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── 5a: Build silent prerequisites config (high-level options) ────────────────
$cpeTf     = if ($DEPLOY_CPE)     { "true" } else { "false" }
$graphqlTf = if ($DEPLOY_GRAPHQL) { "true" } else { "false" }
$banTf     = if ($DEPLOY_BAN)     { "true" } else { "false" }
$cssTf     = if ($DEPLOY_CSS)     { "true" } else { "false" }
$cmisTf    = if ($DEPLOY_CMIS)    { "true" } else { "false" }
$tmTf      = if ($DEPLOY_TM)      { "true" } else { "false" }
$esTf      = if ($DEPLOY_ES)      { "true" } else { "false" }
$ierTf     = if ($DEPLOY_IER)     { "true" } else { "false" }
$iccsapTf  = if ($DEPLOY_ICCSAP)  { "true" } else { "false" }

# OS count: IER adds ROS (OS2) and FPOS (OS3) on top of the general store (OS1)
$osCount = if ($DEPLOY_IER) { 3 } else { 1 }

$prereqToml = @"
NAMESPACE = "${FNCM_NAMESPACE}"
LICENSE = "${FNCM_LICENSE}"
PLATFORM = 1
INGRESS = false
AUTHENTICATION = 1
RESTRICTED_INTERNET_ACCESS = false
GENERATE_NETWORK_POLICIES = false
FIPS_SUPPORT = false

CPE = ${cpeTf}
GRAPHQL = ${graphqlTf}
BAN = ${banTf}
CSS = ${cssTf}
CMIS = ${cmisTf}
TM = ${tmTf}
ES = ${esTf}
IER = ${ierTf}
ICCSAP = ${iccsapTf}

DATABASE_TYPE = 4
DATABASE_SSL_ENABLE = false
DATABASE_OBJECT_STORE_COUNT = ${osCount}

SENDMAIL_SUPPORT = false
ICC_SUPPORT = false
TM_CUSTOM_GROUP_SUPPORT = false
CONTENT_INIT = true
CONTENT_VERIFY = true

[LDAP]
LDAP_TYPE = 2
LDAP_SSL_ENABLE = false

[IDP]
DISCOVERY_ENABLED = false
DISCOVERY_URL = ""
"@

$tmpToml = Write-TempScript -Content $prereqToml -Extension ".toml"
$silentPrereqRemote = "${CONTAINER_SAMPLES_PATH}/scripts/silent_config/silent_install_prerequisites.toml"
Copy-ToPod -Namespace $INSTALL_NAMESPACE -PodName "install" `
    -LocalPath $tmpToml `
    -RemotePath $silentPrereqRemote
Remove-Item $tmpToml -Force

# ── 5b: Run gather phase ──────────────────────────────────────────────────────
Write-Log "Running prerequisites.py gather (silent mode)..." "INFO"
$gatherCmd = "cd ${CONTAINER_SAMPLES_PATH}/scripts && python3 prerequisites.py --silent gather"
$null = Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $gatherCmd -Quiet
Write-Log "Gather phase complete." "SUCCESS"

# ── 5c: Patch property files with real connection details ─────────────────────
# This script mirrors the original sed commands from the manual procedure.
Write-Log "Patching generated property files with environment-specific values..." "INFO"

# Build the property file path once (PowerShell expands it into the bash script)
$PROP_PATH = $PROPERTY_FILE_PATH

$patchScript = @"
#!/bin/bash
set -e

echo "==> Backing up property files..."
find "${PROP_PATH}" -name "*.toml" -exec cp {} {}.bck \;

if [ -f "${PROP_PATH}/fncm_components_options.toml" ]; then
  echo "==> Patching fncm_components_options.toml ..."
  sed -i \
    -e 's/taskAdmins/${FNCM_ADMIN_GROUP}/g' \
    -e 's/taskUsers/${FNCM_USER_GROUP}/g'   \
    -e 's/taskAuditors/${FNCM_ADMIN_GROUP}/g' \
    "${PROP_PATH}/fncm_components_options.toml"
else
  echo "==> Skipping fncm_components_options.toml (not generated - TM not enabled)"
fi

echo "==> Patching fncm_db_server.toml - server name..."
sed -i \
  -e 's/DATABASE_SERVERNAME = "<Required>"/DATABASE_SERVERNAME = "${POSTGRES_HOST}"/g' \
  "${PROP_PATH}/fncm_db_server.toml"

echo "==> Patching fncm_db_server.toml - GCD database..."
sed -i \
  -e '0,/DATABASE_NAME = "<Required>"/s//DATABASE_NAME = "${GCD_DB_NAME}"/' \
  -e '0,/DATABASE_USERNAME = """<Required>"""/s//DATABASE_USERNAME = """${GCD_DB_USER}"""/' \
  -e '0,/DATABASE_PASSWORD = """<Required>"""/s//DATABASE_PASSWORD = """${GCD_DB_PASSWORD}"""/' \
  "${PROP_PATH}/fncm_db_server.toml"

echo "==> Patching fncm_db_server.toml - OS1 (ROS) database..."
sed -i \
  -e '0,/DATABASE_NAME = "<Required>"/s//DATABASE_NAME = "${OS1_DB_NAME}"/' \
  -e '0,/DATABASE_USERNAME = """<Required>"""/s//DATABASE_USERNAME = """${OS1_DB_USER}"""/' \
  -e '0,/DATABASE_PASSWORD = """<Required>"""/s//DATABASE_PASSWORD = """${OS1_DB_PASSWORD}"""/' \
  "${PROP_PATH}/fncm_db_server.toml"

if [ "${ierTf}" = "true" ]; then
  echo "==> Patching fncm_db_server.toml - OS2 (IER ROS - Records Object Store) database..."
  sed -i \
    -e '0,/DATABASE_NAME = "<Required>"/s//DATABASE_NAME = "${OS2_DB_NAME}"/' \
    -e '0,/DATABASE_USERNAME = """<Required>"""/s//DATABASE_USERNAME = """${OS2_DB_USER}"""/' \
    -e '0,/DATABASE_PASSWORD = """<Required>"""/s//DATABASE_PASSWORD = """${OS2_DB_PASSWORD}"""/' \
    "${PROP_PATH}/fncm_db_server.toml"

  echo "==> Patching fncm_db_server.toml - OS3 (IER FPOS - File Plan Object Store) database..."
  sed -i \
    -e '0,/DATABASE_NAME = "<Required>"/s//DATABASE_NAME = "${OS3_DB_NAME}"/' \
    -e '0,/DATABASE_USERNAME = """<Required>"""/s//DATABASE_USERNAME = """${OS3_DB_USER}"""/' \
    -e '0,/DATABASE_PASSWORD = """<Required>"""/s//DATABASE_PASSWORD = """${OS3_DB_PASSWORD}"""/' \
    "${PROP_PATH}/fncm_db_server.toml"
fi

echo "==> Patching fncm_db_server.toml - ICN database..."
sed -i \
  -e '0,/DATABASE_NAME = "<Required>"/s//DATABASE_NAME = "${ICN_DB_NAME}"/' \
  -e '0,/DATABASE_USERNAME = """<Required>"""/s//DATABASE_USERNAME = """${ICN_DB_USER}"""/' \
  -e '0,/DATABASE_PASSWORD = """<Required>"""/s//DATABASE_PASSWORD = """${ICN_DB_PASSWORD}"""/' \
  -e '0,/TABLESPACE_NAME = "ICNDB"/s//TABLESPACE_NAME = "${ICN_TABLESPACE}"/' \
  -e '0,/SCHEMA_NAME = "ICNDB"/s//SCHEMA_NAME = "${ICN_SCHEMA}"/' \
  "${PROP_PATH}/fncm_db_server.toml"

echo "==> Patching fncm_deployment.toml ..."
sed -i \
  -e 's/SLOW_FILE_STORAGE_CLASSNAME = "<Required>"/SLOW_FILE_STORAGE_CLASSNAME = "${STORAGE_CLASS_NAME}"/g' \
  -e 's/MEDIUM_FILE_STORAGE_CLASSNAME = "<Required>"/MEDIUM_FILE_STORAGE_CLASSNAME = "${STORAGE_CLASS_NAME}"/g' \
  -e 's/FAST_FILE_STORAGE_CLASSNAME = "<Required>"/FAST_FILE_STORAGE_CLASSNAME = "${STORAGE_CLASS_NAME}"/g' \
  "${PROP_PATH}/fncm_deployment.toml"

echo "==> Patching fncm_ldap_server.toml ..."
sed -i \
  -e 's|LDAP_SERVER = "<Required>"|LDAP_SERVER = "${LDAP_HOST}"|g' \
  -e 's|LDAP_PORT = "<Required>"|LDAP_PORT = "${LDAP_PORT}"|g' \
  -e 's|LDAP_BASE_DN = "<Required>"|LDAP_BASE_DN = "${LDAP_ROOT}"|g' \
  -e 's|LDAP_GROUP_BASE_DN = "<Required>"|LDAP_GROUP_BASE_DN = "ou=Groups,${LDAP_ROOT}"|g' \
  -e 's|LDAP_BIND_DN = """<Required>"""|LDAP_BIND_DN = """${LDAP_BIND_DN}"""|g' \
  -e 's|LDAP_BIND_DN_PASSWORD = """<Required>"""|LDAP_BIND_DN_PASSWORD = """${LDAP_ADMIN_PASSWORD}"""|g' \
  -e 's|LDAP_USER_NAME_ATTRIBUTE = "\*:uid"|LDAP_USER_NAME_ATTRIBUTE = "*:cn"|g' \
  -e 's|(uid=%v)(objectclass=person)|(uid=%v)(objectclass=inetOrgPerson)|g' \
  -e 's|(objectclass=groupofnames)(objectclass=groupofuniquenames)(objectclass=groupofurls)|(objectclass=groupofnames)(objectclass=groupofuniquenames)|g' \
  "${PROP_PATH}/fncm_ldap_server.toml"

echo "==> Patching fncm_user_group.toml ..."
sed -i \
  -e 's|KEYSTORE_PASSWORD = """<Required>"""|KEYSTORE_PASSWORD = """${KEYSTORE_PASSWORD}"""|g' \
  -e 's|LTPA_PASSWORD = """<Required>"""|LTPA_PASSWORD = """${LTPA_PASSWORD}"""|g' \
  -e 's|FNCM_LOGIN_USER = """<Required>"""|FNCM_LOGIN_USER = """${FNCM_ADMIN_USER}"""|g' \
  -e 's|FNCM_LOGIN_PASSWORD = """<Required>"""|FNCM_LOGIN_PASSWORD = """${FNCM_ADMIN_PASSWORD}"""|g' \
  -e 's|ICN_LOGIN_USER = """<Required>"""|ICN_LOGIN_USER = """${FNCM_ADMIN_USER}"""|g' \
  -e 's|ICN_LOGIN_PASSWORD = """<Required>"""|ICN_LOGIN_PASSWORD = """${FNCM_ADMIN_PASSWORD}"""|g' \
  -e 's|GCD_ADMIN_USER_NAME = \["""<Required>"""\]|GCD_ADMIN_USER_NAME = ["""${FNCM_ADMIN_USER}"""]|g' \
  -e 's|GCD_ADMIN_GROUPS_NAME = \["""<Required>"""\]|GCD_ADMIN_GROUPS_NAME = ["""${FNCM_ADMIN_GROUP}"""]|g' \
  -e 's|CPE_OBJ_STORE_OS_ADMIN_USER_GROUPS = \["""<Required>"""\]|CPE_OBJ_STORE_OS_ADMIN_USER_GROUPS = ["""${FNCM_ADMIN_USER}""","""${FNCM_ADMIN_GROUP}"""]|g' \
  "${PROP_PATH}/fncm_user_group.toml"

echo "==> All property files patched successfully."
"@

$tmpPatch = Write-TempScript -Content $patchScript
Copy-ToPod -Namespace $INSTALL_NAMESPACE -PodName "install" `
    -LocalPath $tmpPatch `
    -RemotePath "/tmp/patch_properties.sh"
Remove-Item $tmpPatch -Force

Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" `
    -BashCommand "chmod +x /tmp/patch_properties.sh && /tmp/patch_properties.sh"

# ── 5d: Run generate phase ────────────────────────────────────────────────────
Write-Log "Running prerequisites.py generate..." "INFO"
$generateCmd = "cd ${CONTAINER_SAMPLES_PATH}/scripts && python3 prerequisites.py --silent generate"
$null = Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $generateCmd -Quiet
Write-Log "Generate phase complete." "SUCCESS"

Write-Log "Gather & Generate complete.  Generated files are in:" "SUCCESS"
Write-Log "  ${GENERATED_FILES_PATH}/" "INFO"
