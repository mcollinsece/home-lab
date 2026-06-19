# AWS EC2 Provisioning Guide

> **Infrastructure setup for running home-lab on AWS EC2**

This document covers provisioning an EC2 instance and supporting infrastructure to run the 
entire home-lab stack (OpenShell, NemoClaw, LiteLLM, agent wrappers) on AWS.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [AMI Selection](#ami-selection)
- [Instance Specifications](#instance-specifications)
- [VPC and Networking](#vpc-and-networking)
- [Security Groups](#security-groups)
- [Storage (EBS)](#storage-ebs)
- [IAM Roles](#iam-roles)
- [DNS Strategy](#dns-strategy)
- [Provisioning Commands](#provisioning-commands)
- [Cost Estimate](#cost-estimate)
- [Post-Provisioning Checklist](#post-provisioning-checklist)

---

## Overview

### What You're Building

```
AWS Account
  └── VPC (10.0.0.0/16)
       ├── Public Subnet (10.0.1.0/24)
       │     └── EC2 Instance (home-lab)
       │           ├── Docker Engine
       │           ├── OpenShell gateway
       │           ├── NemoClaw director
       │           ├── LiteLLM proxy
       │           └── Agent wrappers
       ├── Elastic IP (public access)
       ├── Security Groups (firewall rules)
       └── EBS Volume (persistent storage)
```

### Key Differences from Proxmox Setup

| Aspect | Proxmox (Current) | AWS EC2 |
|---|---|---|
| **Networking** | AdGuard DNS + `*.lab.lan` | Route53 or Cloudflare Tunnel |
| **TLS Certs** | mkcert local CA | Let's Encrypt or ACM |
| **Firewall** | Proxmox firewall | Security Groups |
| **Persistence** | VM disk | EBS volumes |
| **Backups** | Proxmox snapshots | EBS snapshots + AMI |
| **IP Address** | Static LAN IP | Elastic IP |

---

## Prerequisites

### AWS Account Setup

- [ ] AWS account with billing enabled
- [ ] AWS CLI installed locally: `aws --version`
- [ ] AWS credentials configured: `aws configure`
- [ ] Default region set (recommend `us-east-1` for Bedrock compatibility)

```bash
# Install AWS CLI (if needed)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Configure credentials
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: us-east-1
# Default output format: json
```

### Local Tools

- [ ] SSH client
- [ ] `jq` for JSON parsing
- [ ] `git` for repository access

---

## AMI Selection

### Recommended: Debian 13 (Bookworm)

**Why Debian:**
- Matches current Proxmox VM (Debian 13)
- `setup-host.sh` tested on Debian
- Stable, minimal base

**Finding the AMI:**

```bash
# Find latest Debian 13 AMI in your region
aws ec2 describe-images \
  --owners 136693071363 \
  --filters "Name=name,Values=debian-13-*" \
            "Name=architecture,Values=x86_64" \
            "Name=root-device-type,Values=ebs" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].[ImageId,Name,CreationDate]' \
  --output table

# Example output:
# ami-0abcdef1234567890 | debian-13-amd64-20260501-1234 | 2026-05-01T00:00:00.000Z
```

**Store AMI ID:**
```bash
DEBIAN_AMI="ami-0abcdef1234567890"  # Replace with actual AMI from above
```

### Alternative: Ubuntu 24.04 LTS

**Why Ubuntu:**
- Longer LTS support (2029 vs Debian's rolling)
- Larger community
- AWS-optimized images available

**Finding the AMI:**

```bash
# Find latest Ubuntu 24.04 LTS AMI
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-*" \
            "Name=architecture,Values=x86_64" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].[ImageId,Name,CreationDate]' \
  --output table

UBUNTU_AMI="ami-0xyz987654321"  # Replace with actual AMI
```

**Choose ONE:**
- Use Debian if you want exact match to current setup
- Use Ubuntu if you prefer LTS stability

For this guide, we'll use **Debian 13**.

---

## Instance Specifications

### Recommended: `t3.xlarge`

| Spec | Value | Notes |
|---|---|---|
| **Instance Type** | `t3.xlarge` | 4 vCPU, 16 GB RAM |
| **Architecture** | x86_64 | Required for OpenShell binaries |
| **vCPUs** | 4 | Recommended minimum for multi-agent |
| **RAM** | 16 GB | Comfortable for NemoClaw + 2-3 wrappers |
| **Network** | Up to 5 Gbps | More than sufficient |
| **Cost** | ~$0.1664/hr | ~$120/month (730 hrs) |

### Alternative Options

| Instance Type | vCPU | RAM | Cost/Month | Use Case |
|---|---|---|---|---|
| **t3.large** | 2 | 8 GB | ~$60 | Budget option, fewer concurrent agents |
| **t3.xlarge** | 4 | 16 GB | ~$120 | **Recommended** — matches current setup |
| **t3.2xlarge** | 8 | 32 GB | ~$240 | Heavy multi-agent workloads |
| **c7i.xlarge** | 4 | 8 GB | ~$140 | Compute-optimized (if CPU-bound) |

**Recommendation:** Start with `t3.xlarge`. You can resize later without data loss.

### CPU Credits (T3 Burstable Instances)

T3 instances use CPU credits:
- **Baseline:** 40% CPU utilization per vCPU continuously
- **Burst:** Use credits for higher CPU when needed
- **Unlimited mode:** Auto-enabled, pay extra if credits exhausted

For home-lab (mostly idle), baseline is sufficient. If you hit limits, enable unlimited mode:
```bash
aws ec2 modify-instance-credit-specification \
  --instance-id i-1234567890abcdef0 \
  --cpu-credits unlimited
```

---

## VPC and Networking

### Option A: Use Default VPC (Simplest)

AWS provides a default VPC in every region. Use this unless you need custom networking.

**Verify default VPC exists:**
```bash
aws ec2 describe-vpcs --filters "Name=is-default,Values=true"
```

**Get default subnet:**
```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters 'Name=is-default,Values=true' --query 'Vpcs[0].VpcId' --output text)" \
  --query 'Subnets[0].SubnetId' \
  --output text
```

Store for later:
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
```

### Option B: Create Custom VPC (More Control)

Create isolated VPC for home-lab:

```bash
# Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=homelab-vpc}]' \
  --query 'Vpc.VpcId' \
  --output text)

# Enable DNS
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=homelab-igw}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Create Public Subnet
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=homelab-public}]' \
  --query 'Subnet.SubnetId' \
  --output text)

# Create Route Table
RTB_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=homelab-public-rt}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Add Internet route
aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Associate route table with subnet
aws ec2 associate-route-table --subnet-id $SUBNET_ID --route-table-id $RTB_ID
```

---

## Security Groups

### Create Security Group

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name homelab-sg \
  --description "Security group for home-lab instance" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

aws ec2 create-tags --resources $SG_ID --tags Key=Name,Value=homelab-sg
```

### Ingress Rules

```bash
# SSH from your IP only (REPLACE WITH YOUR IP)
YOUR_IP="1.2.3.4/32"  # Get via: curl ifconfig.me

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr $YOUR_IP

# HTTP (for Let's Encrypt verification / public access)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# HTTPS (Traefik / public services)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0
```

**Security note:** If using Cloudflare Tunnel instead of public HTTPS, you can skip ports 80/443 and only allow SSH.

### Egress Rules

Default allows all outbound. If you want to restrict:

```bash
# Remove default allow-all egress
aws ec2 revoke-security-group-egress \
  --group-id $SG_ID \
  --protocol -1 \
  --cidr 0.0.0.0/0

# Add specific egress rules
# HTTPS for package downloads, API calls
aws ec2 authorize-security-group-egress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0

# HTTP for package downloads
aws ec2 authorize-security-group-egress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# DNS
aws ec2 authorize-security-group-egress \
  --group-id $SG_ID \
  --protocol udp \
  --port 53 \
  --cidr 0.0.0.0/0
```

For simplicity, keep default allow-all egress.

---

## Storage (EBS)

### Root Volume

Created automatically with instance. Recommendations:
- **Size:** 100 GB (matches current setup; resized from initial 8GB)
- **Type:** `gp3` (General Purpose SSD v3 — cheaper than gp2, same performance)
- **IOPS:** 3000 (default for gp3)
- **Throughput:** 125 MB/s (default for gp3)

Cost: ~$8/month for 100GB gp3

### Optional: Separate Data Volume

If you want to separate OS from data (recommended for backups):

```bash
# Create 100GB data volume
DATA_VOLUME_ID=$(aws ec2 create-volume \
  --availability-zone us-east-1a \
  --size 100 \
  --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=homelab-data}]' \
  --query 'VolumeId' \
  --output text)

# Attach to instance (after instance is created)
aws ec2 attach-volume \
  --volume-id $DATA_VOLUME_ID \
  --instance-id $INSTANCE_ID \
  --device /dev/sdf
```

Then mount inside instance:
```bash
# Inside EC2 instance
sudo mkfs.ext4 /dev/nvme1n1  # Device name may vary
sudo mkdir -p /data
sudo mount /dev/nvme1n1 /data
echo '/dev/nvme1n1  /data  ext4  defaults,nofail  0  2' | sudo tee -a /etc/fstab
```

For simplicity, **use single root volume** (100GB is plenty).

---

## IAM Roles

### Create IAM Role for EC2 (Optional but Recommended)

Allows instance to interact with AWS services without hardcoded credentials.

**Use cases:**
- CloudWatch Logs for centralized logging
- Systems Manager (SSM) for remote access without SSH
- ECR for pulling private Docker images (future)
- S3 for backups (future)

```bash
# Create trust policy for EC2
cat > ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
  --role-name homelab-ec2-role \
  --assume-role-policy-document file://ec2-trust-policy.json

# Attach managed policies
aws iam attach-role-policy \
  --role-name homelab-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

aws iam attach-role-policy \
  --role-name homelab-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create instance profile
aws iam create-instance-profile --instance-profile-name homelab-ec2-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name homelab-ec2-profile \
  --role-name homelab-ec2-role
```

Attach when launching instance (see Provisioning Commands).

### Bedrock via the instance role (recommended — no static keys)

LiteLLM can call Bedrock using the EC2 instance role via IMDS, so no AWS access
keys ever touch the box. Add Bedrock invoke permissions to the role:

```bash
cat > bedrock-invoke.json << 'EOF'
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": "*" } ] }
EOF
aws iam put-role-policy --role-name homelab-ec2-role \
  --policy-name bedrock-invoke --policy-document file://bedrock-invoke.json
```

Then run `init-secrets.sh --instance-role` (or `deploy-ec2.sh`, which does this by
default): it writes a **region-only** `.secrets/bedrock.env` and LiteLLM picks up
role credentials from IMDS.

> **Two hard requirements** for the *container* to use Bedrock — both cost real
> debugging time on the first deploy:

#### 1. IMDS hop limit must be ≥ 2

The LiteLLM container reaches IMDS through the Docker bridge, which adds a network
hop. The default `HttpPutResponseHopLimit=1` lets a *host* GET succeed but **drops
the IMDSv2 token PUT response to containers**, so boto3 can't get role creds.
Symptom: a container GET to `169.254.169.254/latest/meta-data/` returns `401` fast,
but the IMDSv2 token PUT returns empty. Fix at launch or after:

```bash
# At launch: --metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2"
aws ec2 modify-instance-metadata-options \
  --instance-id <id> --http-put-response-hop-limit 2 --http-tokens required
```

#### 2. bedrock-runtime VPC endpoint security group must allow 443

If the VPC uses a **PrivateLink interface endpoint** for `bedrock-runtime`
(its name resolves to private `10.x` IPs), that endpoint's **own** security group
must allow inbound **TCP 443 from the instance** (source = the instance's SG, or
the subnet/VPC CIDR). Symptom: control-plane calls (`sts`, `bedrock`) work, but
`bedrock-runtime` TCP 443 **hangs / never connects** and `InvokeModel` times out.
Editing the *instance* SG does nothing — it's the *endpoint* SG that gates this.

```bash
# verify from the instance once fixed (instant connect = good):
curl -s -o /dev/null -w '%{time_connect}s %{http_code}\n' \
  https://bedrock-runtime.us-east-1.amazonaws.com/   # 404 fast = reachable
```

If you'd rather not use the instance role, run `init-secrets.sh` (no flag) and
provide a scoped IAM user's keys instead.

---

## DNS Strategy

### Option A: Cloudflare Tunnel (Recommended for Start)

**Pros:**
- Free
- No public IP exposure (except SSH)
- No DNS management needed
- Works with existing `*.lab.lan` setup

**Setup:**
```bash
# Inside EC2 instance (after deployment)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
sudo mv cloudflared /usr/local/bin/
sudo chmod +x /usr/local/bin/cloudflared

# Authenticate
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create homelab

# Route DNS
cloudflared tunnel route dns homelab openclaw.yourdomain.com

# Run tunnel (via systemd)
sudo cloudflared service install
```

Traefik services will be accessible at `openclaw.yourdomain.com`, `litellm.yourdomain.com`, etc.

### Option B: Route53 Public Hosted Zone

**Pros:**
- Full DNS control
- Integrates with ACM for TLS certs
- No third-party dependency

**Cons:**
- Costs $0.50/month per hosted zone
- Requires owning a domain
- Exposes services publicly (need auth)

**Setup:**

```bash
# Register domain (if needed)
# Via AWS Route53 console or your registrar

# Create hosted zone
DOMAIN="yourname.com"
HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name $DOMAIN \
  --caller-reference $(date +%s) \
  --query 'HostedZone.Id' \
  --output text)

# After instance has Elastic IP, create A records
ELASTIC_IP="<your-elastic-ip>"

# Wildcard record for all services
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "*.'$DOMAIN'",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "'$ELASTIC_IP'"}]
      }
    }]
  }'
```

**Recommendation:** Start with Cloudflare Tunnel (simpler), migrate to Route53 later if needed.

---

## Provisioning Commands

### Full Provisioning Script

```bash
#!/bin/bash
# provision-ec2.sh - Provision EC2 instance for home-lab

set -euo pipefail

echo "==> Provisioning home-lab EC2 instance..."

# ── Configuration ─────────────────────────────────────────────────
REGION="us-east-1"
INSTANCE_TYPE="t3.xlarge"
VOLUME_SIZE=100
KEY_NAME="homelab-key"  # SSH key pair name
YOUR_IP="$(curl -s ifconfig.me)/32"  # Your public IP for SSH access

# ── Find Debian 13 AMI ────────────────────────────────────────────
echo "==> Finding latest Debian 13 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region $REGION \
  --owners 136693071363 \
  --filters "Name=name,Values=debian-13-amd64-*" \
            "Name=architecture,Values=x86_64" \
            "Name=root-device-type,Values=ebs" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

echo "    Using AMI: $AMI_ID"

# ── Get Default VPC ───────────────────────────────────────────────
echo "==> Using default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[0].SubnetId' \
  --output text)

echo "    VPC: $VPC_ID"
echo "    Subnet: $SUBNET_ID"

# ── Create Security Group ─────────────────────────────────────────
echo "==> Creating security group..."
SG_ID=$(aws ec2 create-security-group \
  --region $REGION \
  --group-name homelab-sg \
  --description "Security group for home-lab instance" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text 2>/dev/null || \
  aws ec2 describe-security-groups \
    --region $REGION \
    --filters "Name=group-name,Values=homelab-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

echo "    Security Group: $SG_ID"

# Add rules (skip if already exist)
aws ec2 authorize-security-group-ingress \
  --region $REGION \
  --group-id $SG_ID \
  --protocol tcp --port 22 --cidr $YOUR_IP 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region $REGION \
  --group-id $SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region $REGION \
  --group-id $SG_ID \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

# ── Create/Import SSH Key ─────────────────────────────────────────
if ! aws ec2 describe-key-pairs --region $REGION --key-names $KEY_NAME &>/dev/null; then
  echo "==> Creating SSH key pair..."
  aws ec2 create-key-pair \
    --region $REGION \
    --key-name $KEY_NAME \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/${KEY_NAME}.pem
  chmod 600 ~/.ssh/${KEY_NAME}.pem
  echo "    Key saved to: ~/.ssh/${KEY_NAME}.pem"
else
  echo "==> SSH key pair already exists: $KEY_NAME"
fi

# ── Launch Instance ───────────────────────────────────────────────
echo "==> Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region $REGION \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=homelab}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "    Instance ID: $INSTANCE_ID"
echo "==> Waiting for instance to be running..."
aws ec2 wait instance-running --region $REGION --instance-ids $INSTANCE_ID

# ── Allocate and Associate Elastic IP ─────────────────────────────
echo "==> Allocating Elastic IP..."
ALLOCATION_ID=$(aws ec2 allocate-address \
  --region $REGION \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=homelab-eip}]' \
  --query 'AllocationId' \
  --output text)

aws ec2 associate-address \
  --region $REGION \
  --instance-id $INSTANCE_ID \
  --allocation-id $ALLOCATION_ID

ELASTIC_IP=$(aws ec2 describe-addresses \
  --region $REGION \
  --allocation-ids $ALLOCATION_ID \
  --query 'Addresses[0].PublicIp' \
  --output text)

echo "    Elastic IP: $ELASTIC_IP"

# ── Wait for SSH ──────────────────────────────────────────────────
echo "==> Waiting for SSH to be ready..."
sleep 30  # Give instance time to initialize

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "==> Provisioning complete!"
echo ""
echo "Instance ID:  $INSTANCE_ID"
echo "Elastic IP:   $ELASTIC_IP"
echo "SSH Key:      ~/.ssh/${KEY_NAME}.pem"
echo ""
echo "Connect with:"
echo "  ssh -i ~/.ssh/${KEY_NAME}.pem admin@${ELASTIC_IP}"
echo ""
echo "Next steps:"
echo "  1. SSH to instance"
echo "  2. Follow docs/cloud/aws-ec2-deployment.md"
```

**Run it:**
```bash
chmod +x provision-ec2.sh
./provision-ec2.sh
```

---

## Cost Estimate

### Monthly Costs (t3.xlarge)

| Service | Cost | Notes |
|---|---|---|
| **EC2 instance** | $120.85 | t3.xlarge, 730 hrs/month |
| **EBS storage** | $8.00 | 100 GB gp3 |
| **Elastic IP** | $0.00 | Free when attached |
| **Data transfer** | $5-10 | First 100GB/month free, then $0.09/GB |
| **Route53** (optional) | $0.50 | Hosted zone (if using) |
| **CloudWatch Logs** (optional) | $1-5 | ~1-5 GB/month |
| **Total** | **~$135-145/month** | |

### Annual Cost

~$1,620-1,740 per year

### Cost Optimization Tips

1. **Use Savings Plans** — 1-year commitment saves 30%, 3-year saves 50%
2. **Reserved Instances** — Similar savings to Savings Plans
3. **Spot Instances** — NOT recommended (need persistent uptime)
4. **Downsize** — Use t3.large ($60/mo) if workload allows
5. **Shutdown schedule** — Stop instance nights/weekends if not needed 24/7

### Comparison

| Option | Monthly Cost | Annual Cost |
|---|---|---|
| Proxmox (home) | ~$10-20 | ~$120-240 (electricity) |
| AWS Lightsail (8GB) | $40 | $480 |
| AWS EC2 t3.large | $60 | $720 |
| AWS EC2 t3.xlarge | $135 | $1,620 |
| AWS EKS | $230+ | $2,760+ |

---

## Post-Provisioning Checklist

After running provisioning script:

- [ ] SSH access works: `ssh -i ~/.ssh/homelab-key.pem admin@<elastic-ip>`
- [ ] Instance has internet connectivity: `ping 8.8.8.8`
- [ ] DNS resolves: `ping debian.org`
- [ ] Sudo access: `sudo whoami` (should return `root`)
- [ ] Disk space: `df -h` (should show ~100GB root)

**Next:** Proceed to [aws-ec2-deployment.md](aws-ec2-deployment.md) for deployment.

---

## Troubleshooting

### Can't SSH to instance

**Check:**
1. Security group allows SSH from your IP: `aws ec2 describe-security-groups --group-ids $SG_ID`
2. Your IP hasn't changed: `curl ifconfig.me`
3. Instance is running: `aws ec2 describe-instances --instance-ids $INSTANCE_ID`
4. Correct username: Debian uses `admin`, Ubuntu uses `ubuntu`

**Fix:**
```bash
# Update security group with new IP
NEW_IP="$(curl -s ifconfig.me)/32"
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 22 --cidr $NEW_IP
```

### Instance won't start

**Check:**
```bash
aws ec2 get-console-output --instance-id $INSTANCE_ID
```

Look for boot errors. Common issues:
- AMI incompatible with instance type
- EBS volume attachment failed

### Out of disk space

**Resize EBS volume:**
```bash
# Stop instance first
aws ec2 stop-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID

# Modify volume (find volume ID first)
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text)

aws ec2 modify-volume --volume-id $VOLUME_ID --size 200

# Start instance
aws ec2 start-instances --instance-ids $INSTANCE_ID

# Inside instance, extend filesystem:
sudo growpart /dev/nvme0n1 1
sudo resize2fs /dev/nvme0n1p1
```

### High costs

**Check:**
```bash
# View current month costs
aws ce get-cost-and-usage \
  --time-period Start=$(date -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

Common culprits:
- Data transfer (check CloudWatch logs size)
- Unattached EBS volumes
- Unattached Elastic IPs
- Idle instances running 24/7

---

## Cleanup (Deprovisioning)

To tear down everything:

```bash
# Terminate instance
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# Release Elastic IP
aws ec2 release-address --allocation-id $ALLOCATION_ID

# Delete security group (wait for instance to terminate first)
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
aws ec2 delete-security-group --group-id $SG_ID

# Delete key pair
aws ec2 delete-key-pair --key-name homelab-key
rm ~/.ssh/homelab-key.pem
```

---

## Summary

**Provision EC2 with:**
- Debian 13 AMI
- t3.xlarge (4 vCPU, 16 GB RAM)
- 100 GB gp3 root volume
- Elastic IP for stable access
- Security group (SSH, HTTP, HTTPS)
- Default VPC (or custom VPC)

**Cost:** ~$135/month

**Next:** [aws-ec2-deployment.md](aws-ec2-deployment.md) — Deploy home-lab to the provisioned instance
