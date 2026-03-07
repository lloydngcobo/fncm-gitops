# Step 1 - Create the fncm-install namespace, PVC, ClusterRoleBinding and install pod
. (Join-Path $PSScriptRoot ".." "config.ps1")
$_s = Join-Path $PSScriptRoot ".." "config.session.ps1"; if (Test-Path $_s) { . $_s }; Remove-Variable _s -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot ".." "common.psm1") -Force -DisableNameChecking

# ── Project ───────────────────────────────────────────────────────────────────
Apply-Yaml @"
kind: Project
apiVersion: project.openshift.io/v1
metadata:
  name: ${INSTALL_NAMESPACE}
  labels:
    app: fncm-install
"@ "Project ${INSTALL_NAMESPACE}"

# ── Persistent Volume Claim ───────────────────────────────────────────────────
Apply-Yaml @"
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: install
  namespace: ${INSTALL_NAMESPACE}
  labels:
    app: fncm-install
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS_NAME}
  volumeMode: Filesystem
"@ "PVC install"

# ── ClusterRoleBinding (cluster-admin for the install pod SA) ─────────────────
Apply-Yaml @"
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: cluster-admin-fncm-install
  labels:
    app: fncm-install
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: "system:serviceaccount:${INSTALL_NAMESPACE}:default"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
"@ "ClusterRoleBinding cluster-admin-fncm-install"

# ── Install Pod ───────────────────────────────────────────────────────────────
# Only create if it doesn't exist already (pod is long-lived / stateful setup)
if (-not (Test-ResourceExists "pod" "install" $INSTALL_NAMESPACE)) {
    Write-Log "Creating install pod (first-time setup takes ~10 min)..." "INFO"
    Apply-Yaml @"
kind: Pod
apiVersion: v1
metadata:
  name: install
  namespace: ${INSTALL_NAMESPACE}
  labels:
    app: fncm-install
spec:
  containers:
    - name: install
      securityContext:
        privileged: true
      image: ${UBI_IMAGE}
      command: ["/bin/bash"]
      args:
        - "-c"
        - |
          set -e
          cd /usr
          yum install podman ncurses jq python3.9 python3.9-pip git -y
          curl -LO '${JDK_URL}'
          tar -xzf ibm-semeru-open-jdk_x64_linux_21.0.4_7_openj9-0.46.1.tar.gz
          ln -fs /usr/${JDK_DIR}/bin/java /usr/bin/java
          ln -fs /usr/${JDK_DIR}/bin/keytool /usr/bin/keytool
          curl -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz --output oc.tar
          tar -xvf oc.tar oc
          chmod u+x oc
          ln -fs /usr/oc /usr/bin/oc
          curl -LO "https://dl.k8s.io/release/`$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
          chmod u+x kubectl
          ln -fs /usr/kubectl /usr/bin/kubectl
          curl -LO https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_amd64.tar.gz
          tar -xzvf yq_linux_amd64.tar.gz
          ln -fs /usr/yq_linux_amd64 /usr/bin/yq
          pip3 install typer~=0.15.1 rich~=13.9.4 kubernetes==32.0.1 toml~=0.10.2 \
            requests~=2.32.3 xmltodict~=0.14.2 PyYAML~=6.0.2 tomlkit~=0.13.2 \
            cryptography~=44.0.1 docker~=7.1.0 urllib3~=2.2.3 pyOpenSSL~=25.0.0 \
            Jinja2~=3.1.6 packaging~=24.2 ruamel.yaml==0.18.10
          git clone ${FNCM_REPO_URL} ${CONTAINER_SAMPLES_PATH}
          # Sentinel: signals that setup is complete
          touch /usr/install/.setup_complete
          while true; do echo 'Install pod - Ready'; sleep 300; done
      imagePullPolicy: IfNotPresent
      volumeMounts:
        - name: install
          mountPath: /usr/install
  volumes:
    - name: install
      persistentVolumeClaim:
        claimName: install
"@ "install Pod"
} else {
    Write-Log "Install pod already exists - skipping creation." "WARN"
}

# ── Wait for pod to be Running ────────────────────────────────────────────────
Wait-PodReady -Namespace $INSTALL_NAMESPACE -LabelSelector "app=fncm-install" -TimeoutSeconds 120

# ── Wait for one-time setup to finish (repo clone, pip install, etc.) ─────────
Write-Log "Waiting for install pod setup to complete (can take up to 20 min on first run)..." "INFO"
$deadline = (Get-Date).AddMinutes(25)
while ((Get-Date) -lt $deadline) {
    $check = & oc exec -n $INSTALL_NAMESPACE install -- bash -c `
        "test -f /usr/install/.setup_complete && echo DONE" 2>&1
    if ($check -match "DONE") {
        Write-Log "Install pod setup is complete." "SUCCESS"
        break
    }
    $remaining = [int](($deadline - (Get-Date)).TotalSeconds / 60)
    Write-Log "Setup still running... ~${remaining} min remaining before timeout." "INFO"
    Start-Sleep -Seconds 30
}
if ($check -notmatch "DONE") {
    throw "Install pod setup did not complete within the timeout. Check: oc logs -n $INSTALL_NAMESPACE install"
}
