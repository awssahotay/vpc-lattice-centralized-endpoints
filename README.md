# Centralized VPC Endpoints via VPC Lattice

## Overview

This test environment validates centralized VPC endpoint access with overlapping CIDRs using:
- VPC Lattice Service Network with VPC Associations
- Centralized VPC Endpoints in a hub VPC
- Cross-account PHZ associations for DNS override

**Use Case:** Instead of deploying VPC endpoints in every workload VPC (600 endpoints × $0.01/hr = $4,380/month), deploy once in a central VPC and share via Lattice.

**Reference:** [AWS re:Post - Centralized Access to VPC Private Endpoints using VPC Lattice](https://repost.aws/articles/ARYLrU69ciTjeXKVmN7G5NMg/centralized-access-to-vpc-private-endpoints-using-vpc-lattice)

## Architecture (SIMPLIFIED)

```
Workload Dev VPC (10.0.0.0/16)     Workload Test VPC (10.0.0.0/16)
         │                                  │
         │ VPC Association                  │ VPC Association
         │ (NO Service Network Endpoint!)   │ (NO manual routes!)
         │                                  │
         └──────────────┬───────────────────┘
                        │
                        ▼
         VPC Lattice Service Network (RAM shared)
                        │
                        ▼
         Resource Gateway (in Hub VPC)
                        │
                        ▼
         Resource Configurations
         (point to VPCE DNS: vpce-xxx.ssm.us-east-2.vpce.amazonaws.com)
                        │
                        ▼
         Centralized VPC Endpoints (SSM, SSM Messages, EC2 Messages, STS)
                        │
                        ▼
         AWS Services (via AWS PrivateLink)
```

## Quick Start

```bash
# Deploy all resources
./deploy.sh \
    --hub-profile <YOUR_HUB_PROFILE> \
    --spoke-dev-profile <YOUR_DEV_PROFILE> \
    --spoke-test-profile <YOUR_TEST_PROFILE> \
    all

# Check status
./deploy.sh \
    --hub-profile <YOUR_HUB_PROFILE> \
    --spoke-dev-profile <YOUR_DEV_PROFILE> \
    --spoke-test-profile <YOUR_TEST_PROFILE> \
    status

# Cleanup
./deploy.sh \
    --hub-profile <YOUR_HUB_PROFILE> \
    --spoke-dev-profile <YOUR_DEV_PROFILE> \
    --spoke-test-profile <YOUR_TEST_PROFILE> \
    cleanup
```

## Prerequisites

- AWS CLI v2
- jq (for JSON parsing)
- Three AWS accounts with configured CLI profiles
- Appropriate IAM permissions in each account

## Commands

| Command | Description |
|---------|-------------|
| `all` | Deploy all resources (hub + both spokes) |
| `hub` | Deploy hub account only |
| `spoke-dev` | Deploy spoke dev account only |
| `spoke-test` | Deploy spoke test account only |
| `cleanup` | Delete all resources |
| `status` | Show deployment status |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--hub-profile` | AWS CLI profile for hub/endpoint account | Required |
| `--spoke-dev-profile` | AWS CLI profile for spoke dev account | Required |
| `--spoke-test-profile` | AWS CLI profile for spoke test account | Required |
| `--region` | AWS region | us-east-2 |
| `--prefix` | Stack prefix for resource naming | central-vpce |

## What Gets Created

**Hub Account (Endpoint VPC):**
- Endpoint VPC (172.31.0.0/16) with private subnets
- Centralized VPC Endpoints (SSM, SSM Messages, EC2 Messages, STS)
- VPC Lattice Service Network
- Resource Gateway
- Resource Configurations (one per endpoint)
- RAM Share to spoke accounts
- Private Hosted Zones for AWS service DNS override

**Spoke Accounts (Workload VPCs):**
- Workload VPC (10.0.0.0/16 - overlapping CIDR)
- Private subnet with test instance
- VPC Lattice VPC Association (simple!)
- PHZ associations (cross-account)
- NO local VPC endpoints (uses centralized ones)

## Testing

After deployment, connect to a test instance via SSM:

```bash
# Get instance ID from deployment output
aws ssm start-session --target <INSTANCE_ID> --profile <YOUR_DEV_PROFILE> --region us-east-2

# Test DNS resolution (should return Lattice IP 129.224.x.x)
nslookup ssm.us-east-2.amazonaws.com

# Test SSM connectivity (should work via centralized endpoint)
aws ssm describe-instance-information --region us-east-2

# Test S3 connectivity (should work via centralized endpoint)
aws s3 ls --region us-east-2
```

## Expected Results

| Test | Expected Result |
|------|-----------------|
| `nslookup ssm.us-east-2.amazonaws.com` | Lattice IP (129.224.x.x) |
| `curl https://ssm.us-east-2.amazonaws.com` | TLS handshake succeeds, HTTP 400 (expected) |
| `aws ssm start-session` | SSM session connects successfully |

## Cost Comparison

| Approach | 600 VPCs | Monthly Cost |
|----------|----------|--------------|
| Per-VPC Endpoints (4 endpoints each) | 2,400 endpoints | ~$17,520 |
| Centralized via Lattice | 4 endpoints + Lattice | ~$500 |
| **Savings** | | **~$17,000/month** |

## Key Differences from NFW Proxy Test

| Aspect | NFW Proxy Test | VPC Endpoint Test |
|--------|----------------|-------------------|
| Purpose | Internet egress | AWS service access |
| Target | NFW Proxy VPCE | AWS service VPCEs |
| Protocol | HTTP CONNECT (port 3128) | HTTPS (port 443) |
| DNS Override | `egress.proxy.internal` | `ssm.us-east-2.amazonaws.com` |
| Stack Prefix | `egress-proxy` | `central-vpce` |

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Main deployment wrapper script |
| `01-hub-account.sh` | Creates hub VPC, endpoints, Lattice, PHZs |
| `02-spoke-dev.sh` | Creates spoke dev VPC, VPC Association, PHZ associations |
| `03-spoke-test.sh` | Creates spoke test VPC, VPC Association, PHZ associations |
| `cleanup.sh` | Deletes all resources in correct order |

## How It Works

1. **Hub creates centralized VPC endpoints** for SSM, SSM Messages, EC2 Messages, STS
2. **Hub creates Resource Configurations** pointing to each VPCE DNS
3. **Hub creates PHZs** for AWS service DNS (e.g., `ssm.us-east-2.amazonaws.com`)
4. **PHZs contain A records** pointing to Lattice IPs (129.224.x.x)
5. **Spoke VPCs associate with Service Network** via simple VPC Association
6. **Spoke VPCs associate with Hub's PHZs** (cross-account)
7. **DNS resolution in spoke VPC** returns Lattice IP instead of public AWS IP
8. **Traffic flows through Lattice** to centralized VPC endpoints

## Troubleshooting

### SSM commands fail with timeout
- Check VPC Association is ACTIVE: `aws vpc-lattice list-service-network-vpc-associations`
- Verify PHZ is associated with spoke VPC: `aws route53 list-hosted-zones`
- Confirm DNS resolves to Lattice IP: `nslookup ssm.us-east-2.amazonaws.com`

### DNS resolves to public AWS IP (not 129.224.x.x)
- PHZ not associated with spoke VPC
- PHZ record not created correctly
- Check: `aws route53 list-resource-record-sets --hosted-zone-id <PHZ_ID>`

### Connection times out to Lattice IP
- VPC Association missing (most common cause!)
- Security group on Resource Gateway not allowing port 443
- Security group on VPC endpoints blocking traffic

### "VPC not found" when creating VPC Association
- Cross-account: Must run from the spoke account, not hub account
- Service Network must be RAM-shared to spoke account first

## Validated Test Results

```bash
# DNS Resolution - SUCCESS
$ nslookup ssm.us-east-2.amazonaws.com
Server:         10.0.0.2
Address:        10.0.0.2#53
Name:   ssm.us-east-2.amazonaws.com
Address: 129.224.52.1

# HTTPS Connectivity - SUCCESS
$ curl -v --connect-timeout 10 https://ssm.us-east-2.amazonaws.com
* Connected to ssm.us-east-2.amazonaws.com (129.224.52.1) port 443
* SSL connection using TLSv1.3
* Server certificate: CN=ssm.us-east-2.amazonaws.com
< HTTP/1.1 400 Bad Request  # Expected - SSM API doesn't respond to plain GET

# SSM Session - SUCCESS
$ aws ssm start-session --target <INSTANCE_ID> --profile <YOUR_DEV_PROFILE> --region us-east-2
# Session connected successfully
```
