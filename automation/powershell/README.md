# IBM FNCM 5.7.0 – Automated Deployment on OpenShift

PowerShell automation that installs IBM FileNet Content Manager (FNCM) 5.7.0
on OpenShift Container Platform (OCP) end-to-end in **7 steps**, driving `oc`
CLI from a Windows workstation via an install pod inside the cluster.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows workstation | PowerShell 5.1+ |
| `oc` CLI | In `PATH`, already logged-in (`oc login`) |
| OCP 4.x cluster | Tested on 4.14 |
| RWX StorageClass | e.g. NFS-backed (`nfs-homelab`) |
| IBM Entitlement Key | From https://myibm.ibm.com/products-services/containerlibrary |

---

## Quick Start

```powershell
# 1. Edit config.ps1 with your cluster, storage class, and credentials
notepad .\config.ps1

# 2. Launch the interactive wizard  (~60-90 min first run)
#    Select components → choose run mode → confirm → deploy
cd automation\powershell
.\Install-FNCM.ps1
#    CA certificates are automatically imported at the end (one UAC prompt)

# 3. Re-run a single step after a fix (skips wizard, uses config.ps1 defaults)
.\Install-FNCM.ps1 -Step 7

# 4. Skip steps already completed (also skips wizard)
.\Install-FNCM.ps1 -SkipSteps 1,2,3

# 5. Deploy with config.ps1 defaults as-is, no wizard
.\Install-FNCM.ps1 -Force
```

---

## Configuration (`config.ps1`)

| Variable | Purpose |
|---|---|
| `$OCP_API_URL` | `https://api.<cluster>:6443` |
| `$OCP_TOKEN` | Leave empty to use current `oc login` session |
| `$FNCM_NAMESPACE` | Target namespace for FNCM (default `fncm`) |
| `$INSTALL_NAMESPACE` | Long-lived install pod namespace (default `fncm-install`) |
| `$OPENLDAP_NAMESPACE` | OpenLDAP namespace (default `fncm-openldap`) |
| `$POSTGRESQL_NAMESPACE` | PostgreSQL namespace (default `fncm-postgresql`) |
| `$STORAGE_CLASS_NAME` | RWX StorageClass name |
| `$IBM_ENTITLEMENT_KEY` | IBM Container Registry entitlement key |
| `$DEPLOY_CPE/GRAPHQL/BAN/...` | Enable/disable FNCM components *(defaults — the wizard overrides these interactively)* |

---

## Interactive Deployment Wizard

Running `.\Install-FNCM.ps1` with no flags launches a 3-step wizard:

```
+============================================================+
|    IBM FileNet Content Manager  --  Deployment Wizard      |
|                OpenShift Automation  v1.0                  |
+============================================================+

  Cluster  : https://api.homelab.home.nl:6443
  Target   : namespace 'fncm'
  Storage  : nfs-homelab

------------------------------------------------------------
  [1/3]  COMPONENT SELECTION
------------------------------------------------------------

  Content Platform Engine (CPE)  :  REQUIRED  (always included)

  For each optional component, press Enter to keep the default
  shown in [brackets], or type Y / N to change it.

  GraphQL API                         [Y/n] :
  Business Automation Navigator (BAN) [Y/n] :
  Content Search Services (CSS)       [y/N] :
  CMIS Connector                      [y/N] :
  Task Manager (TM)                   [y/N] :
  External Share (ES)                 [y/N] :
  IBM Enterprise Records (IER)        [y/N] :
  ICC for SAP (ICCSAP)                [y/N] :

------------------------------------------------------------
  [2/3]  RUN MODE
------------------------------------------------------------

  1)  Full deployment          (steps 1 - 7, fresh start from scratch)
  2)  Skip Step 1              (install pod is already running, saves ~20 min)
  3)  Single step only         (re-run one specific step)
  4)  Custom skip              (specify which steps to skip)

  Select run mode [1-4] :

------------------------------------------------------------
  [3/3]  CERTIFICATE TRUST
------------------------------------------------------------

  Auto-import CA certificates after Step 7? [Y/n] :

------------------------------------------------------------
  DEPLOYMENT SUMMARY
------------------------------------------------------------

  Components : CPE (required), GraphQL, Navigator, CSS
  Run mode   : Full deployment  (steps 1 - 7)
  Certs      : Import after Step 7  (UAC prompt)

  Proceed with deployment? [Y/n] :
```

