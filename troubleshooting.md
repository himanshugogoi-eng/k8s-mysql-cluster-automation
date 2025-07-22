# Troubleshooting MySQL on Kubernetes

## Common Issues

### 1. MySQL pod fails to start
Check logs:
```bash
kubectl logs mysql-0
```

### 2. Can't connect via socket
Use TCP:
```bash
mysql -uroot -p -h 127.0.0.1
```

### 3. CrashLoopBackOff
- Check volume permissions
- Check config syntax in ConfigMap

### 4. Update ConfigMap

Make edits:
```bash
kubectl edit configmap mysql-config
```

Then restart pods:
```bash
kubectl delete pod mysql-0
```
