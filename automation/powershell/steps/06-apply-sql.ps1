# Step 6 - Apply database SQL scripts to PostgreSQL
# Creates tablespace directories and runs createGCD/createos/createICN SQL files.
# Idempotent: each database creation is skipped if the database already exists.
# When DEPLOY_IER = $true, also creates OS2 (ROS) and OS3 (FPOS) databases for IER.
# OS1 remains the general content repository; IER adds dedicated ROS and FPOS on top.
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

$pgPod = Get-PodName -Namespace $POSTGRESQL_NAMESPACE -LabelSelector "app=fncm-postgresql"
Write-Log "PostgreSQL pod: $pgPod" "INFO"

# ── 6a: Patch ICN SQL - replace default tablespace/schema names ───────────────
Write-Log "Patching createICN.sql tablespace and schema names..." "INFO"
$patchIcnCmd = @"
sed -i \
  -e 's/tablespace ICNDB/tablespace ${ICN_TABLESPACE}/g' \
  -e 's/SCHEMA IF NOT EXISTS ICNDB/SCHEMA IF NOT EXISTS ${ICN_SCHEMA}/g' \
  -e 's/search_path TO ICNDB/search_path TO ${ICN_SCHEMA}/g' \
  ${GENERATED_FILES_PATH}/database/createICN.sql
echo "ICN SQL patched."
"@
Invoke-PodExec -Namespace $INSTALL_NAMESPACE -PodName "install" -BashCommand $patchIcnCmd

# ── 6b: Copy SQL files from install pod → local temp → postgres pod ───────────
Write-Log "Copying SQL scripts from install pod to local temp..." "INFO"
$tmpSqlDir = Join-Path $env:TEMP "fncm-sql-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $tmpSqlDir | Out-Null

# Build file list - OS2/OS3 only generated when DATABASE_OBJECT_STORE_COUNT = 3 (IER)
$sqlFiles = [System.Collections.Generic.List[string]]@("createGCD.sql", "createICN.sql", "createos.sql")
if ($DEPLOY_IER) {
    $sqlFiles.Add("createos2.sql")   # OS2 = ROS  (Records Object Store)    - IER
    $sqlFiles.Add("createos3.sql")   # OS3 = FPOS (File Plan Object Store)   - IER
}

foreach ($sqlFile in $sqlFiles) {
    Copy-FromPod -Namespace $INSTALL_NAMESPACE -PodName "install" `
        -RemotePath "${GENERATED_FILES_PATH}/database/$sqlFile" `
        -LocalPath (Join-Path $tmpSqlDir $sqlFile)
}

Write-Log "Copying SQL scripts to PostgreSQL pod..." "INFO"
Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
    -BashCommand "mkdir -p /usr/dbscript"
