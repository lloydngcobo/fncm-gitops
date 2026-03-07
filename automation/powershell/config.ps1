# =============================================================================
# IBM FNCM Automated Deployment - Configuration
# =============================================================================
# Edit ALL values in this file before running any installation scripts.
# Passwords shown here are EXAMPLES - replace with your own secure values.

# --- OpenShift Cluster Connection ---
$OCP_API_URL = "https://api.homelab.home.nl:6443"
$OCP_TOKEN   = ""   # Leave empty to use current 'oc login' session

# --- Namespaces ---
$INSTALL_NAMESPACE    = "fncm-install"
$OPENLDAP_NAMESPACE   = "fncm-openldap"
$POSTGRESQL_NAMESPACE = "fncm-postgresql"
$FNCM_NAMESPACE       = "fncm"

# --- Storage Class ---
# Replace with the name of your RWX-capable StorageClass
$STORAGE_CLASS_NAME = "nfs-homelab"

# --- OpenLDAP ---
$LDAP_ADMIN_PASSWORD = "Password"
$LDAP_ORGANISATION   = "cp.internal"
$LDAP_ROOT           = "dc=cp,dc=internal"
$LDAP_DOMAIN         = "cp.internal"
$LDAP_HOST           = "openldap.fncm-openldap.svc.cluster.local"
$LDAP_BIND_DN        = "cn=admin,dc=cp,dc=internal"
$LDAP_PORT           = "389"

# --- PostgreSQL ---
$POSTGRES_DB       = "postgresdb"
$POSTGRES_USER     = "cpadmin"
$POSTGRES_PASSWORD = "Password"
$POSTGRES_HOST     = "postgresql.fncm-postgresql.svc.cluster.local"
$POSTGRES_PORT     = "5432"

# --- FNCM Databases (created inside PostgreSQL) ---
$GCD_DB_NAME     = "devgcd"
$GCD_DB_USER     = "devgcd"
$GCD_DB_PASSWORD = "Password"

$OS1_DB_NAME     = "devos1"
$OS1_DB_USER     = "devos1"
$OS1_DB_PASSWORD = "Password"

# OS2 and OS3 are only used when DEPLOY_IER = $true
# OS1 remains the general content repository; IER adds dedicated ROS and FPOS stores on top
$OS2_DB_NAME     = "devos2"   # ROS  - Records Object Store       (IER)
$OS2_DB_USER     = "devos2"
$OS2_DB_PASSWORD = "Password"

$OS3_DB_NAME     = "devos3"   # FPOS - File Plan Object Store      (IER)
$OS3_DB_USER     = "devos3"
$OS3_DB_PASSWORD = "Password"

$ICN_DB_NAME    = "devicn"
$ICN_DB_USER    = "devicn"
$ICN_DB_PASSWORD = "Password"
$ICN_TABLESPACE = "devicn_tbs"
$ICN_SCHEMA     = "devicn"

# --- FNCM Credentials ---
$FNCM_ADMIN_USER     = "cpadmin"
$FNCM_ADMIN_PASSWORD = "Password"
$FNCM_ADMIN_GROUP    = "cpadmins"
$FNCM_USER_GROUP     = "cpusers"
$KEYSTORE_PASSWORD   = "Password"
$LTPA_PASSWORD       = "Password"

# IBM Entitlement Key - obtain from:
# https://myibm.ibm.com/products-services/containerlibrary
$IBM_ENTITLEMENT_KEY = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJJQk0gTWFya2V0cGxhY2UiLCJpYXQiOjE3NzE5NjQ4MjEsImp0aSI6ImJmOTk0ZWI2MTRmNzRmNDRhYjFjOGE0YTNlYzA1YzdlIn0.Q1cjaN0DINAE8Py3zskDrvhukadH3GTTEuYl02WojFA"

# --- FNCM License ---
# Options: FNCM.PVUProd, FNCM.PVUNonProd, FNCM.UVU, FNCM.CU
$FNCM_LICENSE = "FNCM.PVUNonProd"

