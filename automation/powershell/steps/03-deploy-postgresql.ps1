# Step 3 - Deploy PostgreSQL into the fncm-postgresql namespace
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── Project ───────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Project
apiVersion: project.openshift.io/v1
metadata:
  name: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
"@ "Project ${POSTGRESQL_NAMESPACE}"

# ── Privileged SCC RoleBinding ────────────────────────────────────────────────
Apply-Yaml @"
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: postgresql-privileged
  namespace: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
subjects:
  - kind: ServiceAccount
    name: default
    namespace: ${POSTGRESQL_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
"@ "RoleBinding postgresql-privileged"

# ── Secret ────────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Secret
apiVersion: v1
metadata:
  name: postgresql-config
  namespace: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
stringData:
  POSTGRES_DB: '${POSTGRES_DB}'
  POSTGRES_USER: '${POSTGRES_USER}'
  POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
"@ "Secret postgresql-config"

# ── PVC - data ────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: postgresql-data
  namespace: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: ${STORAGE_CLASS_NAME}
  volumeMode: Filesystem
"@ "PVC postgresql-data"

# ── PVC - tablespaces (must be outside PGDATA) ────────────────────────────────
Apply-Yaml @"
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: postgresql-tablespaces
  namespace: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: ${STORAGE_CLASS_NAME}
  volumeMode: Filesystem
"@ "PVC postgresql-tablespaces"

# ── StatefulSet ───────────────────────────────────────────────────────────────
# The escape `$POSTGRES_USER and `$POSTGRES_DB are bash env-vars inside the pod;
# PowerShell backtick-$ produces a literal $ in the YAML/bash string.
Apply-Yaml @"
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: fncm-postgresql
  template:
    metadata:
      labels:
        app: fncm-postgresql
    spec:
      containers:
        - name: postgresql
          image: '${POSTGRESQL_IMAGE}'
          imagePullPolicy: IfNotPresent
          args:
            - '-c'
            - max_prepared_transactions=500
            - '-c'
            - max_connections=500
          securityContext:
            privileged: true
          ports:
            - containerPort: 5432
          resources:
            requests:
              memory: 2Gi
            limits:
              memory: 4Gi
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - exec pg_isready -U `$POSTGRES_USER -d `$POSTGRES_DB
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - exec pg_isready -U `$POSTGRES_USER -d `$POSTGRES_DB
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 6
            timeoutSeconds: 5
          startupProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - exec pg_isready -U `$POSTGRES_USER -d `$POSTGRES_DB
            periodSeconds: 10
            failureThreshold: 18
          envFrom:
            - secretRef:
                name: postgresql-config
          volumeMounts:
            - mountPath: /var/lib/postgresql/data
              name: postgresql-data
            - mountPath: /pgsqldata
              name: postgresql-tablespaces
      volumes:
        - name: postgresql-data
          persistentVolumeClaim:
            claimName: postgresql-data
        - name: postgresql-tablespaces
          persistentVolumeClaim:
            claimName: postgresql-tablespaces
"@ "StatefulSet postgresql"

# ── Service ───────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Service
apiVersion: v1
metadata:
  name: postgresql
  namespace: ${POSTGRESQL_NAMESPACE}
  labels:
    app: fncm-postgresql
spec:
  type: NodePort
  ports:
    - port: 5432
  selector:
    app: fncm-postgresql
"@ "Service postgresql"

# ── Wait ──────────────────────────────────────────────────────────────────────
Wait-StatefulSetReady -Namespace $POSTGRESQL_NAMESPACE -Name "postgresql" -TimeoutSeconds 300

$svc = & oc get svc postgresql -n $POSTGRESQL_NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>&1
Write-Log "PostgreSQL ready.  NodePort: $svc  |  User: ${POSTGRES_USER}  |  DB: ${POSTGRES_DB}" "SUCCESS"
