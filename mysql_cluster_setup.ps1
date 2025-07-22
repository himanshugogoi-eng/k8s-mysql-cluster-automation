param(
    [int]$InitialSize = 1,
    [int]$MaxSize = 3,
    [int]$CpuThreshold = 60,
    [string]$Namespace = "mysql-cluster"
)

function Write-Color ($Text, $Color="Cyan") {
    Write-Host $Text -ForegroundColor $Color
}

function Check-Command ($Cmd) {
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Color "ERROR: Please install $Cmd and ensure it's in your PATH." "Red"
        exit 1
    }
}

Write-Color "Validating prerequisites..."
Check-Command kubectl
Check-Command minikube

Write-Color "Checking Minikube status..."
if (-not (minikube status | Select-String 'Running')) {
    Write-Color "ERROR: Minikube is not running! Start it with 'minikube start --cpus=4 --memory=8g'" "Red"
    exit 1
}
Write-Color "Switching kubectl context to minikube..."
kubectl config use-context minikube | Out-Null

Write-Color "Creating namespace '$Namespace'..."
kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -

Write-Color "Deploying Percona XtraDB Cluster Operator..."
kubectl apply -n $Namespace -f https://raw.githubusercontent.com/percona/percona-xtradb-cluster-operator/main/deploy/bundle.yaml | Out-Null

Write-Color "Waiting for operator to be available..."
$Timeout = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 5
    $Status = kubectl -n $Namespace get deploy percona-xtradb-cluster-operator -o=jsonpath='{.status.availableReplicas}' 2>$null
    Write-Host -NoNewline "."
} until ($Status -ge 1 -or (Get-Date) -gt $Timeout)
Write-Host

if ($Status -lt 1) {
    Write-Color "Operator deployment did not become ready in time." "Red"
    exit 1
}
Write-Color "Operator is deployed." "Green"

# Create a random strong password for root
$RootPass = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | % {[char]$_})

Write-Color "Creating MySQL secrets..."
kubectl -n $Namespace delete secret my-db-secrets --ignore-not-found | Out-Null
kubectl -n $Namespace create secret generic my-db-secrets --from-literal=root=$RootPass --from-literal=users="" | Out-Null
Write-Color "Applying MySQL cluster custom resource..."
$ClusterYAML = @"
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBCluster
metadata:
  name: my-db-cluster
  namespace: $Namespace
spec:
  secretsName: my-db-secrets
  unsafeFlags:
    pxcSize: true
    
  pxc:
    size: $InitialSize
    image: percona/percona-xtradb-cluster:8.4.5-5.1  # <-- This is YAML, inside the here-string 	
    affinity:
      advanced: {}
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
      limits:
        memory: 1Gi
        cpu: 500m
    volumeSpec:
      persistentVolumeClaim:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 2Gi
  haproxy:
    enabled: true
    size: 2
    image: percona/percona-xtradb-cluster-operator:1.14.0-haproxy
"@
$ClusterYAML | kubectl apply -f -

Write-Color "Waiting for MySQL pods to start (can take 2-5 minutes)..."
$MaxRetries = 30
$Attempts = 0
do {
    Start-Sleep 10
    $Attempts++
    $ReadyCount = kubectl -n $Namespace get pods -l "app.kubernetes.io/component=pxc" --no-headers | Select-String "Running" | Measure-Object | % { $_.Count }
    Write-Host "Ready: $ReadyCount/$InitialSize"
    if ($Attempts -ge $MaxRetries) {
        Write-Color "Timeout waiting for MySQL pods to become Ready" "Red"
        exit 1
    }
} until ($ReadyCount -ge $InitialSize)

Write-Color "Cluster is up. Endpoint should be available via 'haproxy' service."
kubectl get svc -n $Namespace | Select-String "haproxy"

Write-Color "Root Password: $RootPass" "Yellow"

minikube addons enable metrics-server
Write-Color "Configuring a demo HPA (may require Kubernetes metrics-server addon)..."
$HPA = @"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-db-cluster-hpa
  namespace: $Namespace
spec:
  scaleTargetRef:
    apiVersion: pxc.percona.com/v1
    kind: PerconaXtraDBCluster
    name: my-db-cluster
  minReplicas: $InitialSize
  maxReplicas: $MaxSize
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: $CpuThreshold
"@
$HPA | kubectl apply -f -

Write-Color "Setup complete! Use the following to access your MySQL cluster:"
Write-Color "minikube service haproxy -n $Namespace" "Green"
Write-Color "Monitor pods: kubectl get pods -n $Namespace"
Write-Color "Monitor HPA: kubectl get hpa -n $Namespace"
Write-Color "Admin (root) password: $RootPass" "Yellow"
Write-Color "Docs: https://www.percona.com/doc/kubernetes-operator-for-pxc/index.html" "Cyan"

