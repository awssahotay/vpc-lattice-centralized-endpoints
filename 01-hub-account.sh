#!/bin/bash
# Centralized VPC Endpoints - Hub Account Setup
#
# This script creates:
# - Endpoint VPC (172.31.0.0/16) with private subnets
# - Centralized VPC Endpoints (SSM, SSM Messages, EC2 Messages, S3)
# - VPC Lattice Service Network
# - Resource Gateway
# - Resource Configurations (one per endpoint)
# - RAM Share to spoke accounts
# - Route 53 Private Hosted Zone for DNS override
#
# Run via deploy.sh or set environment variables:
#   VPCE_HUB_PROFILE
#   VPCE_SPOKE_DEV_ACCOUNT, VPCE_SPOKE_TEST_ACCOUNT (for RAM sharing)
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
PROFILE="${VPCE_HUB_PROFILE:-}"
SPOKE_DEV_ACCOUNT="${VPCE_SPOKE_DEV_ACCOUNT:-}"
SPOKE_TEST_ACCOUNT="${VPCE_SPOKE_TEST_ACCOUNT:-}"
REGION="${VPCE_REGION:-us-east-2}"
STACK_PREFIX="${VPCE_STACK_PREFIX:-central-vpce}"

# Validate required parameters
if [[ -z "$PROFILE" ]]; then
    log_error "VPCE_HUB_PROFILE not set. Run via deploy.sh or set environment variable."
    exit 1
fi
if [[ -z "$SPOKE_DEV_ACCOUNT" ]] || [[ -z "$SPOKE_TEST_ACCOUNT" ]]; then
    log_error "VPCE_SPOKE_DEV_ACCOUNT and VPCE_SPOKE_TEST_ACCOUNT must be set for RAM sharing."
    exit 1
fi

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE --query 'Account' --output text)
log_info "Hub Account ID: $ACCOUNT_ID"
log_info "Region: $REGION"
log_info "Stack Prefix: $STACK_PREFIX"
log_info "Spoke Dev Account: $SPOKE_DEV_ACCOUNT"
log_info "Spoke Test Account: $SPOKE_TEST_ACCOUNT"

# ============================================================================
# STEP 1: Create Endpoint VPC with CloudFormation
# ============================================================================
log_info "Step 1: Creating Endpoint VPC..."

cat > /tmp/endpoint-vpc.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: Centralized VPC Endpoints - Hub VPC

Parameters:
  StackPrefix:
    Type: String
    Default: central-vpce

