#!/bin/bash
# Centralized VPC Endpoints - Cleanup Script
# Deletes all resources created by the test scripts
#
# Run via deploy.sh or set environment variables:
#   VPCE_HUB_PROFILE, VPCE_SPOKE_DEV_PROFILE, VPCE_SPOKE_TEST_PROFILE
#   VPCE_REGION (optional, default: us-east-2)
#   VPCE_STACK_PREFIX (optional, default: central-vpce)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get configuration from environment variables
PROFILE_HUB="${VPCE_HUB_PROFILE:-}"
PROFILE_SPOKE_DEV="${VPCE_SPOKE_DEV_PROFILE:-}"
PROFILE_SPOKE_TEST="${VPCE_SPOKE_TEST_PROFILE:-}"
REGION="${VPCE_REGION:-us-east-2}"
STACK_PREFIX="${VPCE_STACK_PREFIX:-central-vpce}"

# Validate required parameters
if [[ -z "$PROFILE_HUB" ]] || [[ -z "$PROFILE_SPOKE_DEV" ]] || [[ -z "$PROFILE_SPOKE_TEST" ]]; then
    log_error "All profile environment variables must be set."
    log_error "Run via deploy.sh or set: VPCE_HUB_PROFILE, VPCE_SPOKE_DEV_PROFILE, VPCE_SPOKE_TEST_PROFILE"
    exit 1
fi

echo "============================================================================"
echo "Centralized VPC Endpoints - Cleanup"
echo "============================================================================"
echo ""
log_info "Region: $REGION"
log_info "Stack Prefix: $STACK_PREFIX"
log_info "Hub Profile: $PROFILE_HUB"
log_info "Spoke Dev Profile: $PROFILE_SPOKE_DEV"
log_info "Spoke Test Profile: $PROFILE_SPOKE_TEST"
echo ""
log_warn "This will delete ALL resources created by the test scripts!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Cleanup cancelled"
    exit 0
fi

# ============================================================================
# STEP 1: Cleanup Spoke Test Account
# ============================================================================
log_info "Step 1: Cleaning up Spoke Test Account..."

PROFILE="$PROFILE_SPOKE_TEST"
ENVIRONMENT="test"

# Get VPC ID first
VPC_ID=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null || echo "")

