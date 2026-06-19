# AWS EKS Migration Plan

> **Roadmap for migrating home-lab from EC2 to Amazon EKS**

This document describes the future migration from EC2-based deployment to Amazon Elastic 
Kubernetes Service (EKS). This is a **long-term plan** — not required for initial AWS deployment.

**Prerequisites:** Home-lab deployed on EC2 per [../cloud/aws-ec2-deployment.md](../cloud/aws-ec2-deployment.md)

---

## Table of Contents

- [Why Migrate to EKS](#why-migrate-to-eks)
- [When to Migrate](#when-to-migrate)
- [Architecture Changes](#architecture-changes)
- [Migration Strategy](#migration-strategy)
- [EKS Cluster Setup](#eks-cluster-setup)
- [Workload Migration](#workload-migration)
- [OpenShell on Kubernetes](#openshell-on-kubernetes)
- [Storage Strategy](#storage-strategy)
- [Networking](#networking)
- [Cost Analysis](#cost-analysis)
- [Migration Phases](#migration-phases)
- [Rollback Plan](#rollback-plan)

---

## Why Migrate to EKS

### Benefits

| Benefit | Description |
|---|---|
| **Multi-node HA** | Workloads survive node failures |
| **Auto-scaling** | Scale pods/nodes based on load |
| **GPU nodes** | Add GPU-enabled nodes for vLLM (local inference) |
| **Managed control plane** | AWS handles k8s control plane upgrades |
| **Better resource isolation** | Pods have clear resource limits/requests |
| **GitOps-ready** | FluxCD/ArgoCD for declarative infra |
| **Load balancing** | Native ALB/NLB integration |
| **Pod security** | Network policies, PSPs, admission controllers |

### Drawbacks

| Drawback | Impact |
|---|---|
| **Cost** | $75/mo control plane + $80-200/mo nodes = $155-275/mo minimum |
| **Complexity** | Requires k8s expertise (manifests, controllers, operators) |
| **OpenShell compatibility** | Needs testing; may require privileged pods |
| **Migration effort** | Docker Compose → Deployment/StatefulSet/ConfigMap/Secret |
| **Debugging overhead** | More layers (pods, services, ingress vs. Docker bridge) |

---

## When to Migrate

### Migrate When:

✅ **You need multi-node capacity** — Single EC2 instance is insufficient  
✅ **You want HA** — Workloads must survive node failures  
✅ **You're adding GPU nodes** — For vLLM local inference  
✅ **You need auto-scaling** — Load varies and you want cost optimization  
✅ **You're comfortable with k8s** — You understand manifests, kubectl, troubleshooting  
✅ **Budget allows $200+/month** — EKS is expensive

### Don't Migrate If:

❌ Single EC2 node is sufficient  
❌ Budget-constrained (stay on EC2 or k3s)  
❌ Don't need HA (single user, not production)  
❌ Want simplicity (Docker Compose is easier)  
❌ OpenShell compatibility unclear (needs validation first)

### Recommendation

**Intermediate step:** Add a second EC2 node with k3s before migrating to EKS.

```
Current (Phase 1): EC2 single node → Docker Compose
Intermediate (Phase 2): EC2 + k3s (2+ nodes) → k8s manifests
Final (Phase 3): EKS → managed k8s
```

This validates k8s manifests and OpenShell-on-k8s without EKS cost/complexity.

---

## Architecture Changes

### Current Architecture (EC2 + Docker Compose)

```
EC2 Instance
  ├── Docker Engine
  │     ├── ai-net (bridge network)
  │     ├── Traefik (labels → routes)
  │     ├── LiteLLM (env vars from .secrets/)
  │     ├── Portainer, Registry
  │     └── OpenShell sandboxes (sibling containers)
  └── OpenShell Gateway (systemd --user)
        inference.local → LiteLLM
```

### Target Architecture (EKS)

```
EKS Cluster
  ├── Control Plane (managed by AWS)
  └── Worker Nodes
        ├── System Namespace
        │     ├── ALB Ingress Controller
        │     ├── EBS CSI Driver
        │     ├── CoreDNS
        │     └── kube-proxy
        ├── homelab Namespace
        │     ├── Traefik (Ingress/Service)
        │     ├── LiteLLM (Deployment + Secret)
        │     ├── Portainer (Deployment + PVC)
        │     ├── Registry (StatefulSet + PVC)
        │     └── OpenShell Gateway (DaemonSet?)
        └── openshell Namespace
              ├── Claude wrapper (Pod + Service)
              ├── Grok wrapper (Pod + Service)
              └── NemoClaw director (Pod + Service)
```

---

## Migration Strategy

### Approach: Gradual Migration

**Phase 1: Validate on k3s (EC2)**
- Install k3s on existing EC2 instance
- Convert Docker Compose → k8s manifests
- Test OpenShell on k3s
- Validate wrappers, LiteLLM, OpenClaw

**Phase 2: Add Second Node (EC2 + k3s)**
- Launch second EC2 instance (optional GPU)
- Join k3s cluster
- Distribute workloads
- Test HA failover

**Phase 3: Create EKS Cluster**
- Provision EKS cluster (1-2 node groups)
- Deploy manifests from Phase 1
- Migrate DNS (point to ALB)
- Run parallel for 1 week

**Phase 4: Cutover**
- Switch DNS fully to EKS
- Decommission EC2 instances
- Monitor costs/performance

### Alternative: Direct EC2 → EKS

Skip k3s, go straight to EKS. **Only if:**
- You're very confident in k8s
- Budget allows parallel environments (EC2 + EKS running simultaneously)
- You've validated OpenShell on k8s elsewhere

---

## EKS Cluster Setup

### Prerequisites

- AWS CLI configured
- `kubectl` installed
- `eksctl` installed: `brew install eksctl` or download from GitHub

### Create Cluster with eksctl

```bash
# cluster-config.yaml
cat > cluster-config.yaml << 'EOF'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: homelab
  region: us-east-1
  version: "1.31"

vpc:
  cidr: 10.1.0.0/16
  nat:
    gateway: Single  # Cheaper than HighlyAvailable

iam:
  withOIDC: true

managedNodeGroups:
  - name: general
    instanceType: t3.xlarge
    desiredCapacity: 2
    minSize: 1
    maxSize: 3
    volumeSize: 100
    volumeType: gp3
    ssh:
      allow: true
      publicKeyName: homelab-key
    iam:
      withAddonPolicies:
        autoScaler: true
        ebs: true
        albIngress: true
    labels:
      role: general
    tags:
      nodegroup-role: general
  
  # GPU node group (optional, Phase 4+)
  # - name: gpu
  #   instanceType: g4dn.xlarge
  #   desiredCapacity: 1
  #   minSize: 0
  #   maxSize: 2
  #   volumeSize: 200
  #   ssh:
  #     allow: true
  #   labels:
  #     role: gpu
  #     nvidia.com/gpu: "true"
  #   taints:
  #     - key: nvidia.com/gpu
  #       value: "true"
  #       effect: NoSchedule

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
    serviceAccountRoleARN: arn:aws:iam::<account-id>:role/AmazonEKS_EBS_CSI_DriverRole
EOF

# Create cluster (takes ~15 minutes)
eksctl create cluster -f cluster-config.yaml
```

### Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name homelab

# Verify
kubectl get nodes
kubectl get pods -A
```

### Install Add-ons

**AWS Load Balancer Controller (for Ingress):**

```bash
# Create IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# Create service account
eksctl create iamserviceaccount \
  --cluster=homelab \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::<account-id>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install controller via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=homelab \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

**EBS CSI Driver (for persistent volumes):**

```bash
# Create IAM role
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster homelab \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

# Enable addon
eksctl create addon --name aws-ebs-csi-driver --cluster homelab --force
```

---

## Workload Migration

### 1. Convert Docker Compose → Kubernetes Manifests

#### Example: LiteLLM Deployment

**Current (Docker Compose):**
```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    container_name: litellm
    restart: unless-stopped
    ports:
      - "4000:4000"
    env_file:
      - ../.secrets/bedrock.env
      - ../.secrets/litellm.env
      - litellm.env
    volumes:
      - ./litellm/config.yaml:/app/config.yaml:ro
    networks:
      - ai-net
```

**Target (Kubernetes):**

```yaml
# litellm-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: litellm-secrets
  namespace: homelab
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: <base64-encoded>
  AWS_SECRET_ACCESS_KEY: <base64-encoded>
  AWS_REGION: us-east-1
  LITELLM_MASTER_KEY: <base64-encoded>
---
# litellm-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: homelab
data:
  config.yaml: |
    # Paste litellm/config.yaml contents here
---
# litellm-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: homelab
spec:
  replicas: 2  # HA!
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main-latest
        ports:
        - containerPort: 4000
        envFrom:
        - secretRef:
            name: litellm-secrets
        volumeMounts:
        - name: config
          mountPath: /app/config.yaml
          subPath: config.yaml
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
      volumes:
      - name: config
        configMap:
          name: litellm-config
---
# litellm-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: homelab
spec:
  selector:
    app: litellm
  ports:
  - port: 4000
    targetPort: 4000
  type: ClusterIP
```

**Apply:**
```bash
kubectl create namespace homelab
kubectl apply -f litellm-secret.yaml
kubectl apply -f litellm-configmap.yaml
kubectl apply -f litellm-deployment.yaml
kubectl apply -f litellm-service.yaml
```

#### Example: Traefik Ingress

**Current:** Traefik discovers via Docker labels

**Target:** Traefik as Ingress Controller with Ingress resources

```yaml
# traefik-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: homelab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik
      containers:
      - name: traefik
        image: traefik:v3.1
        ports:
        - name: web
          containerPort: 80
        - name: websecure
          containerPort: 443
        args:
        - --entrypoints.web.address=:80
        - --entrypoints.websecure.address=:443
        - --providers.kubernetescrd
        - --certificatesresolvers.letsencrypt.acme.email=your@email.com
        - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
        - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
        volumeMounts:
        - name: letsencrypt
          mountPath: /letsencrypt
      volumes:
      - name: letsencrypt
        persistentVolumeClaim:
          claimName: traefik-letsencrypt
---
# traefik-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: homelab
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  selector:
    app: traefik
  ports:
  - name: web
    port: 80
    targetPort: 80
  - name: websecure
    port: 443
    targetPort: 443
---
# openclaw-ingress.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: openclaw
  namespace: homelab
spec:
  entryPoints:
  - websecure
  routes:
  - match: Host(`openclaw.yourdomain.com`)
    kind: Rule
    services:
    - name: openclaw
      port: 18789
  tls:
    certResolver: letsencrypt
```

### 2. Persistent Storage

**Registry (needs persistence):**

```yaml
# registry-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: homelab
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
---
# registry-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: registry
  namespace: homelab
spec:
  serviceName: registry
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: gp3
      resources:
        requests:
          storage: 50Gi
```

---

## OpenShell on Kubernetes

### Challenge

OpenShell spawns sibling Docker containers. On k8s, this requires:
1. **Docker socket access** — Mount `/var/run/docker.sock` (or use containerd socket)
2. **Privileged pods** — Needed for network namespace manipulation
3. **Host network** — Or custom CNI integration

### Option A: Privileged DaemonSet

Run OpenShell gateway as a DaemonSet (one per node):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: openshell-gateway
  namespace: openshell
spec:
  selector:
    matchLabels:
      app: openshell-gateway
  template:
    metadata:
      labels:
        app: openshell-gateway
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: gateway
        image: <custom-openshell-gateway-image>
        securityContext:
          privileged: true
        volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
        - name: openshell-data
          mountPath: /var/lib/openshell
      volumes:
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
      - name: openshell-data
        hostPath:
          path: /var/lib/openshell
```

**Pros:** Works similarly to EC2 setup  
**Cons:** Requires privileged pods (security concern), host network

### Option B: containerd Integration

EKS uses containerd, not Docker. OpenShell may support containerd runtime:

```yaml
# Check OpenShell docs for containerd support
# If supported, mount containerd socket instead
volumeMounts:
- name: containerd-sock
  mountPath: /run/containerd/containerd.sock
```

### Option C: Run OpenShell Outside k8s

Hybrid approach:
- EKS cluster for services (LiteLLM, Traefik, OpenClaw)
- Separate EC2 instances for OpenShell sandboxes
- Services call OpenShell gateway over network

**Pros:** No privileged pods, simpler k8s  
**Cons:** Defeats purpose of consolidation

### Recommendation

**Test Option A (privileged DaemonSet) first.** If security policy disallows, use Option C (hybrid).

---

## Storage Strategy

### Storage Classes

EKS supports:
- `gp3` (default) — General Purpose SSD
- `io2` — High IOPS SSD
- `st1` — Throughput Optimized HDD
- EFS — Shared filesystem (ReadWriteMany)

**Use gp3 for most workloads.**

### Persistent Volume Claims

| Workload | Storage Type | Access Mode | Size |
|---|---|---|---|
| Registry | gp3 | RWO | 50 GB |
| Portainer data | gp3 | RWO | 10 GB |
| LiteLLM logs | gp3 (optional) | RWO | 20 GB |
| OpenClaw sessions | gp3 | RWO | 50 GB |
| Traefik certs | gp3 | RWO | 1 GB |

### Backup Strategy

**EBS snapshots:**
- Automated via AWS Backup
- Or use Velero (k8s-native backup)

```bash
# Install Velero
velero install \
  --provider aws \
  --bucket homelab-velero-backups \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1

# Schedule daily backups
velero schedule create daily --schedule="0 2 * * *"
```

---

## Networking

### Service Mesh (Optional)

For observability and mTLS between services:

**Istio or Linkerd:**
```bash
# Istio
istioctl install --set profile=default

# Linkerd (lighter)
linkerd install | kubectl apply -f -
```

**Use only if:** You need advanced traffic management, circuit breaking, or mTLS.

### Network Policies

Restrict traffic between namespaces:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-litellm-to-wrappers
  namespace: openshell
spec:
  podSelector:
    matchLabels:
      app: claude-wrapper
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: homelab
      podSelector:
        matchLabels:
          app: litellm
```

### DNS

Internal DNS: `<service>.<namespace>.svc.cluster.local`

Example: `litellm.homelab.svc.cluster.local:4000`

---

## Cost Analysis

### EKS Monthly Cost (2-node t3.xlarge)

| Component | Cost |
|---|---|
| **EKS control plane** | $73 |
| **EC2 nodes (2x t3.xlarge)** | $240 |
| **EBS volumes (200GB total)** | $16 |
| **ALB (for Ingress)** | $16 |
| **Data transfer** | $10-20 |
| **Total** | **~$355-365/month** |

### Annual Cost

~$4,260-4,380 per year

### Comparison

| Platform | Monthly | Annual |
|---|---|---|
| EC2 single node | $135 | $1,620 |
| EC2 + k3s (2 nodes) | $240 | $2,880 |
| **EKS (2 nodes)** | **$355** | **$4,260** |

**EKS is 2.6x more expensive than EC2 single node.**

### Cost Optimization

1. **Fargate for stateless workloads** — Pay per-pod (no node costs)
2. **Spot instances** — 70% discount (risky for persistent workloads)
3. **Savings Plans** — 30-50% off with commitment
4. **Right-size nodes** — Use t3.large if sufficient
5. **Auto-scaling** — Scale down off-hours

---

## Migration Phases

### Phase 0: Pre-Migration (Current State)

- [x] EC2 instance with Docker Compose
- [x] All services running and tested
- [x] Documentation complete

### Phase 1: k3s Validation (1-2 weeks)

- [ ] Install k3s on existing EC2 instance
- [ ] Convert all Docker Compose services → k8s manifests
- [ ] Test OpenShell on k3s (privileged DaemonSet)
- [ ] Test wrapper pods
- [ ] Test OpenClaw
- [ ] Document findings

### Phase 2: Add Second Node (1 week)

- [ ] Launch second EC2 instance
- [ ] Join k3s cluster
- [ ] Distribute workloads across nodes
- [ ] Test HA failover (drain node, verify workload migration)

### Phase 3: EKS Cluster Creation (1 day)

- [ ] Provision EKS cluster with eksctl
- [ ] Install ALB controller, EBS CSI driver
- [ ] Deploy all manifests from Phase 1
- [ ] Verify all pods running

### Phase 4: DNS Cutover (1 week parallel run)

- [ ] Point DNS to EKS ALB
- [ ] Run EC2 + EKS in parallel for 1 week
- [ ] Monitor costs, performance, errors
- [ ] Validate OpenClaw sessions work on EKS

### Phase 5: Decommission EC2 (Final)

- [ ] Stop EC2 instances
- [ ] Wait 1 week (rollback window)
- [ ] Terminate EC2 instances
- [ ] Delete unused resources (EBS volumes, Elastic IPs)
- [ ] Update documentation

---

## Rollback Plan

### If Migration Fails

**Before DNS cutover:**
- Simply revert k8s changes
- Continue on EC2

**After DNS cutover (within rollback window):**
1. Point DNS back to EC2 Elastic IP
2. Restart Docker Compose services on EC2
3. Verify all services operational
4. Keep EKS cluster running for 1 week (for forensics)
5. Terminate EKS cluster

### Rollback Triggers

- OpenShell doesn't work on EKS
- Costs exceed budget (>$400/mo)
- Performance degrades significantly
- >3 critical outages in first week

---

## Summary

### Migration Decision Tree

```
Do you need HA or multi-node?
  ├─ No → Stay on EC2
  └─ Yes
      ├─ Budget < $250/mo → Use k3s on EC2
      └─ Budget > $300/mo
          ├─ Comfortable with k8s → Migrate to EKS
          └─ Not comfortable → Learn k3s first, then EKS
```

### Recommended Path

1. **Stay on EC2** until you outgrow single node
2. **Add k3s** when you need 2+ nodes (validate k8s manifests)
3. **Migrate to EKS** when you need managed control plane or >3 nodes

### EKS Checklist

- [ ] Validate OpenShell on k8s (privileged pods)
- [ ] Convert all Docker Compose → manifests
- [ ] Test on k3s before EKS
- [ ] Budget approved ($355/mo)
- [ ] Team comfortable with k8s troubleshooting
- [ ] Backup/restore strategy in place
- [ ] Monitoring/alerting configured
- [ ] Rollback plan documented

**Do not migrate to EKS prematurely.** EC2 → k3s → EKS is the safer path.

---

## References

- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [eksctl Documentation](https://eksctl.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [OpenShell Kubernetes Integration](https://github.com/NVIDIA/OpenShell) — Check for k8s support
- [k3s Documentation](https://k3s.io/) — Lightweight k8s for learning/testing