### Available FNCM Components

| Component | Flag in `config.ps1` | Default | Description |
|---|---|---|---|
| Content Platform Engine | `$DEPLOY_CPE` | `$true` | **Always required** — core document repository |
| GraphQL API | `$DEPLOY_GRAPHQL` | `$true` | REST/GraphQL interface for content services |
| Business Automation Navigator | `$DEPLOY_BAN` | `$true` | Web-based document management UI |
| Content Search Services | `$DEPLOY_CSS` | `$false` | Full-text search indexing for CPE object stores |
| CMIS Connector | `$DEPLOY_CMIS` | `$false` | CMIS 1.1 protocol support |
| Task Manager | `$DEPLOY_TM` | `$false` | Workflow task management |
| External Share | `$DEPLOY_ES` | `$false` | Share CPE content with external users |
| IBM Enterprise Records | `$DEPLOY_IER` | `$false` | Records management and retention |
| ICC for SAP | `$DEPLOY_ICCSAP` | `$false` | SAP content integration |

> The defaults shown in the wizard come from `config.ps1`.  Press Enter to accept
> them or type Y/N to override for this deployment only.  The wizard writes a
> temporary `config.session.ps1` that the step scripts pick up automatically;
> this file is removed after a successful deployment.

### Non-interactive (bypass wizard)

| Flag | Effect |
|---|---|
| `-Force` | Skip wizard; use `config.ps1` component defaults as-is |
| `-Step N` | Skip wizard; run only step N with `config.ps1` defaults |
| `-SkipSteps N,M` | Skip wizard; run all steps except N and M |
| `-SkipCerts` | Skip CA certificate import after step 7 |

---

## Architecture

```
Windows (PowerShell + oc CLI)
    │
    ├── oc exec ──► install pod (fncm-install)
    │                  ├── git clone ibm-fncm-containers
    │                  ├── deployoperator.py --silent
    │                  ├── prerequisites.py --silent gather/generate
    │                  └── oc apply (secrets, CR)
    │
    ├── fncm-openldap ──► OpenLDAP (Bitnami 2.6.5)
    │
    ├── fncm-postgresql ─► PostgreSQL 14.7
    │                         ├── devgcd  (GCD database)
    │                         ├── devos1  (Object Store 1)
    │                         └── devicn  (ICN/Navigator database)
    │
    └── fncm ────────────► FNCM Operator + FNCMCluster
                               ├── CPE     (Content Platform Engine)        [required]
                               ├── GraphQL (Content Services GraphQL)       [optional]
                               ├── BAN     (Business Automation Navigator)  [optional]
                               ├── CSS     (Content Search Services)        [optional]
                               ├── CMIS    (CMIS Connector)                 [optional]
                               ├── TM      (Task Manager)                   [optional]
                               ├── ES      (External Share)                 [optional]
                               ├── IER     (IBM Enterprise Records)         [optional]
                               └── ICCSAP  (ICC for SAP)                    [optional]
```

---

## Step Reference

### Step 1 – Setup Install Client
Creates the `fncm-install` namespace, a long-lived install pod (UBI9), and a
ClusterRoleBinding giving the pod `cluster-admin` rights.

The pod installs on first run (~20 min):
- IBM Semeru JDK 21 + `keytool`
- `oc` / `kubectl` / `yq` CLIs
- Python 3.9 + all FNCM prereq packages (pip)
- Clones `github.com/ibm-ecm/ibm-fncm-containers`

**Re-run safe**: skipped if install pod already exists.

---

### Step 2 – Deploy OpenLDAP
Deploys Bitnami OpenLDAP 2.6.5 into `fncm-openldap` with:
- Custom LDIF that bootstraps the IBM SDS schema (`ibm-entryuuid` attribute)
- Default users: `cpadmin`, `cpuser`
- Default groups: `cpadmins`, `cpusers`
- Service exposed on port 389 (internal) + NodePort (external testing)

---

### Step 3 – Deploy PostgreSQL
Deploys PostgreSQL 14.7 as a StatefulSet into `fncm-postgresql`:
- Two PVCs: `postgresql-data` (PGDATA) and `postgresql-tablespaces`
  (`/pgsqldata` – separate mount for tablespace directories)
