# Percona XtraDB Cluster Automation on Minikube (Windows)

This project delivers a **one-command PowerShell script** that spins up a minimal Percona XtraDB Cluster (MySQL) on a local Minikube installation.  
It is aimed at developers who want to experiment with database-aware Kubernetes operators on Windows 10/11 (WSL 2 or Hyper-V back-end).

| Item | Value |
|------|-------|
| **Operator version** | v1.18 |
| **PXC image** | percona/percona-xtradb-cluster:8.4.5-5.1 |
| **HAProxy image** | percona/percona-xtradb-cluster-operator:1.14.0-haproxy |
| **Tested on** | Windows 11, Minikube v1.36, Kubernetes v1.33 |

---

## Quick Start

1. Clone
git clone https://github.com/<your-user>/k8s-mysql-cluster-automation.git
cd k8s-mysql-cluster-automation

2. Start Minikube (single node, 4 CPU, 8 GB RAM)
minikube start --cpus=4 --memory=8g

3. Deploy cluster (defaults: size 1, HPA 1-3, 60% CPU)
.\mysql_cluster_setup.ps1

text

When the script finishes it prints:

* Namespace name  
* HAProxy service IP/port  
* Root password  
* Commands to monitor pods and HPA

Connect with any MySQL client:

mysql -h <service-ip> -P <port> -u root -p

text

---

## Parameters

| Switch | Default | Description |
|--------|---------|-------------|
| `-InitialSize` | `1` | PXC pod replicas on first deployment |
| `-MaxSize` | `3` | Maximum replicas the HPA may create |
| `-CpuThreshold` | `60` | Average CPU % that triggers scale-up |
| `-Namespace` | `mysql-cluster` | Kubernetes namespace |

Example:

.\mysql_cluster_setup.ps1 -InitialSize 2 -MaxSize 4 -CpuThreshold 50 -Namespace demo-mysql

text

---

## Cleanup

Remove cluster only
`kubectl -n mysql-cluster delete PerconaXtraDBCluster my-db-cluster
kubectl -n mysql-cluster delete pvc --all

Remove everything (operator, HPA, namespace)
kubectl delete namespace mysql-cluster

text

---

## Repository Structure

k8s-mysql-cluster-automation/
├─ mysql_cluster_setup.ps1 # main automation script
├─ README.md # this file
└─ docs/ # optional extras (troubleshooting, diagrams)

text

---

## Troubleshooting FAQ

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `ImagePullBackOff` for PXC | Wrong or nonexistent image tag | Use a tag that exists on Docker Hub |
| Namespace stuck **Terminating** | Finalisers blocking deletion | Remove finalisers via `kubectl proxy` & PUT `/finalize` |
| Pod **Pending** with anti-affinity error | Single-node Minikube | Script sets `affinity.advanced: {}` so pods can co-locate |
| HPA never scales | `metrics-server` disabled | Script enables add-on; verify with `kubectl top pods` |

---

## License

MIT
2 mysql_cluster_setup.ps1
powershell
<#
.SYNOPSIS
    Single-command deployment of Percona XtraDB Cluster on Minikube (Windows).

.DESCRIPTION
    • Validates kubectl & minikube.
    • Deploys Percona XtraDB Cluster Operator v1.18 into a dedicated namespace.
    • Generates secure secrets.
    • Creates a minimal PXC cluster (default size 1) with HAProxy front-end.
    • Enables metrics-server and sets up a demo HPA.
    • Waits for PXC pods to become Ready, then prints connection details.

.NOTES
    Author : <Your Name>
    Created: 2025-07-22
#>

param(
    [int]   $InitialSize  = 1,
    [int]   $MaxSize      = 3,
    [int]   $CpuThreshold = 60,
    [string]$Namespace    = "mysql-cluster"
)

function Write-Color { param($Text,$Color="Cyan") ; Write-Host $Text -ForegroundColor $Color }
function Check-Command { if(-not(Get-Command $args[0] -ErrorAction SilentlyContinue)){ Write-Color "ERROR: $($args[0]) not found in PATH." "Red"; exit 1 } }

# 1. Prerequisite checks ------------------------------------------------------
Write-Color "Validating prerequisites..."
Check-Command kubectl
Check-Command minikube

Write-Color "Checking Minikube status..."
if(-not (minikube status | Select-String 'Running')){
    Write-Color "ERROR: Minikube is not running. Start with 'minikube start --cpus=4 --memory=8g'." Red
    exit 1
}
kubectl config use-context minikube | Out-Null

# 2. Namespace & operator -----------------------------------------------------
Write-Color "Creating namespace '$Namespace'..."
kubectl create ns $Namespace --dry-run=client -o yaml | kubectl apply -f -

Write-Color "Deploying Percona XtraDB Cluster Operator..."
$operatorUri = "https://raw.githubusercontent.com/percona/percona-xtradb-cluster-operator/v1.18.0/deploy/bundle.yaml"
kubectl apply -n $Namespace -f $operatorUri | Out-Null

Write-Color "Waiting for operator deployment..."
$timeout = (Get-Date).AddMinutes(3)
do{
    Start-Sleep 5
    $ready = kubectl -n $Namespace get deploy percona-xtradb-cluster-operator -o=jsonpath='{.status.availableReplicas}' 2>$null
    Write-Host -NoNewline "."
}until($ready -ge 1 -or (Get-Date) -gt $timeout)
if($ready -lt 1){ Write-Color "`nOperator did not become ready." Red ; exit 1 }
Write-Color "`nOperator is deployed." Green