# --- Components to Deploy ---
# CPE is always required. All others are optional.
# The interactive wizard (.\Install-FNCM.ps1) overrides these for a single run
# without modifying this file. Set defaults here for -Force / -Step runs.
$DEPLOY_CPE     = $true
$DEPLOY_GRAPHQL = $true
$DEPLOY_BAN     = $true
$DEPLOY_CSS     = $false
$DEPLOY_CMIS    = $false
$DEPLOY_TM      = $false
$DEPLOY_ES      = $false
$DEPLOY_IER     = $true    # IBM Enterprise Records - records management and retention
$DEPLOY_ICCSAP  = $false

# --- Paths (inside the install pod, Linux paths) ---
$INSTALL_PATH           = "/usr/install"
$CONTAINER_SAMPLES_PATH = "/usr/install/ibm-fncm-containers"
$PROPERTY_FILE_PATH     = "/usr/install/ibm-fncm-containers/scripts/propertyFile/$FNCM_NAMESPACE"
$GENERATED_FILES_PATH   = "/usr/install/ibm-fncm-containers/scripts/generatedFiles/$FNCM_NAMESPACE"

# --- Source Repository ---
$FNCM_REPO_URL = "https://github.com/ibm-ecm/ibm-fncm-containers.git"

# --- Network Policy ---
$NETWORK_CIDR = "10.2.1.0/0"

# --- Container Images ---
$UBI_IMAGE        = "ubi9/ubi:9.3"
$OPENLDAP_IMAGE   = "bitnamilegacy/openldap:2.6.5"
$POSTGRESQL_IMAGE = "postgres:14.7-alpine3.17"
$JDK_URL          = "https://github.com/ibmruntimes/semeru21-binaries/releases/download/jdk-21.0.4%2B7_openj9-0.46.1/ibm-semeru-open-jdk_x64_linux_21.0.4_7_openj9-0.46.1.tar.gz"
$JDK_DIR          = "jdk-21.0.4+7"

# --- ArgoCD / OpenShift GitOps ---
# Set CONFIGURE_ARGOCD = $true to register an ArgoCD Application in the
# existing OpenShift GitOps instance that watches the FNCM namespace for drift.
# Requires OpenShift GitOps operator to already be installed on the cluster.
$CONFIGURE_ARGOCD        = $true
$ARGOCD_NAMESPACE        = "openshift-gitops"  # namespace where ArgoCD is installed
$ARGOCD_APP_NAME         = "fncm-deploy"       # name of the ArgoCD Application resource

# Your GitOps repository that holds the desired FNCM manifests (FNCMCluster CR,
# secrets, network policies, etc.).  ArgoCD compares these against the live cluster.
# Leave ARGOCD_GITOPS_REPO_URL empty to configure access only (no Application created).
$ARGOCD_GITOPS_REPO_URL  = "https://github.com/lloydngcobo/fncm-gitops"
$ARGOCD_GITOPS_REPO_PATH = "manifests"  # directory within the repo containing FNCM manifests
$ARGOCD_GITOPS_REVISION  = "HEAD"       # branch, tag, or commit SHA to track

# Local workstation path to your cloned GitOps repository.
# When set, step 8 exports the FNCMCluster manifest directly into
#   <ARGOCD_GITOPS_LOCAL_REPO_PATH>\<ARGOCD_GITOPS_REPO_PATH>\
# so you only need to run: git -C <path> add . && git commit && git push
# Leave blank to export to .\gitops-export\ instead.
$ARGOCD_GITOPS_LOCAL_REPO_PATH = "C:\repos\fncm-gitops"

# Sync policy defaults: all-false = manual sync (drift detection / alerts only).
# Set AUTO_SYNC = $true to have ArgoCD apply Git changes automatically.
# Set SELF_HEAL = $true to have ArgoCD revert manual cluster edits to Git state.
# Set PRUNE     = $true to delete cluster resources that disappear from Git (use with care).
$ARGOCD_AUTO_SYNC        = $false
$ARGOCD_SELF_HEAL        = $false
$ARGOCD_PRUNE            = $false