- Tuned for FNCM: `max_prepared_transactions=500`, `max_connections=500`

---

### Step 4 – Deploy FNCM Operator
Runs `deployoperator.py --silent` inside the install pod, which:
- Creates OperatorGroup + Subscription + CatalogSource in the `fncm` namespace
- Adds the IBM Entitlement Key to the global pull secret
- Installs the IBM FNCM Operator via OLM

Waits for the CSV to reach `Succeeded` phase.

---

### Step 5 – Gather & Generate Config
Runs `prerequisites.py --silent gather` then `--silent generate`.

**gather** reads property files (`propertyFile/fncm/`) and produces SQL scripts,
FNCM secrets, and the Custom Resource template.

**Key property file patches** applied before generate:
- `fncm_ldap_server.toml` – rewrites all filters for OpenLDAP:
  - `objectClass=person` → `objectClass=inetOrgPerson`
  - `objectClass=groupofnames` (kept, but member map updated)
  - `lc_user_id_map`: `*:uid`
  - `lc_group_id_map`: `*:cn`
  - `lc_group_member_id_map`: `groupofnames:member`
- `fncm_db_server.toml` – PostgreSQL JDBC URL
- `fncm_components_options.toml` – component flags (applied only if file exists;
  Task Manager is not deployed so this file is absent when `DEPLOY_TM=false`)

---

### Step 6 – Apply Database SQL
Runs the generated SQL scripts inside the PostgreSQL pod:

| Script | What it creates |
|---|---|
| `createGCD.sql` | `devgcd` database + user + tablespace at `/pgsqldata/devgcd` |
| `createOS1.sql` | `devos1` database + user + tablespace at `/pgsqldata/devos1` |
| `createICN.sql` | `devicn` database + user + tablespace at `/pgsqldata/devicn` |

> **Key fix**: the tablespace `LOCATION` directory is named after the
> **database** (`$ICN_DB_NAME = devicn`), not the tablespace
> (`$ICN_TABLESPACE = devicn_tbs`).  PostgreSQL creates the directory with the
> path it finds in the SQL — using the wrong name causes `directory does not
> exist` errors.

---

### Step 7 – Deploy FNCM Custom Resource

**7a** – NetworkPolicy: permissive egress for `fncm` and `fncm-install`
namespaces.

**7b** – CR Patch (Python-based, idempotent):
- Restores `ibm_fncm_cr_production.yaml.bak` on re-runs (ensures pristine base)
- Sets `lc_selected_ldap_type: Custom` (required for OpenLDAP)
- **Adds `custom:` LDAP section** as a deep copy of `tds:` — the FNCM operator
  Ansible roles (`cpe-pre-deploy.yml`, `graphql-pre-deploy.yml`) access
  `ldap_config.tds` unconditionally, even when the type is Custom.  Keeping both
  keys prevents `'dict object' has no attribute 'tds'` errors.

**7c–7d** – Sets `oc project fncm`; applies **all** generated Kubernetes Secrets
(`oc apply -f secrets/`) — picks up component-specific secrets automatically:
`ibm-fncm-secret`, `ibm-ban-secret`, `ibm-ier-secret` (IER only),
`ibm-iccsap-secret` (ICCSAP only), etc.

**7e** – `oc apply` of the patched FNCMCluster CR.

**7f** – Waits up to 90 min for the FNCMCluster to reach `Ready` state.

---

## Access URLs (after successful deployment)

| Interface | URL |
|---|---|
| **Business Automation Navigator** | `https://navigator-fncm.apps.<cluster>/navigator/` |
| **CPE Administration Console (ACCE)** | `https://cpe-fncm.apps.<cluster>/acce/` |
| **CPE Health Check** | `https://cpe-fncm.apps.<cluster>/P8CE/Health` |
| **CPE Ping** | `https://cpe-fncm.apps.<cluster>/FileNet/Engine` |
| **GraphQL Playground** | `https://graphql-fncm.apps.<cluster>/content-services-graphql/` ⚠️ requires dev mode — see below |
| **CPE Web Services (FNCEWS)** | `https://cpe-fncm.apps.<cluster>/wsi/FNCEWS40MTOM/` |

Default admin credentials: `cpadmin` / `Password` (set in `config.ps1`).

Live URL list:
```bash
oc get cm fncmdeploy-fncm-access-info -n fncm -o yaml
```

---

