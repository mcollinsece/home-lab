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

## Automated deployment (recommended)

Everything below is encoded in a single idempotent orchestrator,
[`bootstrap/deploy-ec2.sh`](../../bootstrap/deploy-ec2.sh), which incorporates all
the lessons from the first EC2 bring-up (see [Lessons learned](#lessons-learned-2026-06-ec2-bring-up)).

```bash
# One-time, on the host first (interactive OAuth — cannot be scripted):
claude login
grok login            # skip if you pass --skip-grok

# Then from the repo:
git clone <repo> ~/home-lab && cd ~/home-lab
./bootstrap/deploy-ec2.sh            # Bedrock via instance role by default
#   --static-keys   use a scoped IAM user's keys instead of the instance role
#   --skip-grok     deploy without the Grok wrapper
#   --region us-east-1
```

It runs, in order: `setup-host.sh` → `init-secrets --instance-role` → docker compose
→ OpenShell inference → Claude wrapper → Grok wrapper → NemoClaw director →
OpenClaw relay (`openclaw.lab.lan`) → reboot-autostart units → verification.

**Prereqs it cannot do for you:** `claude login` / `grok login` on the host; and on
the AWS side, **IMDS hop limit 2** + the **bedrock-runtime VPC-endpoint SG open on
443** (see [aws-ec2-provisioning.md](aws-ec2-provisioning.md#bedrock-via-the-instance-role-recommended--no-static-keys)).
After it finishes: install the CA cert on clients and set up DNS
([route53-dns.md](route53-dns.md)).

The manual, step-by-step walkthrough below explains what each phase does and is the
reference when something needs hand-holding.

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
- **NemoClaw:** ~8-12 minutes (non-interactive onboard; the director sandbox image build is the slow part)
- **Wrappers:** ~5 minutes each (first sandbox create pulls the ~5GB base image)
- **Total:** ~40-55 minutes (mostly image pulls/builds; `deploy-ec2.sh` runs it unattended)

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

## Install NemoClaw + OpenClaw director

> Install NemoClaw **after** the wrappers — it installs its own OpenShell 0.0.44
> CLI/gateway (port 8080) that shadows the lab 0.0.62 gateway (17670). Creating the
> wrapper sandboxes first means the plain `openshell` CLI still targets the lab
> gateway during their creation.

Two scripts encode the whole flow (both called by `deploy-ec2.sh`):

```bash
# 1. Install NemoClaw + onboard the director, non-interactively, against LiteLLM:
bootstrap/setup-nemoclaw.sh            # --name my-assistant --model claude-code-wrapper-local

# 2. Expose it at openclaw.lab.lan through Traefik:
bootstrap/setup-openclaw-relay.sh      # --name my-assistant
```

### What `setup-nemoclaw.sh` handles (and why)

- **`binutils` (`strings`) is required** by the installer's credential-rewrite check
  — it installs it if missing.
- **Non-interactive onboard against an OpenAI-compatible endpoint uses
  `NEMOCLAW_PROVIDER=custom`** — *not* `openai`, which hardcodes `api.openai.com` and
  returns 401. The mapping is non-obvious:
  | Setting | Env var |
  |---|---|
  | provider | `NEMOCLAW_PROVIDER=custom` |
  | API key | `COMPATIBLE_API_KEY=<LITELLM_MASTER_KEY>` |
  | endpoint | `NEMOCLAW_ENDPOINT_URL=http://localhost:4000/v1` (not `NEMOCLAW_INFERENCE_BASE_URL`) |
  | model | `NEMOCLAW_MODEL=claude-code-wrapper-local` |
- **The onboard sandbox is named `my-assistant`** (CLI: `nemoclaw my-assistant ...`),
  not `director`. The old repo probe (`nemoclaw-director-probe.sh`) assumed a
  `director`-named sandbox and is **not used** in this flow.
- **onboard clobbers `openshell/gateway.env`** (via the `~/.config/openshell/gateway.env`
  symlink) with NemoClaw's 8080 config. The script **restores** the simple lab version
  afterward (`OPENSHELL_DRIVERS=docker` + `OPENSHELL_BIND_ADDRESS=0.0.0.0`) — otherwise
  the lab gateway comes up wrong on the next reboot. `recover` does *not* re-clobber it.

### What `setup-openclaw-relay.sh` handles (the 502 fix)

NemoClaw 0.0.55 serves the dashboard via an **SSH tunnel on host `127.0.0.1:18789`**,
*not* on the sandbox container's network. So Traefik → `openclaw-director:18789`
returns **502**. The script bridges it with a **socat relay** on the ai-net gateway IP
(`172.19.0.1:18790 → 127.0.0.1:18789`, a persistent `openclaw-socat-relay.service`),
repoints the Traefik file route at the relay, CORS-patches `openclaw.json`
(`allowedOrigins += https://openclaw.lab.lan`), adds the wrapper models to the picker,
and `nemoclaw <name> recover`s to reload.

### Verify

```bash
curl -s  -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18789/          # 200 (direct)
curl -sk -o /dev/null -w "%{http_code}\n" -H 'Host: openclaw.lab.lan' https://localhost/   # 200 (Traefik)
```

### Lab gateway commands after NemoClaw

`nemoclaw` installs its 0.0.44 CLI at `~/.local/bin/openshell` (shadowing the 0.0.62
at `/usr/bin/openshell`) and flips the active gateway to `nemoclaw`. The wrapper
sandboxes keep running as containers (`restart: unless-stopped`); the wrapper *setup*
scripts use `docker` directly and don't need the CLI. If you do need the lab gateway
CLI, use the explicit binary + endpoint form documented in
[bootstrap/TROUBLESHOOTING.md](../../bootstrap/TROUBLESHOOTING.md).

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

> **For this deployment we use a Route53 private hosted zone** (`*.lab.lan →
> instance private IP`), which keeps the existing mkcert `*.lab.lan` cert valid and
> matches the VPN-only access model. Full plan + CloudFormation template:
> **[route53-dns.md](route53-dns.md)** / [`cloudformation/route53-lab-dns.yaml`](../../cloudformation/route53-lab-dns.yaml).
> The Cloudflare/public-Route53 options below remain for public-exposure scenarios.

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

### Reboot autostart + credential refresh (scripted)

`deploy-ec2.sh` runs [`bootstrap/install-autostart-services.sh`](../../bootstrap/install-autostart-services.sh),
which installs the reboot-recovery units (director recover + both wrappers) **and**
the daily OAuth credential-sync timers, then enables linger. Prefer that over the
manual snippets here. What survives a reboot vs the gaps it closes is documented in
**[reboot-autostart.md](reboot-autostart.md)**.

### Manual credential-refresh timers (reference)

> The installer script above already does this. These snippets are the manual
> equivalent (adjust the `/home/admin` paths to your user, e.g. `/home/debian`).

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

## Lessons learned (2026-06 EC2 bring-up)

Concrete gotchas from the first real EC2 deploy — all now handled by the scripts,
listed here so the *why* is recorded.

1. **Docker group / systemd --user manager.** After `setup-host.sh` adds the user
   to `docker`, the `systemd --user` manager still has the old groups, so
   `openshell-gateway` crash-loops "failed to query Docker daemon". Fix: restart the
   user manager (`sudo systemctl restart user@$(id -u).service`) — now done by
   `setup-host.sh`. Your interactive shell also lacks the group until re-login; the
   scripts use `sg docker`/re-exec to cope.

2. **mkcert keyless committed certs.** A fresh clone ships `rootCA.pem` /
   `_wildcard.lab.lan.pem` but not their gitignored keys, so mkcert can't sign and
   `setup-host.sh` aborted under `set -e`. Fix: drop the keyless cert+CA and
   regenerate a fresh local CA — now handled in `setup-host.sh`.

3. **Bedrock needs IMDS hop-limit 2 + the endpoint SG open.** See
   [provisioning §Bedrock](aws-ec2-provisioning.md#bedrock-via-the-instance-role-recommended--no-static-keys).
   Symptom was `InvokeModel` hanging while `sts`/`bedrock` control-plane worked.

4. **Wrapper `requirements.txt` was wrong.** `claude-code-openai-wrapper` pinned a
   nonexistent `claude-agent-sdk>=0.4.0` and omitted `python-dotenv`, `httpx`,
   `slowapi`. Fixed in the repo.

5. **NemoClaw non-interactive onboard** needs `binutils`, `NEMOCLAW_PROVIDER=custom`
   (+ `COMPATIBLE_API_KEY`, `NEMOCLAW_ENDPOINT_URL`), names the sandbox
   `my-assistant`, and clobbers `openshell/gateway.env` — all handled by
   `setup-nemoclaw.sh`. See the [NemoClaw section](#install-nemoclaw--openclaw-director).

6. **openclaw.lab.lan 502** — the dashboard is an SSH tunnel on host loopback, not
   on the container network. Fixed by `setup-openclaw-relay.sh` (socat relay).

7. **Traefik Docker-provider 404s** — Traefik v3.3 sends Docker API 1.24 (daemon
   min 1.40), so label-discovered routes (`portainer/litellm/registry.lab.lan`) 404.
   Only static file routes (`openclaw`, dashboard) work. Services are reachable
   directly. Open item: bump the Traefik image or add a socket-proxy / static routes.

8. **Reboot persistence** — containers return but the `docker exec`-launched wrapper
   uvicorns and the director tunnel don't. Closed by `install-autostart-services.sh`;
   details in [reboot-autostart.md](reboot-autostart.md).

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
