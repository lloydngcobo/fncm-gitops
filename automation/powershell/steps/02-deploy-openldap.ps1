# Step 2 - Deploy OpenLDAP into the fncm-openldap namespace
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── Project ───────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Project
apiVersion: project.openshift.io/v1
metadata:
  name: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
"@ "Project ${OPENLDAP_NAMESPACE}"

# ── Privileged SCC RoleBinding ────────────────────────────────────────────────
Apply-Yaml @"
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: openldap-privileged
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
subjects:
  - kind: ServiceAccount
    name: default
    namespace: ${OPENLDAP_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
"@ "RoleBinding openldap-privileged"

# ── ConfigMap - environment variables ─────────────────────────────────────────
Apply-Yaml @"
kind: ConfigMap
apiVersion: v1
metadata:
  name: openldap-env
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
data:
  BITNAMI_DEBUG: 'true'
  LDAP_ORGANISATION: '${LDAP_ORGANISATION}'
  LDAP_ROOT: '${LDAP_ROOT}'
  LDAP_DOMAIN: '${LDAP_DOMAIN}'
"@ "ConfigMap openldap-env"

# ── ConfigMap - schema + user LDIF ────────────────────────────────────────────
# Note: passwords in LDIF are plain-text for development/testing only.
# Replace with hashed values for production.
Apply-Yaml @"
kind: ConfigMap
apiVersion: v1
metadata:
  name: openldap-customldif
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
data:
  01-sds-schema.ldif: |-
    dn: cn=sds,cn=schema,cn=config
    objectClass: olcSchemaConfig
    cn: sds
    olcAttributeTypes: {0}( 1.3.6.1.4.1.42.2.27.4.1.6 NAME 'ibm-entryUuid' DESC
      'Uniquely identifies a directory entry throughout its life.' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
    olcObjectClasses: {0}( 1.3.6.1.4.1.42.2.27.4.2.1 NAME 'sds' DESC 'sds' SUP top AUXILIARY MUST ( cn `$ ibm-entryuuid ) )
  02-default-users.ldif: |-
    dn: ${LDAP_ROOT}
    objectClass: top
    objectClass: dcObject
    objectClass: organization
    o: ${LDAP_ORGANISATION}
    dc: cp

    dn: ou=Users,${LDAP_ROOT}
    objectClass: organizationalUnit
    ou: Users

    dn: ou=Groups,${LDAP_ROOT}
    objectClass: organizationalUnit
    ou: Groups

    dn: uid=cpadmin,ou=Users,${LDAP_ROOT}
    objectClass: inetOrgPerson
    objectClass: sds
    objectClass: top
    cn: cpadmin
    sn: cpadmin
    uid: cpadmin
    mail: cpadmin@${LDAP_DOMAIN}
    userpassword: ${FNCM_ADMIN_PASSWORD}
    employeeType: admin
    ibm-entryuuid: e6c41859-ced3-4772-bfa3-6ebbc58ec78a

    dn: uid=cpuser,ou=Users,${LDAP_ROOT}
    objectClass: inetOrgPerson
    objectClass: sds
    objectClass: top
    cn: cpuser
    sn: cpuser
    uid: cpuser
    mail: cpuser@${LDAP_DOMAIN}
    userpassword: ${FNCM_ADMIN_PASSWORD}
    ibm-entryuuid: 40324128-84c8-48c3-803d-4bef500f84f1

    dn: cn=cpadmins,ou=Groups,${LDAP_ROOT}
    objectClass: groupOfNames
    objectClass: sds
    objectClass: top
    cn: cpadmins
    ibm-entryuuid: 53f96449-2b7e-4402-a58a-9790c5089dd0
    member: uid=cpadmin,ou=Users,${LDAP_ROOT}

    dn: cn=cpusers,ou=Groups,${LDAP_ROOT}
    objectClass: groupOfNames
    objectClass: sds
    objectClass: top
    cn: cpusers
    ibm-entryuuid: 30183bb0-1012-4d23-8ae2-f94816b91a75
    member: uid=cpadmin,ou=Users,${LDAP_ROOT}
    member: uid=cpuser,ou=Users,${LDAP_ROOT}
"@ "ConfigMap openldap-customldif"

# ── Secret ────────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Secret
apiVersion: v1
metadata:
  name: openldap
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
stringData:
  LDAP_ADMIN_PASSWORD: '${LDAP_ADMIN_PASSWORD}'
"@ "Secret openldap"

# ── PVC ───────────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: openldap-data
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS_NAME}
  volumeMode: Filesystem
"@ "PVC openldap-data"

# ── Deployment ────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Deployment
apiVersion: apps/v1
metadata:
  name: openldap
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fncm-openldap
  template:
    metadata:
      labels:
        app: fncm-openldap
    spec:
      containers:
        - name: openldap
          image: '${OPENLDAP_IMAGE}'
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          ports:
            - name: ldap-port
              containerPort: 1389
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          startupProbe:
            tcpSocket:
              port: ldap-port
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            tcpSocket:
              port: ldap-port
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 10
          livenessProbe:
            tcpSocket:
              port: ldap-port
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 10
          envFrom:
            - configMapRef:
                name: openldap-env
            - secretRef:
                name: openldap
          volumeMounts:
            - name: data
              mountPath: /bitnami/openldap/
            - name: custom-ldif-files
              mountPath: /ldifs/02-default-users.ldif
              subPath: 02-default-users.ldif
            - name: custom-ldif-files
              mountPath: /schemas/01-sds-schema.ldif
              subPath: 01-sds-schema.ldif
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openldap-data
        - name: custom-ldif-files
          configMap:
            name: openldap-customldif
            defaultMode: 420
"@ "Deployment openldap"

# ── Service ───────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Service
apiVersion: v1
metadata:
  name: openldap
  namespace: ${OPENLDAP_NAMESPACE}
  labels:
    app: fncm-openldap
spec:
  type: NodePort
  ports:
    - name: ldap-port
      protocol: TCP
      port: 389
      targetPort: ldap-port
  selector:
    app: fncm-openldap
"@ "Service openldap"

# ── Wait ──────────────────────────────────────────────────────────────────────
Wait-DeploymentReady -Namespace $OPENLDAP_NAMESPACE -Name "openldap" -TimeoutSeconds 600

$svc = & oc get svc openldap -n $OPENLDAP_NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>&1
Write-Log "OpenLDAP ready.  NodePort: $svc  |  Bind DN: ${LDAP_BIND_DN}  |  Password: ${LDAP_ADMIN_PASSWORD}" "SUCCESS"