## Certificate Trust

FNCM 5.7.0 creates its own internal certificate authority
(**`fncmdeploy ICP4A Root CA`**) and uses it to sign TLS certificates for every
route it exposes (CPE, GraphQL, Navigator).  Until this CA is trusted by the
workstation, browsers show `NET::ERR_CERT_AUTHORITY_INVALID`.

The `Add-ClusterCerts.ps1` helper automates the full process:

```powershell
# From automation\powershell\

# Import both the FNCM CA and the OCP Ingress Router CA (standard first run)
.\Add-ClusterCerts.ps1

# Import the FNCM CA only (skip the OCP router CA)
.\Add-ClusterCerts.ps1 -SkipRouterCA

# Remove the imported CAs (e.g. after decommissioning the cluster)
.\Add-ClusterCerts.ps1 -Uninstall
```

### What it does

| Step | Action | Admin needed? |
|---|---|---|
| 1 | Reads the FNCM Root CA from secret `fncm-root-ca` in the `fncm` namespace via `oc` | No |
| 2 | Reads the OCP Ingress Router CA from `openshift-ingress-operator/router-ca` via `oc` | No |
| 3 | Displays subject, issuer, thumbprint and expiry of each CA | No |
| 4 | Skips any CA that is already present in `Cert:\LocalMachine\Root` | No |
| 5 | Imports untrusted CAs into `Cert:\LocalMachine\Root` | **Yes** |
| 6 | Verifies trust by making an HTTPS request to the Navigator URL | No |

> **Elevation**: if the script is not running as Administrator it saves the
> certificate DER files to a temp folder and launches a self-contained elevated
> helper via **one UAC prompt** (no `oc` CLI required in the elevated window).

### Why two CAs?

| CA | Where stored in cluster | What it signs |
|---|---|---|
| `fncmdeploy ICP4A Root CA` | Secret `fncm-root-ca` in `fncm` ns | All FNCM route certs (CPE, GraphQL, Navigator) |
| OCP Ingress Router CA | Secret `router-ca` in `openshift-ingress-operator` ns | OCP console and other built-in routes |

FNCM uses `reencrypt` route termination and provides its own custom route
certificates signed by its internal CA — so the browser sees certs issued by
`fncmdeploy ICP4A Root CA`, not by the OCP ingress CA.

### After import

1. **Restart your browser** (Chrome / Edge / Firefox each cache the certificate
   store differently; a full restart is required).
2. Open any FNCM URL — there should be no certificate warning.

---

## GraphQL – XSRF / Authentication

### Why the error occurs

In FNCM 25.x the operator hardcodes these env vars on the GraphQL deployment:

| Env var | Operator default | Effect |
|---|---|---|
| `ENABLE_GRAPHIQL` | `false` | Browser playground **disabled** |
| `DISABLE_BASIC_AUTH` | `true` | LDAP Basic Auth **disabled** — direct access returns 401 |
| `IBM_ICS_DISABLE_XSRF_CHECK` | *(absent)* | CSRF validation **on** |

Two failure modes result from these defaults:

| Error | Cause |
|---|---|
| **HTTP 401** on the GraphQL URL | `DISABLE_BASIC_AUTH=true` — no credential challenge is issued |
| **Error 500 – XSRF token is not valid** | A valid Liberty LTPA session cookie is present (e.g. carried from CPE or Navigator) but the request is missing the `XSRF-TOKEN` cookie / `X-XSRF-TOKEN` header that GraphQL expects for every call |

> **Why `oc set env` alone does not fix this**: the FNCM operator reconciles
> the GraphQL deployment every few minutes and resets any manually-applied env
> vars.  The operator must be **scaled to 0** before changing env vars.

---

### Option A – Navigator UI (recommended, no changes needed)

IBM Business Automation Navigator calls GraphQL internally; its own auth flow
handles XSRF transparently.

```
URL  : https://navigator-fncm.apps.<cluster>/navigator/
Login: cpadmin / Password
```

---

### Option B – GraphiQL browser playground + Basic Auth (dev mode)

Use the helper script, which scales the operator to 0, applies the three dev
env vars, waits for the pod to roll, then prints the playground URL:

```powershell
# From automation\powershell\
.\Enable-GraphQL-DevMode.ps1
```

