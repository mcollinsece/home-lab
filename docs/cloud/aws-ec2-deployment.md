# AWS EC2 Deployment Guide

> **Deploy home-lab stack to AWS EC2 instance**

This document covers deploying the complete home-lab stack (Docker Compose services, OpenShell 
sandboxes, NemoClaw director, agent wrappers) to a provisioned EC2 instance.

**Prerequisites:** EC2 instance provisioned per [aws-ec2-provisioning.md](aws-ec2-provisioning.md)

---

## Table of Contents

- [Overview](#overview)
- [Initial Access](#initial-access)
- [System Preparation](#system-preparation)
- [Clone Repository](#clone-repository)
- [Run Host Setup](#run-host-setup)
- [Initialize Secrets](#initialize-secrets)
- [Start Docker Services](#start-docker-services)
- [Configure OpenShell](#configure-openshell)
- [Install NemoClaw](#install-nemoclaw)
- [Start Agent Wrappers](#start-agent-wrappers)
- [Configure DNS](#configure-dns)
- [TLS Certificates](#tls-certificates)
- [Verification](#verification)
- [Post-Deployment](#post-deployment)
- [Troubleshooting](#troubleshooting)

---

## Overview

### What You're Deploying

```
EC2 Instance
  ├── Docker Compose Services
  │     ├── Traefik (reverse proxy)
  │     ├── Portainer (container management)
  │     ├── Registry (local Docker registry)
  │     └── LiteLLM (inference proxy)
  ├── OpenShell Gateway (lab)
  │     └── Agent sandboxes
  ├── NemoClaw Gateway
  │     └── OpenClaw director sandbox
  └── Agent Wrappers
        ├── claude-code-wrapper (openshell-claude-revproxy)
        └── grok-wrapper (openshell-grok-wrapper)
```

### Deployment Time

- **System prep:** 5 minutes
- **setup-host.sh:** 10-15 minutes (downloads Docker, Node, OpenShell)
- **Docker services:** 2 minutes
- **NemoClaw:** 5 minutes (interactive onboarding)
- **Wrappers:** 5 minutes each
- **Total:** ~35-45 minutes

---

## Initial Access

### SSH to Instance

```bash
# Using key from provisioning
ssh -i ~/.ssh/homelab-key.pem admin@<elastic-ip>

# Or if you have your own key
ssh -i ~/.ssh/your-key.pem admin@<elastic-ip>
```

**Username depends on AMI:**
- Debian: `admin`
- Ubuntu: `ubuntu`

### Verify System

```bash
# Check OS
cat /etc/os-release

# Check resources
free -h  # Should show 16GB RAM for t3.xlarge
df -h    # Should show ~100GB root volume
nproc    # Should show 4 CPUs
```

### Update System

```bash
sudo apt update
sudo apt upgrade -y
```

**Reboot if kernel updated:**
```bash
sudo reboot
# Wait 30 seconds, then reconnect
```

---

## System Preparation

### Set Hostname (Optional but Recommended)

```bash
sudo hostnamectl set-hostname homelab
echo "127.0.0.1 homelab" | sudo tee -a /etc/hosts
```

### Create User (Optional — Use admin/ubuntu)

The default user (`admin` on Debian, `ubuntu` on Ubuntu) is fine. If you want a different user:

```bash
sudo adduser debian
sudo usermod -aG sudo debian
su - debian
```

For this guide, we'll use the default `admin` user.

### Install Prerequisites

```bash
# Essential tools
sudo apt install -y \
  git \
  curl \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  jq \
  unzip
```

---

## Clone Repository

### Option A: HTTPS Clone (Public Repo)

```bash
cd ~
git clone https://github.com/mcollinsece/home-lab.git
cd home-lab
```

### Option B: SSH Clone (Private Repo or You Have SSH Keys)

```bash
# Add GitHub SSH key (if not already)
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/github_ed25519
cat ~/.ssh/github_ed25519.pub
# Add this public key to GitHub: Settings → SSH Keys

# Clone
cd ~
git clone git@github.com:mcollinsece/home-lab.git
cd home-lab
```

### Verify Checkout

```bash
git status
git log --oneline -5
```

Should show latest commit (e.g., `cfd0312 docs: Add CLI-to-API wrapper design pattern`).

---

## Run Host Setup

### Execute setup-host.sh

```bash
cd ~/home-lab
./bootstrap/setup-host.sh
```

**What it does:**
1. Installs base packages (build-essential, python3, etc.)
2. Installs Node.js 22 (via NodeSource)
3. Installs Docker Engine (rootful daemon)
4. Adds user to `docker` group
5. Installs OpenShell (pinned v0.0.62)
6. Sets up gateway.env (Docker driver)
7. Installs mkcert + generates wildcard cert (for `*.lab.lan`)
8. Creates `/etc/hosts` entry for `registry.lab.lan`
9. Configures insecure registry
10. Symlinks tools (`osbox`, `init-secrets`) to `~/.local/bin`

**Expected output:**
```
==> Installing base packages...
==> Installing Node.js 22...
==> Installing Docker Engine...
==> Installing OpenShell v0.0.62...
==> Setup complete!
```

### Activate Docker Group

**Important:** You must activate the docker group before continuing.

```bash
# Option 1: Log out and back in
exit
ssh -i ~/.ssh/homelab-key.pem admin@<elastic-ip>

# Option 2: Use newgrp (in current session)
newgrp docker

# Verify
docker ps
# Should return empty list (not "permission denied")
```

### Verify Setup

```bash
# Docker
docker --version
docker ps

# Node.js
node --version  # Should be v22.x
npm --version   # Should be 10.x

# OpenShell
openshell --version  # Should be v0.0.62
openshell sandbox list  # Should be empty

# Tools
which osbox
which init-secrets
```

---

## Initialize Secrets

### Run init-secrets

```bash
cd ~/home-lab
init-secrets
```

**Interactive prompts:**

1. **Bedrock AWS Access Key ID:** Your AWS access key (from IAM)
2. **Bedrock AWS Secret Access Key:** Your AWS secret key
3. **Bedrock AWS Region:** `us-east-1` (recommended for Claude Bedrock models)
4. **Generate LiteLLM master key?** `y` (auto-generates secure key)

**Output files:**
- `.secrets/bedrock.env` — AWS credentials for LiteLLM → Bedrock
- `.secrets/litellm.env` — LiteLLM master key for API auth

**Security note:** `.secrets/` is gitignored. Keep backups elsewhere (password manager, AWS Secrets Manager).

### Verify Secrets

```bash
ls -la ~/home-lab/.secrets/
# Should show: bedrock.env, litellm.env

cat ~/home-lab/.secrets/litellm.env
# Should show: LITELLM_MASTER_KEY=<hex-string>
```

---

## Start Docker Services

### Copy Non-Secret Config

```bash
cd ~/home-lab
cp litellm/litellm.env.example litellm/litellm.env
```

### Start All Services

```bash
docker compose -f docker/compose.yml up -d
```

**Expected output:**
```
[+] Running 5/5
 ✔ Network ai-net      Created
 ✔ Container traefik   Started
 ✔ Container portainer Started
 ✔ Container registry  Started
 ✔ Container litellm   Started
```

### Verify Services

```bash
docker compose -f docker/compose.yml ps
# All should show "Up" status

docker logs traefik --tail 20
docker logs litellm --tail 20
```

### Test LiteLLM

```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)

curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  | python3 -m json.tool
```

**Expected:** JSON list with `claude-sonnet-4-6` and wrapper models.

**Test Bedrock inference:**
```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Say hi"}]}' \
  | python3 -m json.tool | head -30
```

**Expected:** Response with Claude's message.

---

## Configure OpenShell

### Create Provider

```bash
cd ~/home-lab

LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/.secrets/litellm.env | cut -d= -f2)

openshell provider create \
  --name litellm-local \
  --type openai \
  --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
  --config OPENAI_BASE_URL=http://localhost:4000/v1
```

### Set Inference Route

```bash
openshell inference set \
  --no-verify \
  --provider litellm-local \
  --model claude-sonnet-4-6
```

**`--no-verify` skips embeddings check** (Bedrock doesn't support embeddings).

### Verify

```bash
openshell inference get
```

**Expected:**
```
Provider: litellm-local
Model: claude-sonnet-4-6
```

---

## Install NemoClaw

### Run Installer

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

**Interactive prompts:**

1. **Install location:** Press Enter (default: `~/.nemoclaw`)
2. **Add to PATH?** `y`
3. **Inference provider:** Select `OpenAI-compatible`
4. **API key:** Paste the LITELLM_MASTER_KEY (from `.secrets/litellm.env`)
5. **Base URL:** `http://localhost:4000/v1`
6. **Model:** `claude-sonnet-4-6`

**Expected output:**
```
✓ NemoClaw installed successfully
✓ OpenClaw director container created
```

### Verify Installation

```bash
# Check NemoClaw CLI
nemoclaw --version

# Check director container
docker ps --filter 'name=openshell-director'
# Should show one container running
```

### Restore Lab Gateway Config

NemoClaw installs its own OpenShell 0.0.44. Restore the lab gateway (0.0.62) as default:

```bash
ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env
```

**Use explicit paths for lab gateway commands:**
```bash
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox list
```

### Start Probe Service

```bash
systemctl --user enable --now nemoclaw-director-control-ui
systemctl --user status nemoclaw-director-control-ui
```

**Expected:** `active (exited)` — This is normal. Probe runs once on boot.

**What it does:**
1. Patches OpenClaw `openclaw.json` (CORS, provider rename, model adds)
2. Connects director to `ai-net`
3. Starts OpenClaw gateway inside sandbox

### Verify OpenClaw

```bash
# Check if OpenClaw is reachable
curl -sk http://localhost:18789/ -o /dev/null -w "%{http_code}\n"
# Expected: 200
```

**Note:** Uses HTTP locally. Traefik handles HTTPS termination for external access.

---

## Start Agent Wrappers

### 1. Claude Code Wrapper

#### Authenticate on Host

```bash
# Install Claude Code CLI (if not already)
# See: https://code.claude.com/

# Login
claude auth login
# Follow OAuth flow in browser
```

#### Create Sandbox

```bash
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure \
  sandbox create --name claude-revproxy --no-auto-providers \
  --policy ~/home-lab/openshell/policies/claude-code.yaml
```

#### Start Wrapper

```bash
cd ~/home-lab
bootstrap/setup-claude-revproxy.sh
```

**Expected output:**
```
==> Syncing Claude OAuth credentials...
==> Connecting sandbox to ai-net...
==> Copying wrapper code to sandbox...
==> Installing wrapper Python dependencies...
==> Starting claude-code-openai-wrapper...
==> Wrapper listening on :8000
==> Done.
```

#### Verify

```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ss -tlnp | grep ':8000'
# Should show uvicorn listening
```

### 2. Grok Wrapper

#### Authenticate on Host

```bash
# Install Grok CLI (if not already)
# Download from https://grok.com/download or via:
curl -L https://grok.com/downloads/grok-linux-amd64 -o /tmp/grok-linux-amd64
sudo mv /tmp/grok-linux-amd64 /usr/local/bin/grok
sudo chmod +x /usr/local/bin/grok

# Login
grok login
# Follow OAuth flow
```

#### Create Sandbox

```bash
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure \
  sandbox create --name grok-wrapper --no-auto-providers \
  --policy ~/home-lab/openshell/policies/grok.yaml
```

#### Start Wrapper

```bash
cd ~/home-lab
bootstrap/setup-grok-wrapper.sh
```

**Expected output:**
```
==> Syncing Grok OAuth credentials...
==> Installing Grok Build CLI in sandbox...
==> Connecting sandbox to ai-net...
==> Copying wrapper code to sandbox...
==> Installing wrapper Python dependencies...
==> Starting grok-openai-wrapper...
==> Wrapper listening on :8001
==> Done.
```

#### Verify

```bash
_SB=$(docker ps --filter 'name=openshell-grok-wrapper-' --format '{{.Names}}' | head -1)
docker exec "$_SB" ss -tlnp | grep ':8001'
# Should show uvicorn listening
```

---

## Configure DNS

### Option A: Cloudflare Tunnel (Recommended)

**Install cloudflared:**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o cloudflared
sudo mv cloudflared /usr/local/bin/
sudo chmod +x /usr/local/bin/cloudflared
```

**Authenticate:**
```bash
cloudflared tunnel login
# Opens browser for Cloudflare auth
```

**Create tunnel:**
```bash
cloudflared tunnel create homelab
# Note the tunnel ID from output
```

**Configure DNS:**
```bash
# For each service you want to expose
cloudflared tunnel route dns homelab openclaw.yourdomain.com
cloudflared tunnel route dns homelab litellm.yourdomain.com
cloudflared tunnel route dns homelab portainer.yourdomain.com
```

**Create config:**
```bash
mkdir -p ~/.cloudflared
cat > ~/.cloudflared/config.yml << EOF
tunnel: <tunnel-id>
credentials-file: /home/admin/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: openclaw.yourdomain.com
    service: http://localhost:80
  - hostname: litellm.yourdomain.com
    service: http://localhost:80
  - hostname: portainer.yourdomain.com
    service: http://localhost:80
  - service: http_status:404
EOF
```

**Install as service:**
```bash
sudo cloudflared service install
sudo systemctl start cloudflared
sudo systemctl enable cloudflared
```

**Verify:**
```bash
sudo systemctl status cloudflared
curl https://openclaw.yourdomain.com/
```

### Option B: Route53 Public DNS

**Prerequisites:**
- Domain registered (Route53 or external registrar)
- Elastic IP assigned to instance

**Get Elastic IP:**
```bash
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d' ' -f2)
ELASTIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Elastic IP: $ELASTIC_IP"
```

**Create Route53 records:**
```bash
DOMAIN="yourdomain.com"
HOSTED_ZONE_ID="Z1234567890ABC"  # Your hosted zone ID

# Wildcard A record
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.'$DOMAIN'",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "'$ELASTIC_IP'"}]
      }
    }]
  }'
```

**Update Traefik for public access** (see TLS Certificates section).

---

## TLS Certificates

### Option A: Use Existing mkcert Certs (For Testing)

`setup-host.sh` already created `*.lab.lan` certs in `traefik/certs/`.

**Add hosts file entry on your local machine:**
```bash
# On your local machine (not EC2)
echo "<elastic-ip> openclaw.lab.lan litellm.lab.lan portainer.lab.lan" | sudo tee -a /etc/hosts
```

**Install CA cert on local machine:**
```bash
# Copy CA cert from EC2
scp -i ~/.ssh/homelab-key.pem admin@<elastic-ip>:~/home-lab/traefik/certs/ca/rootCA.pem ~/Downloads/

# Install on macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/rootCA.pem

# Install on Linux
sudo cp ~/Downloads/rootCA.pem /usr/local/share/ca-certificates/homelab-ca.crt
sudo update-ca-certificates
```

Now `https://openclaw.lab.lan` will work from your local machine.

### Option B: Let's Encrypt (For Production)

**Update Traefik config** to use Let's Encrypt:

```bash
cd ~/home-lab/traefik
```

Edit `traefik/traefik.yml`:
```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: your-email@example.com
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
```

Edit `docker/compose.yml` Traefik service:
```yaml
traefik:
  command:
    - "--certificatesresolvers.letsencrypt.acme.email=your-email@example.com"
    - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
    - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
  volumes:
    - ./traefik/letsencrypt:/letsencrypt
```

**Restart Traefik:**
```bash
docker compose -f docker/compose.yml restart traefik
```

Certificates will be automatically obtained for your domain.

---

## Verification

### 1. Docker Services

```bash
docker compose -f ~/home-lab/docker/compose.yml ps
# All should be "Up"

docker ps
# Should show: traefik, portainer, registry, litellm, and OpenShell sandbox containers
```

### 2. OpenShell Gateway

```bash
openshell sandbox list
# Should show: claude-revproxy, grok-wrapper (Ready state)
```

### 3. NemoClaw Director

```bash
docker ps --filter 'name=openshell-director'
# Should show director container

curl -sk http://localhost:18789/ -o /dev/null -w "%{http_code}\n"
# Should return: 200
```

### 4. LiteLLM Models

```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)

curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  | jq '.data[].id'
```

**Expected:**
```
"claude-sonnet-4-6"
"bedrock/us.anthropic.claude-sonnet-4-6"
"claude-code-wrapper-local"
"claude-code-sonnet"
"claude-code/sonnet"
"grok-wrapper-local"
"grok-beta"
```

### 5. Agent Wrappers

**Test Claude wrapper:**
```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-code-wrapper-local","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  | jq '.choices[0].message.content' | head -5
```

**Test Grok wrapper:**
```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"grok-wrapper-local","messages":[{"role":"user","content":"What is 2+2?"}]}' \
  | jq '.choices[0].message.content' | head -5
```

### 6. OpenClaw Dashboard

**Get gateway token:**
```bash
_DIR=$(docker ps --filter 'name=openshell-director' --format '{{.Names}}' | head -1)
docker exec "$_DIR" grep -o '"token":"[^"]*"' /sandbox/.openclaw/openclaw.json | cut -d'"' -f4
```

**Access dashboard:**
- Local: `http://localhost:18789` (or `https://openclaw.lab.lan` if using hosts file)
- Public: `https://openclaw.yourdomain.com` (if DNS configured)

**Paste token**, select a model, test a message.

---

## Post-Deployment

### Set Up Automatic Credential Refresh

Create systemd timers for OAuth credential syncs:

```bash
# Claude credentials (daily refresh)
cat > ~/.config/systemd/user/sync-claude-creds.service << 'EOF'
[Unit]
Description=Sync Claude OAuth credentials to wrapper sandbox

[Service]
Type=oneshot
ExecStart=/home/admin/home-lab/bootstrap/sync-claude-credentials.sh
EOF

cat > ~/.config/systemd/user/sync-claude-creds.timer << 'EOF'
[Unit]
Description=Sync Claude credentials daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable timer
systemctl --user enable --now sync-claude-creds.timer

# Same for Grok
cat > ~/.config/systemd/user/sync-grok-creds.service << 'EOF'
[Unit]
Description=Sync Grok OAuth credentials to wrapper sandbox

[Service]
Type=oneshot
ExecStart=/home/admin/home-lab/bootstrap/sync-grok-credentials.sh
EOF

cat > ~/.config/systemd/user/sync-grok-creds.timer << 'EOF'
[Unit]
Description=Sync Grok credentials daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user enable --now sync-grok-creds.timer
```

### Enable Linger (Persist User Services After Logout)

```bash
sudo loginctl enable-linger $USER
```

This ensures systemd user services (like credential sync timers) run even when you're not logged in.

### Set Up Backups

**EBS snapshots (via AWS CLI or console):**
```bash
# From local machine (not EC2)
aws ec2 create-snapshot \
  --volume-id vol-1234567890abcdef0 \
  --description "homelab-backup-$(date +%Y%m%d)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=homelab-backup}]'
```

**Automate with cron or EventBridge scheduled rule.**

### Monitoring

**CloudWatch Logs (optional):**

Install CloudWatch agent:
```bash
wget https://s3.amazonaws.com/amazoncloudwatch-agent/debian/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb
```

Configure to send logs to CloudWatch (requires IAM role with CloudWatchAgentServerPolicy).

### Security Hardening

1. **Restrict SSH:**
   - Use key-only auth (disable password auth in `/etc/ssh/sshd_config`)
   - Change SSH port (optional): `Port 2222` in `sshd_config`
   - Update security group accordingly

2. **Enable fail2ban:**
   ```bash
   sudo apt install -y fail2ban
   sudo systemctl enable --now fail2ban
   ```

3. **Regular updates:**
   ```bash
   # Add to weekly cron
   sudo apt update && sudo apt upgrade -y
   ```

4. **Firewall (ufw):**
   ```bash
   sudo apt install -y ufw
   sudo ufw allow 22/tcp
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw enable
   ```

---

## Troubleshooting

### Services Won't Start

**Check logs:**
```bash
docker compose -f ~/home-lab/docker/compose.yml logs --tail 50
docker logs traefik
docker logs litellm
```

**Common issues:**
- Port conflicts (8000, 8001, 17670, 18789)
- Permission errors (ensure user in `docker` group)
- Secret file missing (run `init-secrets`)

### OpenShell Sandboxes Fail

**Check gateway:**
```bash
systemctl --user status openshell-gateway
journalctl --user -u openshell-gateway -n 50
```

**Restart gateway:**
```bash
systemctl --user restart openshell-gateway
```

### NemoClaw Director Won't Start

**Check probe service:**
```bash
systemctl --user status nemoclaw-director-control-ui
journalctl --user -u nemoclaw-director-control-ui -n 50
```

**Re-run probe:**
```bash
systemctl --user restart nemoclaw-director-control-ui
```

**Check director container:**
```bash
_DIR=$(docker ps --filter 'name=openshell-director' --format '{{.Names}}' | head -1)
docker logs "$_DIR" --tail 100
```

### Wrappers Not Responding

**Check sandbox state:**
```bash
openshell sandbox list
```

**Restart wrapper:**
```bash
# Claude
~/home-lab/bootstrap/setup-claude-revproxy.sh

# Grok
~/home-lab/bootstrap/setup-grok-wrapper.sh
```

**Check logs:**
```bash
_SB=$(docker ps --filter 'name=openshell-claude-revproxy-' --format '{{.Names}}' | head -1)
docker logs "$_SB" --tail 50
```

### DNS Not Resolving

**If using hosts file:**
- Verify entry: `cat /etc/hosts` (on local machine)
- Verify Elastic IP: `curl ifconfig.me` (on EC2)

**If using Cloudflare Tunnel:**
```bash
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -n 50
```

**If using Route53:**
- Check DNS propagation: `dig openclaw.yourdomain.com`
- Wait 5 minutes for TTL

### Out of Memory

**Check usage:**
```bash
free -h
docker stats --no-stream
```

**Resize instance:**
```bash
# Stop instance
aws ec2 stop-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID

# Change type
aws ec2 modify-instance-attribute \
  --instance-id $INSTANCE_ID \
  --instance-type t3.2xlarge

# Start
aws ec2 start-instances --instance-ids $INSTANCE_ID
```

---

## Summary

**Deployment checklist:**

- [x] SSH to EC2 instance
- [x] Update system
- [x] Clone repository
- [x] Run `setup-host.sh`
- [x] Activate docker group
- [x] Run `init-secrets`
- [x] Start Docker services
- [x] Configure OpenShell provider
- [x] Install NemoClaw
- [x] Start probe service
- [x] Start Claude wrapper
- [x] Start Grok wrapper
- [x] Configure DNS (Cloudflare or Route53)
- [x] Set up TLS certs
- [x] Verify all services
- [x] Set up credential sync timers
- [x] Enable linger
- [x] Configure backups

**You now have:**
- Full home-lab stack running on AWS EC2
- OpenClaw director accessible via HTTPS
- Three models available: Bedrock, Claude Code agent, Grok agent
- Isolated sandboxes for each wrapper
- Automated credential refresh (via timers)

**Next:** [aws-eks-migration.md](../future/aws-eks-migration.md) for EKS migration planning.