foreach ($sqlFile in $sqlFiles) {
    Copy-ToPod -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
        -LocalPath (Join-Path $tmpSqlDir $sqlFile) `
        -RemotePath "/usr/dbscript/$sqlFile"
}
Remove-Item $tmpSqlDir -Recurse -Force

# ── 6c: ICN database (idempotent) ────────────────────────────────────────────
Write-Log "Creating ICN tablespace directory and running createICN.sql..." "INFO"
Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
    -BashCommand "mkdir -p /pgsqldata/${ICN_DB_NAME} && chown postgres:postgres /pgsqldata/${ICN_DB_NAME}"

$icnSqlCmd = @"
if psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
     -tc "SELECT 1 FROM pg_database WHERE datname='${ICN_DB_NAME}'" 2>/dev/null | grep -q 1; then
  echo "ICN database '${ICN_DB_NAME}' already exists - skipping."
else
  psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
       --file=/usr/dbscript/createICN.sql
  echo "ICN database created."
fi
"@
Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod -BashCommand $icnSqlCmd
Write-Log "ICN database ready." "SUCCESS"

# ── 6d: OS1 (ROS - Records Object Store) database (idempotent) ───────────────
Write-Log "Creating OS1 tablespace directories and running createos.sql..." "INFO"
foreach ($dir in @("${OS1_DB_NAME}", "${OS1_DB_NAME}/data", "${OS1_DB_NAME}/index")) {
    Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
        -BashCommand "mkdir -p /pgsqldata/$dir && chown postgres:postgres /pgsqldata/$dir"
}

$os1SqlCmd = @"
if psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
     -tc "SELECT 1 FROM pg_database WHERE datname='${OS1_DB_NAME}'" 2>/dev/null | grep -q 1; then
  echo "OS1 database '${OS1_DB_NAME}' already exists - skipping."
else
  psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
       --file=/usr/dbscript/createos.sql
  echo "OS1 database created."
fi
"@
Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod -BashCommand $os1SqlCmd
Write-Log "OS1 (ROS) database ready." "SUCCESS"

# ── 6e: OS2 (IER ROS) + OS3 (IER FPOS) databases (conditional, idempotent) ───
if ($DEPLOY_IER) {
    # OS2 — Records Object Store
    Write-Log "Creating OS2 (IER ROS) tablespace directories and running createos2.sql..." "INFO"
    foreach ($dir in @("${OS2_DB_NAME}", "${OS2_DB_NAME}/data", "${OS2_DB_NAME}/index")) {
        Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
            -BashCommand "mkdir -p /pgsqldata/$dir && chown postgres:postgres /pgsqldata/$dir"
    }
    $os2SqlCmd = @"
if psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
     -tc "SELECT 1 FROM pg_database WHERE datname='${OS2_DB_NAME}'" 2>/dev/null | grep -q 1; then
  echo "OS2 database '${OS2_DB_NAME}' already exists - skipping."
else
  psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
       --file=/usr/dbscript/createos2.sql
  echo "OS2 database created."
fi
"@
    Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod -BashCommand $os2SqlCmd
    Write-Log "OS2 (IER ROS) database ready." "SUCCESS"

    # OS3 — File Plan Object Store
    Write-Log "Creating OS3 (IER FPOS) tablespace directories and running createos3.sql..." "INFO"
    foreach ($dir in @("${OS3_DB_NAME}", "${OS3_DB_NAME}/data", "${OS3_DB_NAME}/index")) {
        Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
            -BashCommand "mkdir -p /pgsqldata/$dir && chown postgres:postgres /pgsqldata/$dir"
    }
    $os3SqlCmd = @"
if psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
     -tc "SELECT 1 FROM pg_database WHERE datname='${OS3_DB_NAME}'" 2>/dev/null | grep -q 1; then
  echo "OS3 database '${OS3_DB_NAME}' already exists - skipping."
else
  psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
       --file=/usr/dbscript/createos3.sql
  echo "OS3 database created."
fi
"@
    Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod -BashCommand $os3SqlCmd
    Write-Log "OS3 (IER FPOS) database ready." "SUCCESS"
}

# ── 6f: GCD database (idempotent) ────────────────────────────────────────────
Write-Log "Creating GCD tablespace directory and running createGCD.sql..." "INFO"
Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod `
    -BashCommand "mkdir -p /pgsqldata/${GCD_DB_NAME} && chown postgres:postgres /pgsqldata/${GCD_DB_NAME}"

$gcdSqlCmd = @"
if psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
     -tc "SELECT 1 FROM pg_database WHERE datname='${GCD_DB_NAME}'" 2>/dev/null | grep -q 1; then
  echo "GCD database '${GCD_DB_NAME}' already exists - skipping."
else
  psql postgresql://${POSTGRES_USER}@localhost:5432/${POSTGRES_DB} \
       --file=/usr/dbscript/createGCD.sql
  echo "GCD database created."
fi
"@
Invoke-PodExec -Namespace $POSTGRESQL_NAMESPACE -PodName $pgPod -BashCommand $gcdSqlCmd
Write-Log "GCD database ready." "SUCCESS"

Write-Log "All FNCM databases created in PostgreSQL." "SUCCESS"