Sample output:
```
[INFO]  Scaling FNCM operator to 0 (pausing reconciliation)...
[SUCCESS] Operator scaled down.
[INFO]  Applying dev env vars to GraphQL deployment...
[INFO]  Waiting for GraphQL pod to roll out...
[SUCCESS] GraphQL dev mode ENABLED.
[SUCCESS]   GraphQL Playground : https://graphql-fncm.apps.<cluster>/content-services-graphql/
[INFO]    Login credentials  : cpadmin / Password
[WARN]    The FNCM operator is paused (replicas=0). When finished:
            .\Enable-GraphQL-DevMode.ps1 -Disable
```

Restore the operator when done (it will reconcile and reset env vars back to
production defaults):

```powershell
.\Enable-GraphQL-DevMode.ps1 -Disable
```

**Manual equivalent:**

```bash
# 1. Pause operator
oc scale deployment ibm-fncm-operator --replicas=0 -n fncm

# 2. Apply dev settings
oc set env deployment/fncmdeploy-graphql-deploy \
  ENABLE_GRAPHIQL=true \
  DISABLE_BASIC_AUTH=false \
  IBM_ICS_DISABLE_XSRF_CHECK=true \
  -n fncm

# 3. Wait for rollout
oc rollout status deployment/fncmdeploy-graphql-deploy -n fncm

# 4. Use playground at https://graphql-fncm.apps.<cluster>/content-services-graphql/
#    (login: cpadmin / Password)

# 5. Restore operator when done
oc scale deployment ibm-fncm-operator --replicas=1 -n fncm
```

> ⚠️ **Before running `Install-FNCM.ps1` or `Teardown-FNCM.ps1`** while dev
> mode is active, always restore the operator first with `-Disable` so it can
> reconcile cleanly.

---

### Option C – Direct API access via Liberty form login (operator running)

When you need to keep the operator running and make programmatic GraphQL calls:

```bash
GQL=https://graphql-fncm.apps.<cluster>/content-services-graphql

# 1. Authenticate via Liberty form login (gets LTPA + XSRF-TOKEN cookies)
curl -k -c /tmp/gql-cookies.txt -b /tmp/gql-cookies.txt \
  -X POST \
  -d "j_username=cpadmin&j_password=Password" \
  "$GQL/j_security_check"

# 2. Extract XSRF token
XSRF=$(grep -i "xsrf-token" /tmp/gql-cookies.txt | awk '{print $NF}' | tail -1)

# 3. Execute a GraphQL query
curl -k -b /tmp/gql-cookies.txt \
  -H "X-XSRF-TOKEN: $XSRF" \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{"query":"{ objectStores { objectStores { id displayName } } }"}' \
  "$GQL/graphql"
```

---

## Known Fixes / Pitfalls