# Delete Service Network Endpoints (VPC Endpoints of type ServiceNetwork)
log_info "Deleting Service Network Endpoints..."
for ENDPOINT_ID in $(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-endpoint-type,Values=ServiceNetwork" \
    --query "VpcEndpoints[?VpcId=='${VPC_ID}'].VpcEndpointId" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting Service Network Endpoint: $ENDPOINT_ID"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ENDPOINT_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Wait for endpoints to be deleted
sleep 5

# Delete VPC association (if any)
log_info "Deleting VPC Lattice associations..."
for ASSOC_ID in $(aws vpc-lattice list-service-network-vpc-associations \
    --query "items[?contains(id, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting association: $ASSOC_ID"
    aws vpc-lattice delete-service-network-vpc-association \
        --service-network-vpc-association-identifier $ASSOC_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Wait for associations to be deleted
sleep 5

# Delete Lattice security groups
log_info "Deleting Lattice security groups..."
for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${STACK_PREFIX}-*-sg-${ENVIRONMENT}" \
    --query 'SecurityGroups[*].GroupId' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id $SG_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete CloudFormation stack
log_info "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --region $REGION --profile $PROFILE 2>/dev/null || true

aws cloudformation wait stack-delete-complete \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "Spoke Test cleanup complete"

# ============================================================================
# STEP 2: Cleanup Spoke Dev Account
# ============================================================================
log_info "Step 2: Cleaning up Spoke Dev Account..."

PROFILE="$PROFILE_SPOKE_DEV"
ENVIRONMENT="dev"

# Get VPC ID first
VPC_ID=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null || echo "")

# Delete Service Network Endpoints (VPC Endpoints of type ServiceNetwork)
log_info "Deleting Service Network Endpoints..."
for ENDPOINT_ID in $(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-endpoint-type,Values=ServiceNetwork" \
    --query "VpcEndpoints[?VpcId=='${VPC_ID}'].VpcEndpointId" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting Service Network Endpoint: $ENDPOINT_ID"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ENDPOINT_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Wait for endpoints to be deleted
sleep 5

# Delete VPC association (if any)
log_info "Deleting VPC Lattice associations..."
for ASSOC_ID in $(aws vpc-lattice list-service-network-vpc-associations \
    --query "items[?contains(id, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting association: $ASSOC_ID"
    aws vpc-lattice delete-service-network-vpc-association \
        --service-network-vpc-association-identifier $ASSOC_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Wait for associations to be deleted
sleep 5

# Delete Lattice security groups
log_info "Deleting Lattice security groups..."
for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${STACK_PREFIX}-*-sg-${ENVIRONMENT}" \
    --query 'SecurityGroups[*].GroupId' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id $SG_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete CloudFormation stack
log_info "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --region $REGION --profile $PROFILE 2>/dev/null || true

aws cloudformation wait stack-delete-complete \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "Spoke Dev cleanup complete"


# ============================================================================
# STEP 3: Cleanup Hub Account - PHZs first
# ============================================================================
log_info "Step 3: Cleaning up Route 53 Private Hosted Zones..."

PROFILE="$PROFILE_HUB"

# Delete PHZs for each service
for SERVICE in ssm ssmmessages ec2messages; do
    PHZ_NAME="${SERVICE}.${REGION}.amazonaws.com"
    
    PHZ_ID=$(aws route53 list-hosted-zones-by-name \
        --dns-name "$PHZ_NAME" \
        --query "HostedZones[?Name=='${PHZ_NAME}.'].Id" \
        --output text --profile $PROFILE 2>/dev/null | head -1 | sed 's|/hostedzone/||')
    
    if [ -n "$PHZ_ID" ] && [ "$PHZ_ID" != "None" ] && [ "$PHZ_ID" != "" ]; then
        log_info "Found PHZ for $SERVICE: $PHZ_ID"
        
        # Delete all resource record sets except NS and SOA
        log_info "Deleting resource record sets..."
        RECORD_SETS=$(aws route53 list-resource-record-sets \
            --hosted-zone-id $PHZ_ID \
            --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" \
            --profile $PROFILE 2>/dev/null)
        
        if [ -n "$RECORD_SETS" ] && [ "$RECORD_SETS" != "[]" ]; then
            echo "$RECORD_SETS" | jq -c '.[]' | while read -r record; do
                NAME=$(echo "$record" | jq -r '.Name')
                TYPE=$(echo "$record" | jq -r '.Type')
                log_info "Deleting record: $NAME ($TYPE)"
                
                aws route53 change-resource-record-sets \
                    --hosted-zone-id $PHZ_ID \
                    --change-batch "{
                        \"Changes\": [{
                            \"Action\": \"DELETE\",
                            \"ResourceRecordSet\": $record
                        }]
                    }" \
                    --profile $PROFILE 2>/dev/null || true
            done
        fi
        
        # Disassociate all VPCs except the creating VPC
        log_info "Disassociating VPCs from PHZ..."
        ASSOCIATED_VPCS=$(aws route53 get-hosted-zone \
            --id $PHZ_ID \
            --query 'VPCs[*]' --output json \
            --profile $PROFILE 2>/dev/null || echo "[]")
        
        VPC_COUNT=$(echo "$ASSOCIATED_VPCS" | jq 'length')
        if [ "$VPC_COUNT" -gt 1 ]; then
            # Keep one VPC (the hub VPC) to allow deletion
            echo "$ASSOCIATED_VPCS" | jq -c '.[1:][]' | while read -r vpc; do
                VPC_ID=$(echo "$vpc" | jq -r '.VPCId')
                VPC_REGION=$(echo "$vpc" | jq -r '.VPCRegion')
                log_info "Disassociating VPC $VPC_ID from PHZ..."
                aws route53 disassociate-vpc-from-hosted-zone \
                    --hosted-zone-id $PHZ_ID \
                    --vpc VPCRegion=$VPC_REGION,VPCId=$VPC_ID \
                    --profile $PROFILE 2>/dev/null || true
            done
        fi
        
        # Delete the PHZ
        log_info "Deleting PHZ for $SERVICE..."
        aws route53 delete-hosted-zone \
            --id $PHZ_ID \
            --profile $PROFILE 2>/dev/null && \
            log_info "PHZ deleted for $SERVICE" || \
            log_warn "Could not delete PHZ for $SERVICE"
    else
        log_info "No PHZ found for $SERVICE"
    fi
done

log_info "Route 53 cleanup complete"

# ============================================================================
# STEP 4: Cleanup Hub Account - VPC Lattice Resources
# ============================================================================
log_info "Step 4: Cleaning up VPC Lattice Resources..."

PROFILE="$PROFILE_HUB"

# Delete RAM share
log_info "Deleting RAM resource share..."
RAM_SHARE_ARN=$(aws ram get-resource-shares \
    --resource-owner SELF \
    --name ${STACK_PREFIX}-lattice-share \
    --query 'resourceShares[0].resourceShareArn' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$RAM_SHARE_ARN" ] && [ "$RAM_SHARE_ARN" != "None" ]; then
    aws ram delete-resource-share \
        --resource-share-arn $RAM_SHARE_ARN \
        --region $REGION --profile $PROFILE 2>/dev/null || true
    log_info "RAM share deleted"
fi

# Get Service Network ID
SERVICE_NETWORK_ID=$(aws vpc-lattice list-service-networks \
    --query "items[?name=='${STACK_PREFIX}-service-network'].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$SERVICE_NETWORK_ID" ] && [ "$SERVICE_NETWORK_ID" != "None" ]; then
    # Delete Service Network VPC Associations (hub VPC)
    log_info "Deleting Service Network VPC Associations..."
    for ASSOC_ID in $(aws vpc-lattice list-service-network-vpc-associations \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --query 'items[*].id' --output text \
        --region $REGION --profile $PROFILE 2>/dev/null); do
        log_info "Deleting VPC association: $ASSOC_ID"
        aws vpc-lattice delete-service-network-vpc-association \
            --service-network-vpc-association-identifier $ASSOC_ID \
            --region $REGION --profile $PROFILE 2>/dev/null || true
    done
    
    # Wait for VPC associations to be deleted
    sleep 5
    
    # Delete Service Network Resource Associations
    log_info "Deleting Service Network Resource Associations..."
    for ASSOC_ID in $(aws vpc-lattice list-service-network-resource-associations \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --query 'items[*].id' --output text \
        --region $REGION --profile $PROFILE 2>/dev/null); do
        log_info "Deleting resource association: $ASSOC_ID"
        aws vpc-lattice delete-service-network-resource-association \
            --service-network-resource-association-identifier $ASSOC_ID \
            --region $REGION --profile $PROFILE 2>/dev/null || true
    done
    
    # Wait for associations to be deleted
    sleep 5
fi

# Delete Resource Configurations
log_info "Deleting Resource Configurations..."
for RC_ID in $(aws vpc-lattice list-resource-configurations \
    --query "items[?contains(name, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting resource configuration: $RC_ID"
    aws vpc-lattice delete-resource-configuration \
        --resource-configuration-identifier $RC_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Wait for resource configs to be deleted
sleep 5

# Delete Resource Gateways
log_info "Deleting Resource Gateways..."
for RGW_ID in $(aws vpc-lattice list-resource-gateways \
    --query "items[?contains(name, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting resource gateway: $RGW_ID"
    aws vpc-lattice delete-resource-gateway \
        --resource-gateway-identifier $RGW_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Wait for resource gateways to be deleted
log_info "Waiting for Resource Gateways to be deleted..."
sleep 10

# Delete Service Network
log_info "Deleting Service Network..."
if [ -n "$SERVICE_NETWORK_ID" ] && [ "$SERVICE_NETWORK_ID" != "None" ]; then
    aws vpc-lattice delete-service-network \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
    log_info "Service Network deleted"
fi

log_info "VPC Lattice cleanup complete"

# ============================================================================
# STEP 5: Cleanup Hub Account - CloudFormation Stack
# ============================================================================
log_info "Step 5: Cleaning up Hub CloudFormation Stack..."

PROFILE="$PROFILE_HUB"

# Delete CloudFormation stack
log_info "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --region $REGION --profile $PROFILE 2>/dev/null || true

aws cloudformation wait stack-delete-complete \
    --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "Hub Account cleanup complete"

# ============================================================================
# CLEANUP COMPLETE
# ============================================================================
echo ""
echo "============================================================================"
echo "CLEANUP COMPLETE"
echo "============================================================================"
echo ""
log_info "All resources have been deleted."
echo ""

# Clean up temp files
rm -f /tmp/hub-outputs.env /tmp/hub-phz-ids.env /tmp/spoke-dev-outputs.env /tmp/spoke-test-outputs.env /tmp/phz-ids.txt 2>/dev/null || true
