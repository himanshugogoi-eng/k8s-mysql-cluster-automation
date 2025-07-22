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