| Symptom | Root Cause | Fix |
|---|---|---|
| `oc cp` fails with "one of src or dest must be a local file specification" | Windows drive letter (`C:`) misread as pod spec | `Copy-ToPod` uses `Push-Location` to the parent dir and passes only the leaf filename |
| `bash: \r': command not found` | PowerShell here-strings use `\r\n`; bash sees stray carriage returns | `Invoke-PodExec` strips CR before handing to bash |
| `No such option: --silent-config` | `deployoperator.py` and `prerequisites.py` use `--silent` boolean flag, not `--silent-config <path>` | Copy TOML to hardcoded `scripts/silent_config/` path; pass `--silent` |
| `EOFError: EOF when reading a line` (prerequisites.py generate) | Without `--silent`, generate prompts for namespace | Add `--silent` to the generate command |
| PowerShell variable not set (`$PROP`, `$CR`) | `\$VAR` in a PS here-string is NOT an escaped `$` — it's literal `\` + expanded `$VAR` | Assign to a PowerShell variable first (`$PROP_PATH = ...`) and use `${PROP_PATH}` |
| `fncm_components_options.toml: No such file or directory` | File only generated when Task Manager is enabled | Wrap sed in `if [ -f ... ]` conditional |
| `propertyFile` path not found | `prerequisites.py` stores files in `propertyFile/{namespace}/` | Config path includes `/$FNCM_NAMESPACE` subdirectory |
| `/pgsqldata/devicn_tbs` does not exist | Tablespace LOCATION used tablespace name, not DB name | mkdir uses `$ICN_DB_NAME` (`devicn`), not `$ICN_TABLESPACE` (`devicn_tbs`) |
| `'dict object' has no attribute 'tds'` (CPE + GraphQL pre-deploy) | `sed 's/tds:/custom:/g'` renamed the LDAP section but Ansible still accesses `.tds` unconditionally | Python patch keeps **both** `tds:` and `custom:` sections in the CR |
| **`NET::ERR_CERT_AUTHORITY_INVALID`** in browser for all FNCM URLs | FNCM uses its own internal CA (`fncmdeploy ICP4A Root CA`) to sign route certs; this CA is not in the Windows trust store | Run `.\Add-ClusterCerts.ps1` — fetches both the FNCM CA and the OCP Router CA from the cluster and imports them into `Cert:\LocalMachine\Root` |
| **IER (or ICCSAP) pod stuck in `Pending` / `CrashLoopBackOff`** — operator event: `secret "ibm-ier-secret" not found` | Step 7d previously applied only 3 hardcoded secret files; `ibm-ier-secret.yaml` (and `ibm-iccsap-secret.yaml`) were never applied | **Fixed** — step 7d now runs `oc apply -f secrets/` (all files), so every component secret generated by `prerequisites.py` is applied automatically |
| **HTTP 401** on `graphql-fncm.apps.<cluster>/content-services-graphql/` | Operator default `DISABLE_BASIC_AUTH=true` disables all credential-based entry | **Fixed automatically in step 7** — operator is scaled to 0 and `DISABLE_BASIC_AUTH=false` is applied after deployment |
| **Error 500 – XSRF token is not valid** on GraphQL endpoint | Liberty LTPA session present (from CPE/Navigator) but `XSRF-TOKEN` cookie missing; operator default omits `IBM_ICS_DISABLE_XSRF_CHECK` and reverts any manual `oc set env` changes | **Fixed automatically in step 7** — operator is scaled to 0 and `IBM_ICS_DISABLE_XSRF_CHECK=true` is applied permanently after deployment |

---

## Teardown & Re-run

The teardown script removes all FNCM resources from the cluster **and** the CA
certificates from the workstation trust store, leaving a completely clean slate.

```powershell
# Full teardown -- removes cluster resources AND workstation certs (interactive)
.\Teardown-FNCM.ps1

# Keep the install pod (saves ~20 min setup on the next run)
.\Teardown-FNCM.ps1 -KeepInstallPod

# Keep certs trusted on the workstation (handy for quick re-deploy with same CA)
.\Teardown-FNCM.ps1 -KeepCerts

# Non-interactive (CI/scripted)
.\Teardown-FNCM.ps1 -Force

# Full clean including CRDs (required for operator version upgrades)
.\Teardown-FNCM.ps1 -Force -DeleteCRDs
```

### Teardown sequence

The script runs in this fixed order, which matters:

| Step | Action | Why this order |
|---|---|---|
| **0** | Remove FNCM + OCP CA certs from `Cert:\LocalMachine\Root` | Must run **before** cluster deletion — needs `oc` to read cert thumbprints from `fncm-root-ca` secret |
| **1** | Strip FNCMCluster finalizers | Prevents namespace-delete from hanging indefinitely |
| **2** | Delete FNCMCluster CR | Signals operator to stop reconciling |
| **3** | Delete Subscription + CSV | Prevents OLM from reinstalling the operator |
| **4** | Delete namespaces (async) | Removes all namespaced resources including PVCs |
| **5** | Delete ClusterRoleBinding | Removes cluster-scoped RBAC |
| **6** | Delete CRDs (optional) | Only with `-DeleteCRDs` |
| **7** | Wait for namespace termination | Up to 15 min; reports stuck namespaces |
| **8** | Clear generated files in install pod | Only with `-KeepInstallPod` |

### What gets deleted

| Resource | Default | `-KeepInstallPod` | `-DeleteCRDs` | `-KeepCerts` |
|---|---|---|---|---|
| Workstation CA certs (`Cert:\LocalMachine\Root`) | ✅ removed | ✅ removed | ✅ removed | ❌ kept |
| FNCMCluster CR | ✅ | ✅ | ✅ | ✅ |
| FNCM Operator (Subscription/CSV) | ✅ | ✅ | ✅ | ✅ |
| Namespace `fncm` | ✅ | ✅ | ✅ | ✅ |
| Namespace `fncm-openldap` | ✅ | ✅ | ✅ | ✅ |
| Namespace `fncm-postgresql` | ✅ | ✅ | ✅ | ✅ |
| Namespace `fncm-install` | ✅ | ❌ preserved | ✅ | ✅ |
| Generated files inside install pod | n/a | ✅ cleared | n/a | n/a |
| ClusterRoleBinding | ✅ | ✅ | ✅ | ✅ |
| FNCMCluster CRD | ❌ | ❌ | ✅ | ❌ |