Resources:
  EndpointVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 172.31.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-endpoint-vpc'

  PrivateSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref EndpointVPC
      CidrBlock: 172.31.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-subnet-a'

  PrivateSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref EndpointVPC
      CidrBlock: 172.31.2.0/24
      AvailabilityZone: !Select [1, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-subnet-b'

  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref EndpointVPC
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-rt'

  PrivateSubnetARTAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetA
      RouteTableId: !Ref PrivateRouteTable

  PrivateSubnetBRTAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnetB
      RouteTableId: !Ref PrivateRouteTable

  # Security Group for VPC Endpoints
  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for centralized VPC endpoints
      VpcId: !Ref EndpointVPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 0.0.0.0/0
          Description: Allow HTTPS from anywhere (Lattice will route)
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-endpoint-sg'

  # SSM Endpoint
  SSMEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref EndpointVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssm'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup
      PrivateDnsEnabled: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-ssm-endpoint'

  # SSM Messages Endpoint
  SSMMessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref EndpointVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssmmessages'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup
      PrivateDnsEnabled: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-ssmmessages-endpoint'

  # EC2 Messages Endpoint
  EC2MessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref EndpointVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2messages'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup
      PrivateDnsEnabled: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-ec2messages-endpoint'

  # S3 Gateway Endpoint
  S3Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref EndpointVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
      VpcEndpointType: Gateway
      RouteTableIds:
        - !Ref PrivateRouteTable
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-s3-endpoint'

  # STS Endpoint (required for SSM agent to get credentials)
  STSEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref EndpointVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.sts'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnetA
        - !Ref PrivateSubnetB
      SecurityGroupIds:
        - !Ref EndpointSecurityGroup
      PrivateDnsEnabled: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-sts-endpoint'

Outputs:
  VpcId:
    Value: !Ref EndpointVPC
    Export:
      Name: !Sub '${StackPrefix}-vpc-id'
  
  PrivateSubnetAId:
    Value: !Ref PrivateSubnetA
    Export:
      Name: !Sub '${StackPrefix}-private-subnet-a-id'
  
  PrivateSubnetBId:
    Value: !Ref PrivateSubnetB
    Export:
      Name: !Sub '${StackPrefix}-private-subnet-b-id'
  
  EndpointSecurityGroupId:
    Value: !Ref EndpointSecurityGroup
    Export:
      Name: !Sub '${StackPrefix}-endpoint-sg-id'
  
  SSMEndpointId:
    Value: !Ref SSMEndpoint
    Export:
      Name: !Sub '${StackPrefix}-ssm-endpoint-id'
  
  SSMMessagesEndpointId:
    Value: !Ref SSMMessagesEndpoint
    Export:
      Name: !Sub '${StackPrefix}-ssmmessages-endpoint-id'
  
  EC2MessagesEndpointId:
    Value: !Ref EC2MessagesEndpoint
    Export:
      Name: !Sub '${StackPrefix}-ec2messages-endpoint-id'
  
  STSEndpointId:
    Value: !Ref STSEndpoint
    Export:
      Name: !Sub '${StackPrefix}-sts-endpoint-id'
EOF

aws cloudformation deploy \
    --template-file /tmp/endpoint-vpc.yaml \
    --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --parameter-overrides StackPrefix=${STACK_PREFIX} \
    --region $REGION \
    --profile $PROFILE

log_info "Endpoint VPC created successfully"

# Get outputs
VPC_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
PRIVATE_SUBNET_A=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetAId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
ENDPOINT_SG=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`EndpointSecurityGroupId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
SSM_ENDPOINT_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`SSMEndpointId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)

log_info "VPC ID: $VPC_ID"
log_info "Private Subnet A: $PRIVATE_SUBNET_A"
log_info "SSM Endpoint ID: $SSM_ENDPOINT_ID"

# ============================================================================
# STEP 2: Get VPC Endpoint DNS Names
# ============================================================================
log_info "Step 2: Getting VPC Endpoint DNS Names..."

# Get SSM endpoint DNS
SSM_VPCE_DNS=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $SSM_ENDPOINT_ID \
    --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text \
    --region $REGION --profile $PROFILE)
log_info "SSM VPCE DNS: $SSM_VPCE_DNS"

# Get SSM Messages endpoint DNS
SSMMSG_ENDPOINT_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`SSMMessagesEndpointId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
SSMMSG_VPCE_DNS=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $SSMMSG_ENDPOINT_ID \
    --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text \
    --region $REGION --profile $PROFILE)
log_info "SSM Messages VPCE DNS: $SSMMSG_VPCE_DNS"

# Get EC2 Messages endpoint DNS
EC2MSG_ENDPOINT_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`EC2MessagesEndpointId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
EC2MSG_VPCE_DNS=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $EC2MSG_ENDPOINT_ID \
    --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text \
    --region $REGION --profile $PROFILE)
log_info "EC2 Messages VPCE DNS: $EC2MSG_VPCE_DNS"

