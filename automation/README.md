# FNCM Automated Deployment

Automates the full IBM FileNet Content Manager deployment on OpenShift.
Supports two equivalent approaches: **PowerShell** (primary, runs natively on Windows) and **Ansible** (cross-platform).

---

## Prerequisites

| Tool | Required by | Notes |
|------|-------------|-------|
| OpenShift CLI (`oc`) | Both | Must be logged in: `oc login` |
| PowerShell 5.1+ | PS scripts | Built-in on Windows 10/11 |
| Python 3.8+ | Ansible | For `pip install ansible` |
| Ansible 2.14+ | Ansible only | `pip install ansible kubernetes` |
| `kubernetes.core` collection | Ansible only | `ansible-galaxy collection install kubernetes.core` |

### IBM Entitlement Key
Obtain from <https://myibm.ibm.com/products-services/containerlibrary> — required to pull FNCM operator images.

---

## Deployment Steps Automated

| Step | Description |
|------|-------------|
| 1 | Create `fncm-install` namespace, PVC, ClusterRoleBinding, and install pod |
| 2 | Deploy OpenLDAP into `fncm-openldap` |
| 3 | Deploy PostgreSQL into `fncm-postgresql` |
| 4 | Deploy FNCM Operator into `fncm` namespace |
| 5 | Gather config (silent mode) → patch property files → generate SQL/secrets/CR |
| 6 | Apply database SQL scripts to PostgreSQL |
| 7 | Apply network policies, secrets, and FNCM Custom Resource |

---

## PowerShell (Windows)

### Quick Start

```powershell
# 1. Edit configuration
notepad automation\powershell\config.ps1

# 2. Login to your OCP cluster
oc login --server=https://api.your-cluster.example.com:6443

# 3. Run full deployment
cd automation\powershell
.\Install-FNCM.ps1
```

### Run individual steps

```powershell
# Run only step 2 (OpenLDAP)
.\Install-FNCM.ps1 -Step 2

# Run from step 4 onwards (prereqs already deployed)
.\Install-FNCM.ps1 -SkipSteps 1,2,3

# Use a custom config file
.\Install-FNCM.ps1 -ConfigFile C:\my-env\fncm-prod-config.ps1
```

### File structure

```
automation\powershell\
├── config.ps1              # All configuration variables  ← EDIT THIS
├── common.psm1             # Shared utility functions
├── Install-FNCM.ps1        # Master orchestration script
└── steps\
    ├── 01-setup-install-client.ps1
    ├── 02-deploy-openldap.ps1
    ├── 03-deploy-postgresql.ps1
    ├── 04-deploy-operator.ps1
    ├── 05-gather-generate.ps1
    ├── 06-apply-sql.ps1
    └── 07-deploy-fncm-cr.ps1
```

---

## Ansible (Cross-platform)

### Install dependencies

```bash
# On Windows (PowerShell) - no WSL needed
pip install ansible kubernetes

# Install required Ansible collection
ansible-galaxy collection install kubernetes.core
```

### Quick Start

```bash
# 1. Edit variables
notepad automation\ansible\group_vars\all.yml   # Windows
# or
nano automation/ansible/group_vars/all.yml       # Linux/macOS

# 2. Login to OCP
oc login --server=https://api.your-cluster.example.com:6443

# 3. Run full deployment
ansible-playbook -i automation/ansible/inventory.yml automation/ansible/site.yml
```

### Run individual roles (using tags)

```bash
# Deploy only OpenLDAP and PostgreSQL
ansible-playbook -i inventory.yml site.yml --tags prereqs

# Skip install client (already deployed)
ansible-playbook -i inventory.yml site.yml --skip-tags install_client

# Run from FNCM operator step onwards
ansible-playbook -i inventory.yml site.yml --tags fncm_operator,fncm_configure,fncm_deploy

# Dry run (check mode)
ansible-playbook -i inventory.yml site.yml --check
```

### File structure

```
automation/ansible/
├── site.yml                    # Main playbook
├── inventory.yml               # Localhost inventory
├── group_vars/
│   └── all.yml                 # All variables  ← EDIT THIS
└── roles/
    ├── install_client/tasks/main.yml
    ├── openldap/tasks/main.yml
    ├── postgresql/tasks/main.yml
    ├── fncm_operator/tasks/main.yml
    ├── fncm_configure/tasks/main.yml   # gather + generate + SQL
    └── fncm_deploy/tasks/main.yml      # secrets + CR + wait
```

---

## Configuration Reference

Both `config.ps1` (PowerShell) and `group_vars/all.yml` (Ansible) share the same variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `STORAGE_CLASS_NAME` | `nfs-homelab` | RWX StorageClass for PVCs |
| `IBM_ENTITLEMENT_KEY` | _(empty)_ | **Required** for image pulls |
| `FNCM_NAMESPACE` | `fncm` | Target namespace for FNCM |
| `FNCM_LICENSE` | `FNCM.PVUNonProd` | License type |
| `POSTGRES_HOST` | `postgresql.fncm-postgresql.svc.cluster.local` | Internal service DNS |
| `LDAP_HOST` | `openldap.fncm-openldap.svc.cluster.local` | Internal service DNS |
| `NETWORK_CIDR` | `10.2.1.0/0` | Egress network policy CIDR |

---

## Monitoring Deployment Progress

```powershell
# Watch operator CSV status
oc get csv -n fncm -w

# Watch operator logs
oc logs deployment/ibm-fncm-operator -n fncm -f

# Watch FNCM component status
oc get FNCMCluster fncmdeploy -n fncm -o jsonpath='{.status.components}' | jq

# Get access URLs after completion
oc get cm fncmdeploy-fncm-access-info -n fncm -o yaml
```

---

## Troubleshooting

### Install pod setup is slow
The first run downloads JDK (~200 MB), oc client, pip packages, and clones the repo. Allow 15-20 min. Check progress:
```powershell
oc logs -n fncm-install install -f
```

### prerequisites.py gather fails in silent mode
If the `--silent-config` flag is not supported in your version, run gather interactively instead and re-run from step 5:
```powershell
oc exec -n fncm-install install -- bash
cd /usr/install/ibm-fncm-containers/scripts
python3 prerequisites.py gather   # answer prompts, then Ctrl+D
.\Install-FNCM.ps1 -Step 5        # run remaining patch + generate
```

### SQL apply fails (relation already exists)
The databases may already exist from a previous run. Drop and recreate:
```powershell
oc exec -n fncm-postgresql statefulset/postgresql -- bash -c `
  "psql postgresql://cpadmin@localhost:5432/postgresdb -c 'DROP DATABASE IF EXISTS devgcd;'"
```

### FNCM CR not reaching Ready
Check operator reconciliation logs:
```powershell
oc logs deployment/ibm-fncm-operator -n fncm --tail=100
oc describe FNCMCluster fncmdeploy -n fncm
```

---

## Cleanup

```powershell
# Remove all FNCM namespaces (WARNING: destructive)
oc delete project fncm fncm-install fncm-openldap fncm-postgresql
oc delete clusterrolebinding cluster-admin-fncm-install
```
