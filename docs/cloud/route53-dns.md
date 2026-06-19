# Cloud DNS — Route53 (replacing AdGuard)

> On the home LAN, `*.lab.lan` resolved via AdGuard's wildcard rewrite
> (`*.lab.lan → 192.168.0.51`). The EC2 deployment has no AdGuard. This doc
> migrates that wildcard to a **Route53 private hosted zone** for the VPC.
>
> **Decision (2026-06-19):** keep the `.lab.lan` name (private zone) so the
> existing mkcert `*.lab.lan` wildcard cert keeps working unchanged.

## Why a private hosted zone (not public)

Access to the lab is VPN-only (instance SG `lunar-vpn-access-required`; no public
exposure). A **private hosted zone** associated with the VPC resolves `*.lab.lan`
to the instance's **private** IP for anything using the VPC resolver. No real
domain, no public IP, no cert change.

| Setting | Value |
|---|---|
| Zone name | `lab.lan` (private) |
| VPC | `vpc-03c90cc1969db9c8f` (region `us-east-1`, CIDR `10.0.0.0/16`) |
| Target | instance private IP `10.0.5.55` |
| Record | `*.lab.lan` A → `10.0.5.55` (TTL 60) |

> The instance itself does **not** need to resolve `*.lab.lan` (Traefik routes by
> Host header; sandboxes are outbound-only) — same as the old homelab note.

## Prerequisites

- The EC2 instance role (`lunar-nemoclaw-ec2-stack-role`) has **no Route53 (or
  CloudFormation) permissions** — deploy with admin credentials (console or a
  profile that can do `route53:*` / `cloudformation:*`).
- VPC must have `enableDnsSupport` + `enableDnsHostnames` = true (AWS default).

## Deploy via CloudFormation (recommended)

A ready template lives at [`cloudformation/route53-lab-dns.yaml`](../../cloudformation/route53-lab-dns.yaml).
It creates the private hosted zone, associates it with the VPC, and adds the
`*.lab.lan` wildcard record. Defaults are baked in (`lab.lan`,
`vpc-03c90cc1969db9c8f`, `us-east-1`, `10.0.5.55`).

```bash
# With admin creds (laptop or admin profile):
aws cloudformation deploy \
  --stack-name home-lab-route53-dns \
  --template-file cloudformation/route53-lab-dns.yaml \
  --capabilities CAPABILITY_NAMED_IAM
# Override a default if needed:
#   --parameter-overrides TargetPrivateIp=10.0.5.55 CreateExplicitRecords=false
```
Or upload the template in the CloudFormation console. Outputs include the
`HostedZoneId` and a `dig` test command.

The CLI steps below (sections 1–2) are the manual equivalent if you'd rather not
use CloudFormation.

## 1. Create the private hosted zone

```bash
aws route53 create-hosted-zone \
  --name lab.lan \
  --caller-reference "lab-lan-$(date +%s)" \
  --hosted-zone-config Comment="home-lab cloud private DNS",PrivateZone=true \
  --vpc VPCRegion=us-east-1,VPCId=vpc-03c90cc1969db9c8f
# Note the returned HostedZone Id (e.g. /hostedzone/Z0123456789ABC)
```

## 2. Add the wildcard record

```bash
ZONE_ID=Z0123456789ABC   # from step 1
cat > /tmp/lab-lan-records.json <<'JSON'
{
  "Comment": "wildcard -> homelab EC2 private IP",
  "Changes": [
    { "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.lab.lan",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [{ "Value": "10.0.5.55" }]
      } }
  ]
}
JSON
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/lab-lan-records.json
```

> Optional: instead of a single wildcard, add explicit A records
> (`openclaw.lab.lan`, `litellm.lab.lan`, `portainer.lab.lan`, …) all → `10.0.5.55`
> if you prefer not to wildcard. Wildcard matches the old AdGuard behavior.

## 3. Make clients resolve it (VPN DNS)

A private hosted zone only answers for clients querying the **VPC resolver**
(`10.0.0.2`, the VPC base +2). Pick one:

### Option A — Split-DNS on the VPN (recommended)
Push the VPC resolver **only for the `lab.lan` domain** (conditional forwarding),
leaving all other DNS on the client's normal resolver.
- **AWS Client VPN:** set DNS Servers to the VPC resolver; scope with a `lab.lan`
  search/split-DNS domain in the client profile.
- **WireGuard:** `DNS = 10.0.0.2, lab.lan` (clients that honor search-domain
  scoping route only `lab.lan` there).
- **OpenVPN:** push `dhcp-option DNS 10.0.0.2` + `dhcp-option DOMAIN lab.lan`
  (+ a split-DNS-aware client).

Negatives of pushing VPC DNS: if pushed as the *sole* resolver (not split), **all**
client DNS goes through AWS and other internal names may stop resolving while
connected. Split-DNS scoped to `lab.lan` avoids this.

### Option B — Per-client hosts file (no infra, quick)
On each client (while on VPN):
```
10.0.5.55  openclaw.lab.lan litellm.lab.lan portainer.lab.lan traefik.lab.lan registry.lab.lan
```
Mirrors how the homelab doc suggested hosts entries; fine for 1–2 operators.

### Option C — Route53 Resolver inbound endpoint
Only if clients can't be configured for split-DNS. Creates 2 ENIs in the VPC that
accept DNS queries from the VPN and answer private-zone names. ~$0.125/hr per ENI
+ query charges — overkill for a single-instance lab; documented for completeness.

## 4. Verify (from a VPN-connected client)

```bash
dig +short openclaw.lab.lan        # expect 10.0.5.55
curl -k https://openclaw.lab.lan/  # expect the OpenClaw dashboard (needs CA cert installed)
```
From the instance itself (uses the VPC resolver directly):
```bash
dig +short @10.0.0.2 openclaw.lab.lan   # expect 10.0.5.55 once the zone exists
```

## Notes / caveats

- **TLS unchanged:** the mkcert `*.lab.lan` cert still matches; clients still need
  the local CA (`traefik/certs/ca/rootCA.pem`) installed — see README § HTTPS/CA.
- **Traefik label routes** (portainer/litellm/registry) are currently 404 due to the
  Docker-provider API-version skew (separate issue); only static-file routes
  (`openclaw.lab.lan`, dashboard) resolve through Traefik regardless of DNS. DNS gets
  you to the instance; Traefik routing is the next layer.
- If the instance's **private IP changes** (stop/start without an Elastic IP), update
  the `*.lab.lan` record. Consider a private static IP / Elastic Network Interface to
  pin `10.0.5.55`.