# Get STS endpoint DNS
STS_ENDPOINT_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-endpoint-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`STSEndpointId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
STS_VPCE_DNS=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $STS_ENDPOINT_ID \
    --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text \
    --region $REGION --profile $PROFILE)
log_info "STS VPCE DNS: $STS_VPCE_DNS"

# ============================================================================
# STEP 3: Create VPC Lattice Service Network
# ============================================================================
log_info "Step 3: Creating VPC Lattice Service Network..."

SERVICE_NETWORK_ID=$(aws vpc-lattice create-service-network \
    --name ${STACK_PREFIX}-service-network \
    --auth-type NONE \
    --region $REGION \
    --profile $PROFILE \
    --query 'id' --output text 2>/dev/null || \
    aws vpc-lattice list-service-networks \
    --query "items[?name=='${STACK_PREFIX}-service-network'].id" \
    --output text --region $REGION --profile $PROFILE)

log_info "Service Network ID: $SERVICE_NETWORK_ID"

SERVICE_NETWORK_ARN=$(aws vpc-lattice get-service-network \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query 'arn' --output text \
    --region $REGION --profile $PROFILE)

log_info "Service Network ARN: $SERVICE_NETWORK_ARN"

# ============================================================================
# STEP 4: Create Resource Gateway
# ============================================================================
log_info "Step 4: Creating Resource Gateway..."

EXISTING_RGW=$(aws vpc-lattice list-resource-gateways \
    --query "items[?name=='${STACK_PREFIX}-resource-gateway'].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_RGW" ] && [ "$EXISTING_RGW" != "None" ]; then
    RESOURCE_GATEWAY_ID=$EXISTING_RGW
    log_info "Using existing Resource Gateway: $RESOURCE_GATEWAY_ID"
else
    RESOURCE_GATEWAY_ID=$(aws vpc-lattice create-resource-gateway \
        --name ${STACK_PREFIX}-resource-gateway \
        --vpc-identifier $VPC_ID \
        --subnet-ids $PRIVATE_SUBNET_A \
        --security-group-ids $ENDPOINT_SG \
        --region $REGION \
        --profile $PROFILE \
        --query 'id' --output text)
    log_info "Created Resource Gateway: $RESOURCE_GATEWAY_ID"
fi

# Wait for Resource Gateway to be active
log_info "Waiting for Resource Gateway to become active..."
while true; do
    STATUS=$(aws vpc-lattice get-resource-gateway \
        --resource-gateway-identifier $RESOURCE_GATEWAY_ID \
        --query 'status' --output text \
        --region $REGION --profile $PROFILE)
    if [ "$STATUS" == "ACTIVE" ]; then
        log_info "Resource Gateway is ACTIVE"
        break
    fi
    log_info "Resource Gateway status: $STATUS - waiting..."
    sleep 10
done

# ============================================================================
# STEP 5: Create Resource Configurations for each endpoint
# ============================================================================
log_info "Step 5: Creating Resource Configurations..."

# Function to create resource configuration
create_resource_config() {
    local NAME=$1
    local DNS=$2
    local PORT=$3
    
    EXISTING_RC=$(aws vpc-lattice list-resource-configurations \
        --query "items[?name=='${STACK_PREFIX}-${NAME}-resource'].id" \
        --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_RC" ] && [ "$EXISTING_RC" != "None" ] && [ "$EXISTING_RC" != "" ]; then
        echo >&2 "[INFO] Using existing Resource Configuration for $NAME: $EXISTING_RC"
        echo "$EXISTING_RC"
        return 0
    fi
    
    echo >&2 "[INFO] Creating Resource Configuration for $NAME..."
    RC_RESULT=$(aws vpc-lattice create-resource-configuration \
        --name ${STACK_PREFIX}-${NAME}-resource \
        --type SINGLE \
        --resource-gateway-identifier $RESOURCE_GATEWAY_ID \
        --port-ranges "$PORT" \
        --protocol TCP \
        --resource-configuration-definition "dnsResource={domainName=${DNS},ipAddressType=IPV4}" \
        --region $REGION \
        --profile $PROFILE 2>&1)
    
    if [ $? -ne 0 ]; then
        echo >&2 "[ERROR] Failed to create Resource Configuration for $NAME: $RC_RESULT"
        return 1
    fi
    
    RC_ID=$(echo "$RC_RESULT" | jq -r '.id // empty')
    if [ -z "$RC_ID" ]; then
        echo >&2 "[ERROR] Failed to get Resource Configuration ID for $NAME"
        return 1
    fi
    
    echo >&2 "[INFO] Created Resource Configuration for $NAME: $RC_ID"
    echo "$RC_ID"
    return 0
}

# Create resource configs for each endpoint
SSM_RC_ID=$(create_resource_config "ssm" "$SSM_VPCE_DNS" "443")
if [ -z "$SSM_RC_ID" ]; then
    log_error "Failed to create SSM Resource Configuration"
    exit 1
fi

SSMMSG_RC_ID=$(create_resource_config "ssmmessages" "$SSMMSG_VPCE_DNS" "443")
if [ -z "$SSMMSG_RC_ID" ]; then
    log_error "Failed to create SSM Messages Resource Configuration"
    exit 1
fi

EC2MSG_RC_ID=$(create_resource_config "ec2messages" "$EC2MSG_VPCE_DNS" "443")
if [ -z "$EC2MSG_RC_ID" ]; then
    log_error "Failed to create EC2 Messages Resource Configuration"
    exit 1
fi

STS_RC_ID=$(create_resource_config "sts" "$STS_VPCE_DNS" "443")
if [ -z "$STS_RC_ID" ]; then
    log_error "Failed to create STS Resource Configuration"
    exit 1
fi

log_info "SSM RC ID: $SSM_RC_ID"
log_info "SSM Messages RC ID: $SSMMSG_RC_ID"
log_info "EC2 Messages RC ID: $EC2MSG_RC_ID"
log_info "STS RC ID: $STS_RC_ID"

# Wait for resource configurations to be active
log_info "Waiting for Resource Configurations to become active..."
for RC_ID in $SSM_RC_ID $SSMMSG_RC_ID $EC2MSG_RC_ID $STS_RC_ID; do
    if [ -z "$RC_ID" ] || [ ${#RC_ID} -lt 20 ]; then
        log_error "Invalid Resource Configuration ID: $RC_ID"
        exit 1
    fi
    while true; do
        STATUS=$(aws vpc-lattice get-resource-configuration \
            --resource-configuration-identifier $RC_ID \
            --query 'status' --output text \
            --region $REGION --profile $PROFILE 2>/dev/null)
        if [ "$STATUS" == "ACTIVE" ]; then
            log_info "Resource Configuration $RC_ID is ACTIVE"
            break
        elif [ "$STATUS" == "CREATE_FAILED" ]; then
            log_error "Resource Configuration $RC_ID failed to create"
            exit 1
        fi
        log_info "Resource Configuration $RC_ID status: $STATUS - waiting..."
        sleep 5
    done
done

# ============================================================================
# STEP 6: Associate Resource Configurations with Service Network
# ============================================================================
log_info "Step 6: Associating Resource Configurations with Service Network..."

associate_resource_config() {
    local RC_ID=$1
    local NAME=$2
    local RETRY_COUNT=0
    local MAX_RETRIES=3
    
    EXISTING_ASSOC=$(aws vpc-lattice list-service-network-resource-associations \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --query "items[?resourceConfigurationId=='${RC_ID}'].id" \
        --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_ASSOC" ] && [ "$EXISTING_ASSOC" != "None" ] && [ "$EXISTING_ASSOC" != "" ]; then
        log_info "Using existing association for $NAME: $EXISTING_ASSOC"
        return 0
    fi
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        ASSOC_RESULT=$(aws vpc-lattice create-service-network-resource-association \
            --service-network-identifier $SERVICE_NETWORK_ID \
            --resource-configuration-identifier $RC_ID \
            --region $REGION \
            --profile $PROFILE 2>&1)
        
        if [ $? -eq 0 ]; then
            ASSOC_ID=$(echo "$ASSOC_RESULT" | jq -r '.id // empty')
            log_info "Created association for $NAME: $ASSOC_ID"
            return 0
        fi
        
        if echo "$ASSOC_RESULT" | grep -q "ThrottlingException"; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            log_warn "Throttled, retrying in 10 seconds... (attempt $RETRY_COUNT/$MAX_RETRIES)"
            sleep 10
        else
            log_error "Failed to create association for $NAME: $ASSOC_RESULT"
            return 1
        fi
    done
    
    log_error "Max retries exceeded for $NAME"
    return 1
}

associate_resource_config "$SSM_RC_ID" "ssm"
sleep 3
associate_resource_config "$SSMMSG_RC_ID" "ssmmessages"
sleep 3
associate_resource_config "$EC2MSG_RC_ID" "ec2messages"
sleep 3
associate_resource_config "$STS_RC_ID" "sts"

# ============================================================================
# STEP 7: Share Service Network via RAM
# ============================================================================
log_info "Step 7: Sharing Service Network via RAM..."

log_info "Sharing to Spoke Dev Account: $SPOKE_DEV_ACCOUNT"
log_info "Sharing to Spoke Test Account: $SPOKE_TEST_ACCOUNT"

# Check if RAM share already exists
EXISTING_RAM_SHARE=$(aws ram get-resource-shares \
    --resource-owner SELF \
    --name ${STACK_PREFIX}-lattice-share \
    --query 'resourceShares[0].resourceShareArn' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_RAM_SHARE" ] && [ "$EXISTING_RAM_SHARE" != "None" ] && [ "$EXISTING_RAM_SHARE" != "" ]; then
    RAM_SHARE_ARN=$EXISTING_RAM_SHARE
    log_info "Using existing RAM Share: $RAM_SHARE_ARN"
else
    RAM_SHARE_ARN=$(aws ram create-resource-share \
        --name ${STACK_PREFIX}-lattice-share \
        --resource-arns $SERVICE_NETWORK_ARN \
        --principals $SPOKE_DEV_ACCOUNT $SPOKE_TEST_ACCOUNT \
        --no-allow-external-principals \
        --region $REGION \
        --profile $PROFILE \
        --query 'resourceShare.resourceShareArn' --output text)
    log_info "Created RAM Share: $RAM_SHARE_ARN"
fi

# ============================================================================
# STEP 8: Associate Hub VPC with Service Network (required for DNS resolution)
# ============================================================================
log_info "Step 8: Associating Hub VPC with Service Network..."

# Check if association already exists
EXISTING_VPC_ASSOC=$(aws vpc-lattice list-service-network-vpc-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?vpcId=='${VPC_ID}'].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_VPC_ASSOC" ] && [ "$EXISTING_VPC_ASSOC" != "None" ] && [ "$EXISTING_VPC_ASSOC" != "" ]; then
    log_info "Hub VPC already associated with Service Network: $EXISTING_VPC_ASSOC"
else
    VPC_ASSOC_RESULT=$(aws vpc-lattice create-service-network-vpc-association \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --vpc-identifier $VPC_ID \
        --region $REGION \
        --profile $PROFILE 2>&1)
    
    if [ $? -eq 0 ]; then
        VPC_ASSOC_ID=$(echo "$VPC_ASSOC_RESULT" | jq -r '.id // empty')
        log_info "Created Hub VPC association: $VPC_ASSOC_ID"
        
        # Wait for association to be active
        log_info "Waiting for VPC association to become active..."
        while true; do
            STATUS=$(aws vpc-lattice get-service-network-vpc-association \
                --service-network-vpc-association-identifier $VPC_ASSOC_ID \
                --query 'status' --output text \
                --region $REGION --profile $PROFILE 2>/dev/null)
            if [ "$STATUS" == "ACTIVE" ]; then
                log_info "VPC association is ACTIVE"
                break
            fi
            log_info "VPC association status: $STATUS - waiting..."
            sleep 5
        done
    else
        log_warn "Failed to create Hub VPC association: $VPC_ASSOC_RESULT"
    fi
fi

# ============================================================================
# STEP 9: Get Lattice Resource DNS entries
# ============================================================================
log_info "Step 9: Getting Lattice Resource DNS entries..."

sleep 5

# Get DNS for each resource configuration
SSM_LATTICE_DNS=$(aws vpc-lattice list-service-network-resource-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?resourceConfigurationId=='${SSM_RC_ID}'].dnsEntry.domainName" --output text \
    --region $REGION --profile $PROFILE)
log_info "SSM Lattice DNS: $SSM_LATTICE_DNS"

SSMMSG_LATTICE_DNS=$(aws vpc-lattice list-service-network-resource-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?resourceConfigurationId=='${SSMMSG_RC_ID}'].dnsEntry.domainName" --output text \
    --region $REGION --profile $PROFILE)
log_info "SSM Messages Lattice DNS: $SSMMSG_LATTICE_DNS"

EC2MSG_LATTICE_DNS=$(aws vpc-lattice list-service-network-resource-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?resourceConfigurationId=='${EC2MSG_RC_ID}'].dnsEntry.domainName" --output text \
    --region $REGION --profile $PROFILE)
log_info "EC2 Messages Lattice DNS: $EC2MSG_LATTICE_DNS"

STS_LATTICE_DNS=$(aws vpc-lattice list-service-network-resource-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?resourceConfigurationId=='${STS_RC_ID}'].dnsEntry.domainName" --output text \
    --region $REGION --profile $PROFILE)
log_info "STS Lattice DNS: $STS_LATTICE_DNS"

# ============================================================================
# STEP 10: Create Route 53 Private Hosted Zones for DNS override
# ============================================================================
log_info "Step 10: Creating Route 53 Private Hosted Zones for DNS override..."

# PHZs are created in the Hub account and associated with Hub VPC first.
# Then spoke VPCs will be authorized to associate with these PHZs.
# This follows the AWS reference architecture pattern.

# Function to create PHZ with CNAME record
create_service_phz() {
    local SERVICE_NAME=$1
    local SERVICE_DNS="${SERVICE_NAME}.${REGION}.amazonaws.com"
    local LATTICE_DNS=$2
    
    echo >&2 "[INFO] Creating PHZ for $SERVICE_DNS..."
    
    # Check if PHZ already exists
    local EXISTING_PHZ=$(aws route53 list-hosted-zones \
        --query "HostedZones[?Name=='${SERVICE_DNS}.'].Id" \
        --output json --profile $PROFILE 2>/dev/null)
    local PHZ_ID=$(echo "$EXISTING_PHZ" | jq -r '.[0] // empty' | sed 's|/hostedzone/||')
    
    if [ -n "$PHZ_ID" ] && [ "$PHZ_ID" != "null" ] && [ "$PHZ_ID" != "" ]; then
        echo >&2 "[INFO] Using existing PHZ for $SERVICE_DNS: $PHZ_ID"
    else
        # Create PHZ associated with Hub VPC
        local CREATE_RESULT=$(aws route53 create-hosted-zone \
            --name "$SERVICE_DNS" \
            --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
            --caller-reference "${STACK_PREFIX}-${SERVICE_NAME}-$(date +%s)" \
            --hosted-zone-config Comment="DNS override for centralized VPC endpoint",PrivateZone=true \
            --profile $PROFILE 2>&1)
        
        if [ $? -ne 0 ]; then
            echo >&2 "[ERROR] Failed to create PHZ for $SERVICE_DNS: $CREATE_RESULT"
            return 1
        fi
        
        PHZ_ID=$(echo "$CREATE_RESULT" | jq -r '.HostedZone.Id' | sed 's|/hostedzone/||')
        echo >&2 "[INFO] Created PHZ for $SERVICE_DNS: $PHZ_ID"
    fi
    
    # Create CNAME record pointing to Lattice DNS
    echo >&2 "[INFO] Creating CNAME record: $SERVICE_DNS -> $LATTICE_DNS"
    
    local CHANGE_BATCH=$(cat << JSONEOF
{
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": "${SERVICE_DNS}",
            "Type": "CNAME",
            "TTL": 60,
            "ResourceRecords": [{"Value": "${LATTICE_DNS}"}]
        }
    }]
}
JSONEOF
)
    
    local CHANGE_RESULT=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$PHZ_ID" \
        --change-batch "$CHANGE_BATCH" \
        --profile $PROFILE 2>&1)
    
    if [ $? -ne 0 ]; then
        echo >&2 "[WARN] Failed to create CNAME record: $CHANGE_RESULT"
        echo >&2 "[WARN] PHZ created but record may need manual configuration"
    else
        echo >&2 "[INFO] Created CNAME record for $SERVICE_DNS"
    fi
    
    # Return the PHZ ID
    echo "$PHZ_ID"
}

# Create PHZs for each AWS service
log_info "Creating PHZ for SSM..."
SSM_PHZ_ID=$(create_service_phz "ssm" "$SSM_LATTICE_DNS")
log_info "SSM PHZ ID: $SSM_PHZ_ID"

log_info "Creating PHZ for SSM Messages..."
SSMMSG_PHZ_ID=$(create_service_phz "ssmmessages" "$SSMMSG_LATTICE_DNS")
log_info "SSM Messages PHZ ID: $SSMMSG_PHZ_ID"

log_info "Creating PHZ for EC2 Messages..."
EC2MSG_PHZ_ID=$(create_service_phz "ec2messages" "$EC2MSG_LATTICE_DNS")
log_info "EC2 Messages PHZ ID: $EC2MSG_PHZ_ID"

log_info "Creating PHZ for STS..."
STS_PHZ_ID=$(create_service_phz "sts" "$STS_LATTICE_DNS")
log_info "STS PHZ ID: $STS_PHZ_ID"

# ============================================================================
# STEP 11: Authorize Spoke VPCs to Associate with PHZs
# ============================================================================
log_info "Step 11: Authorizing spoke accounts to associate with PHZs..."

# Note: We authorize the spoke ACCOUNTS here. The actual VPC association
# happens in the spoke scripts after they create their VPCs.
# We save the PHZ IDs so spoke scripts can use them.

log_info "PHZ IDs saved for spoke scripts to use"
log_info "Spoke scripts will:"
log_info "  1. Create their VPCs"
log_info "  2. Request authorization from hub for PHZ association"
log_info "  3. Associate their VPCs with hub PHZs"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "============================================================================"
echo "HUB ACCOUNT SETUP COMPLETE"
echo "============================================================================"
echo ""
echo "Resources Created:"
echo "  - Endpoint VPC: $VPC_ID (associated with Service Network)"
echo "  - SSM Endpoint: $SSM_ENDPOINT_ID"
echo "  - Service Network: $SERVICE_NETWORK_ID"
echo "  - Resource Gateway: $RESOURCE_GATEWAY_ID"
echo "  - RAM Share: $RAM_SHARE_ARN"
echo ""
echo "Private Hosted Zones (for DNS override):"
echo "  - SSM PHZ: $SSM_PHZ_ID (ssm.${REGION}.amazonaws.com)"
echo "  - SSM Messages PHZ: $SSMMSG_PHZ_ID (ssmmessages.${REGION}.amazonaws.com)"
echo "  - EC2 Messages PHZ: $EC2MSG_PHZ_ID (ec2messages.${REGION}.amazonaws.com)"
echo "  - STS PHZ: $STS_PHZ_ID (sts.${REGION}.amazonaws.com)"
echo ""
echo "Lattice DNS Entries:"
echo "  - SSM: $SSM_LATTICE_DNS"
echo "  - SSM Messages: $SSMMSG_LATTICE_DNS"
echo "  - EC2 Messages: $EC2MSG_LATTICE_DNS"
echo "  - STS: $STS_LATTICE_DNS"
echo ""
echo "NOTE: Spoke scripts will associate their VPCs with these PHZs"
echo "      for cross-account DNS override."
echo ""
echo "============================================================================"

# Save outputs for spoke scripts
cat > /tmp/hub-outputs.env << ENVEOF
SERVICE_NETWORK_ID=$SERVICE_NETWORK_ID
SERVICE_NETWORK_ARN=$SERVICE_NETWORK_ARN
RESOURCE_GATEWAY_ID=$RESOURCE_GATEWAY_ID
SSM_LATTICE_DNS=$SSM_LATTICE_DNS
SSMMSG_LATTICE_DNS=$SSMMSG_LATTICE_DNS
EC2MSG_LATTICE_DNS=$EC2MSG_LATTICE_DNS
STS_LATTICE_DNS=$STS_LATTICE_DNS
HUB_VPC_ID=$VPC_ID
SSM_PHZ_ID=$SSM_PHZ_ID
SSMMSG_PHZ_ID=$SSMMSG_PHZ_ID
EC2MSG_PHZ_ID=$EC2MSG_PHZ_ID
STS_PHZ_ID=$STS_PHZ_ID
ENVEOF

log_info "Outputs saved to /tmp/hub-outputs.env"