# 3. Secrets ------------------------------------------------------------------
$RootPass = -join ((65..90)+(97..122)+(48..57)|Get-Random -Count 16|%{[char]$_})
kubectl -n $Namespace delete secret my-db-secrets --ignore-not-found | Out-Null
kubectl -n $Namespace create secret generic my-db-secrets `
        --from-literal=root=$RootPass --from-literal=users="" | Out-Null

# 4. CustomResource for PXC cluster ------------------------------------------
Write-Color "Applying Percona XtraDB Cluster custom resource..."
$ClusterYaml = @"
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBCluster
metadata:
  name: my-db-cluster
spec:
  secretsName: my-db-secrets
  unsafeFlags:
    pxcSize: true
  pxc:
    size: $InitialSize
    image: percona/percona-xtradb-cluster:8.4.5-5.1
    affinity:
      advanced: {}              # allow scheduling on single node
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
    size: 1
    image: percona/percona-xtradb-cluster-operator:1.14.0-haproxy
"@
$ClusterYaml | kubectl apply -n $Namespace -f -

# 5. Wait for PXC pod readiness ----------------------------------------------
Write-Color "Waiting for MySQL pod readiness..."
$maxTries = 30
for($i=1;$i -le $maxTries;$i++){
    Start-Sleep 10
    $ready = kubectl -n $Namespace get pods -l app.kubernetes.io/component=pxc `
             --field-selector=status.phase=Running --no-headers 2>$null | Measure-Object | %{$_.Count}
    Write-Host "Ready: $ready/$InitialSize"
    if($ready -ge $InitialSize){ break }
    if($i -eq $maxTries){ Write-Color "Timeout waiting for pods." Red ; exit 1 }
}

# 6. Enable metrics-server & HPA ---------------------------------------------
minikube addons enable metrics-server | Out-Null
Write-Color "Creating HorizontalPodAutoscaler..."
@"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-db-cluster-hpa
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
"@ | kubectl apply -n $Namespace -f -

# 7. Final output -------------------------------------------------------------
Write-Color "`nCluster deployed!"
$svc = kubectl -n $Namespace get svc haproxy -o=jsonpath='{.spec.clusterIP}' 2>$null
Write-Color "HAProxy Service: $svc:3306"
Write-Color "root password: $RootPass" Yellow
Write-Color "Watch pods : kubectl get pods -n $Namespace -w"
Write-Color "Access svc : minikube service haproxy -n $Namespace"
Write-Color "Delete     : kubectl delete ns $Namespace"
3 Step-by-Step Explanation
Stage	Script section	What happens	Why it matters
Prerequisite check	Check-Command / Minikube status	Ensures kubectl & minikube exist and the cluster is running.	Prevents cryptic failures later.
Namespace creation	kubectl create ns ...	Makes an isolated Kubernetes namespace.	Keeps resources contained and easy to delete.
Operator install	Apply bundle.yaml	Installs CRDs, RBAC, and operator Deployment.	Operator will reconcile PerconaXtraDBCluster objects.
Wait for operator	Loop until availableReplicas ≥ 1	Confirms operator pod is healthy before proceeding.	Eliminates race conditions.
Secret generation	Random 16-char root password	Populates my-db-secrets for PXC root and users.	Avoids hard-coding credentials.
Cluster CR apply	`$ClusterYaml	kubectl apply`	Defines PXC cluster: 1 pod, HAProxy, small resources, no anti-affinity.
Pod readiness loop	Count Running pxc pods up to $InitialSize	Waits max ~5 min for pods to initialise.	Gives user clear progress feedback.
metrics-server addon	minikube addons enable	Provides CPU metrics so HPA functions.	Without it HPA remains Unknown.
Create HPA	Applies autoscaling object	Scales PXC replicas 1-3 at 60% CPU.	Demonstrates database-aware scaling.
Final output	Prints service IP and password	Tells user exactly how to connect.	Smooth first-time experience.
Customisation Pointers
Larger clusters
Remove unsafeFlags.pxcSize: true and set size: 3, haproxy.size: 2 for production-like HA.

Resource limits
Tune under resources: if your workstation has more/less memory.

Storage class
Change the PVC storageClassName (or add the field) to use cloud disks instead of Minikube hostpath.

Images
Pin specific tags for both PXC and HAProxy to guarantee reproducibility.

Load testing
Use mysqlslap or siege inside a busybox pod to drive CPU and watch HPA scaling.

Final Checks
Pods Ready – kubectl -n mysql-cluster get pods

HPA status – kubectl -n mysql-cluster get hpa

Service IP – kubectl -n mysql-cluster get svc haproxy

Once these look healthy, your single-node Percona XtraDB Cluster on Minikube is fully operational.