> **NFS note**: PVs with `Retain` reclaim policy are NOT deleted automatically.
> The teardown script lists any `Released` PVs at the end.  Delete them with
> `oc delete pv <name>` and clean the backing NFS share before re-running
> Step 6 (SQL scripts assume empty databases).

### Re-run options after teardown

```powershell
# Option A: fastest -- keep install pod AND certs (saves 20 min + skips cert reimport)
.\Teardown-FNCM.ps1 -KeepInstallPod -KeepCerts -Force
.\Install-FNCM.ps1          # wizard appears -- choose "Skip Step 1" (option 2)
# Certs already trusted -- no browser warnings on redeploy

# Option B: keep install pod, reimport certs after redeploy
.\Teardown-FNCM.ps1 -KeepInstallPod -Force
.\Install-FNCM.ps1          # wizard appears -- choose "Skip Step 1" (option 2)
# Cert import runs automatically at the end (one UAC prompt)

# Option C: completely clean slate (longest -- ~60-90 min total)
.\Teardown-FNCM.ps1 -Force
.\Install-FNCM.ps1          # wizard appears -- choose "Full deployment" (option 1)
# Cert import runs automatically at the end (one UAC prompt)
```

---

## File Structure

```
automation/powershell/
├── Install-FNCM.ps1              # Master orchestrator + interactive wizard
├── Teardown-FNCM.ps1             # Clean teardown for re-runs
├── Enable-GraphQL-DevMode.ps1    # Toggle GraphiQL + Basic Auth (scales operator)
├── Add-ClusterCerts.ps1          # Import FNCM + OCP CA certs into Windows trust store
├── config.ps1                    # All deployment variables (edit this)
├── config.session.ps1            # Auto-generated by wizard (do not edit; deleted after run)
├── common.psm1                   # Shared functions (Write-Log, Copy-ToPod, etc.)
└── steps/
    ├── 01-setup-install-client.ps1
    ├── 02-deploy-openldap.ps1
    ├── 03-deploy-postgresql.ps1
    ├── 04-deploy-operator.ps1
    ├── 05-gather-generate.ps1    # Reads all $DEPLOY_* flags → builds TOML → prerequisites.py
    ├── 06-apply-sql.ps1
    └── 07-deploy-fncm-cr.ps1
```

---

## Operator State Reference

| State | How to get there | Effect |
|---|---|---|
| **Running** (normal) | `oc scale deployment ibm-fncm-operator --replicas=1 -n fncm` | Operator reconciles every few minutes; **resets GraphQL env vars back to defaults** (XSRF error returns) |
| **Paused** ✅ (post-deploy default) | Applied automatically at end of step 7 | GraphQL XSRF fix persists; no reconciliation. Kubernetes still manages pod restarts normally |

> **The operator is intentionally paused after every deployment.**
> Step 7 scales it to 0 after FNCM is Ready so the GraphQL XSRF fix is permanent.
> Do **not** scale the operator back to 1 unless you need to apply a CR change or
> upgrade — doing so will cause the XSRF error to return until step 7 is re-run.

Check current operator state:
```bash
oc get deployment ibm-fncm-operator -n fncm -o jsonpath='{.spec.replicas}'
# 0 = paused (correct post-deploy state)
# 1 = running (will revert GraphQL env vars on next reconcile)
```

If you scaled the operator back to 1 and the XSRF error returned, re-apply the fix:
```powershell
.\Install-FNCM.ps1 -Step 7
# or manually:
oc scale deployment ibm-fncm-operator --replicas=0 -n fncm
oc set env deployment/fncmdeploy-graphql-deploy IBM_ICS_DISABLE_XSRF_CHECK=true ENABLE_GRAPHIQL=true DISABLE_BASIC_AUTH=false -n fncm
oc rollout status deployment/fncmdeploy-graphql-deploy -n fncm
```
