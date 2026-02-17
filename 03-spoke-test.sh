#!/bin/bash
# Centralized VPC Endpoints - Spoke Test Account Setup
#
# This script creates:
# - Workload VPC (10.0.0.0/16) - overlapping CIDR
# - Private subnet with test instance
# - VPC Lattice Service Network VPC Association (NOT Service Network Endpoint)
# - PHZ associations for DNS override
# - NO local VPC endpoints (uses centralized ones via Lattice)
#
# KEY FINDING: VPC Association alone is sufficient for EC2 instances.
# Service Network Endpoints are only needed for TGW/VPN/Direct Connect traffic.
#
# Run via deploy.sh or set environment variables:
#   VPCE_SPOKE_TEST_PROFILE
#   VPCE_HUB_PROFILE (for PHZ authorization)
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
PROFILE="${VPCE_SPOKE_TEST_PROFILE:-}"
HUB_PROFILE="${VPCE_HUB_PROFILE:-}"
REGION="${VPCE_REGION:-us-east-2}"
STACK_PREFIX="${VPCE_STACK_PREFIX:-central-vpce}"
ENVIRONMENT="test"

# Validate required parameters
if [[ -z "$PROFILE" ]]; then
    log_error "VPCE_SPOKE_TEST_PROFILE not set. Run via deploy.sh or set environment variable."
    exit 1
fi
if [[ -z "$HUB_PROFILE" ]]; then
    log_error "VPCE_HUB_PROFILE not set. Run via deploy.sh or set environment variable."
    exit 1
fi

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE --query 'Account' --output text)
log_info "Spoke Test Account ID: $ACCOUNT_ID"
log_info "Region: $REGION"
log_info "Stack Prefix: $STACK_PREFIX"

# Load hub outputs
if [ -f /tmp/hub-outputs.env ]; then
    source /tmp/hub-outputs.env
    log_info "Loaded hub outputs from previous script"
else
    log_error "No hub outputs found at /tmp/hub-outputs.env"
    log_error "Run 01-hub-account.sh first or run via deploy.sh"
    exit 1
fi

# Load PHZ IDs
if [ -f /tmp/hub-phz-ids.env ]; then
    source /tmp/hub-phz-ids.env
    log_info "Loaded PHZ IDs from hub script"
fi

log_info "Service Network ID: $SERVICE_NETWORK_ID"

# ============================================================================
# STEP 1: Create Workload VPC with CloudFormation
# ============================================================================
log_info "Step 1: Creating Workload VPC..."

cat > /tmp/spoke-vpc-test.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: Centralized VPC Endpoints - Spoke VPC (Overlapping CIDR, NO local endpoints)

Parameters:
  StackPrefix:
    Type: String
    Default: central-vpce
  Environment:
    Type: String
    Default: test

Resources:
  # VPC with overlapping CIDR (same as other spoke accounts)
  WorkloadVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-workload-vpc-${Environment}'

  # Private Subnet
  PrivateSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref WorkloadVPC
      CidrBlock: 10.0.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-subnet-${Environment}'

  # Private Route Table (no internet route - uses Lattice for AWS services)
  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref WorkloadVPC
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-rt-${Environment}'

  PrivateSubnetRTAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable

  # Security Group for test instance
  TestInstanceSG:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for test instance
      VpcId: !Ref WorkloadVPC
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-test-sg-${Environment}'

  # IAM Role for test instance
  TestInstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${StackPrefix}-test-role-${Environment}'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

  TestInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub '${StackPrefix}-test-profile-${Environment}'
      Roles:
        - !Ref TestInstanceRole

  # Test EC2 Instance
  TestInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'
      InstanceType: t3.micro
      SubnetId: !Ref PrivateSubnet
      SecurityGroupIds:
        - !Ref TestInstanceSG
      IamInstanceProfile: !Ref TestInstanceProfile
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-test-instance-${Environment}'

Outputs:
  VpcId:
    Value: !Ref WorkloadVPC
    Export:
      Name: !Sub '${StackPrefix}-workload-vpc-id-${Environment}'
  
  PrivateSubnetId:
    Value: !Ref PrivateSubnet
    Export:
      Name: !Sub '${StackPrefix}-private-subnet-id-${Environment}'
  
  PrivateRouteTableId:
    Value: !Ref PrivateRouteTable
    Export:
      Name: !Sub '${StackPrefix}-private-rt-id-${Environment}'
  
  TestInstanceId:
    Value: !Ref TestInstance
    Export:
      Name: !Sub '${StackPrefix}-test-instance-id-${Environment}'
  
  TestInstanceSGId:
    Value: !Ref TestInstanceSG
    Export:
      Name: !Sub '${StackPrefix}-test-sg-id-${Environment}'
EOF

aws cloudformation deploy \
    --template-file /tmp/spoke-vpc-test.yaml \
    --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --parameter-overrides StackPrefix=${STACK_PREFIX} Environment=${ENVIRONMENT} \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $REGION \
    --profile $PROFILE

log_info "Workload VPC created successfully"

# Get outputs
VPC_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
PRIVATE_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
TEST_INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs[?OutputKey==`TestInstanceId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)

log_info "VPC ID: $VPC_ID"
log_info "Private Subnet: $PRIVATE_SUBNET_ID"
log_info "Test Instance: $TEST_INSTANCE_ID"

# ============================================================================
# STEP 2: Create VPC Lattice Service Network VPC Association
# ============================================================================
log_info "Step 2: Creating VPC Lattice Service Network VPC Association..."

# Check if association already exists
EXISTING_ASSOC=$(aws vpc-lattice list-service-network-vpc-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?vpcId=='${VPC_ID}'].id" --output text \
    --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_ASSOC" ] && [ "$EXISTING_ASSOC" != "None" ] && [ "$EXISTING_ASSOC" != "" ]; then
    VPC_ASSOC_ID=$EXISTING_ASSOC
    log_info "Using existing VPC Association: $VPC_ASSOC_ID"
else
    # Create VPC Association
    VPC_ASSOC_RESULT=$(aws vpc-lattice create-service-network-vpc-association \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --vpc-identifier $VPC_ID \
        --region $REGION \
        --profile $PROFILE 2>&1)
    
    if [ $? -eq 0 ]; then
        VPC_ASSOC_ID=$(echo "$VPC_ASSOC_RESULT" | jq -r '.id')
        log_info "Created VPC Association: $VPC_ASSOC_ID"
    else
        log_error "Failed to create VPC Association: $VPC_ASSOC_RESULT"
        exit 1
    fi
fi

# Wait for association to be active
log_info "Waiting for VPC Association to become active..."
while true; do
    STATUS=$(aws vpc-lattice get-service-network-vpc-association \
        --service-network-vpc-association-identifier $VPC_ASSOC_ID \
        --query 'status' --output text \
        --region $REGION --profile $PROFILE)
    
    if [ "$STATUS" == "ACTIVE" ]; then
        log_info "VPC Association is active"
        break
    elif [ "$STATUS" == "CREATE_FAILED" ] || [ "$STATUS" == "DELETE_IN_PROGRESS" ]; then
        log_error "VPC Association failed (status: $STATUS)"
        exit 1
    fi
    log_info "Association status: $STATUS - waiting..."
    sleep 5
done

# ============================================================================
# STEP 3: Associate with Hub's Private Hosted Zones (Cross-Account)
# ============================================================================
log_info "Step 3: Associating with Hub's Private Hosted Zones..."

# Get PHZ IDs from hub outputs
SSM_PHZ_ID="${SSM_PHZ_ID:-}"
SSMMSG_PHZ_ID="${SSMMSG_PHZ_ID:-}"
EC2MSG_PHZ_ID="${EC2MSG_PHZ_ID:-}"
STS_PHZ_ID="${STS_PHZ_ID:-}"

if [ -z "$SSM_PHZ_ID" ] || [ -z "$SSMMSG_PHZ_ID" ] || [ -z "$EC2MSG_PHZ_ID" ] || [ -z "$STS_PHZ_ID" ]; then
    log_error "PHZ IDs not found in hub outputs"
    exit 1
fi

log_info "Hub PHZ IDs:"
log_info "  SSM: $SSM_PHZ_ID"
log_info "  SSM Messages: $SSMMSG_PHZ_ID"
log_info "  EC2 Messages: $EC2MSG_PHZ_ID"
log_info "  STS: $STS_PHZ_ID"

# Function to associate VPC with hub's PHZ (cross-account)
associate_with_hub_phz() {
    local PHZ_ID=$1
    local SERVICE_NAME=$2
    
    echo >&2 "[INFO] Associating VPC with hub PHZ for $SERVICE_NAME..."
    
    # Step 1: Hub account authorizes this VPC
    aws route53 create-vpc-association-authorization \
        --hosted-zone-id "$PHZ_ID" \
        --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
        --profile $HUB_PROFILE 2>/dev/null || true
    
    # Step 2: This account associates its VPC with the hub's PHZ
    local ASSOC_RESULT=$(aws route53 associate-vpc-with-hosted-zone \
        --hosted-zone-id "$PHZ_ID" \
        --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
        --profile $PROFILE 2>&1)
    
    if [ $? -ne 0 ]; then
        if echo "$ASSOC_RESULT" | grep -q "already associated"; then
            echo >&2 "[INFO] VPC already associated with $SERVICE_NAME PHZ"
        else
            echo >&2 "[WARN] PHZ association issue: $ASSOC_RESULT"
        fi
    else
        echo >&2 "[INFO] VPC associated with $SERVICE_NAME PHZ"
    fi
    
    # Step 3: Delete the authorization (cleanup)
    aws route53 delete-vpc-association-authorization \
        --hosted-zone-id "$PHZ_ID" \
        --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
        --profile $HUB_PROFILE 2>/dev/null || true
}

# Associate with each hub PHZ
associate_with_hub_phz "$SSM_PHZ_ID" "ssm"
associate_with_hub_phz "$SSMMSG_PHZ_ID" "ssmmessages"
associate_with_hub_phz "$EC2MSG_PHZ_ID" "ec2messages"
associate_with_hub_phz "$STS_PHZ_ID" "sts"

log_info "PHZ associations complete"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "============================================================================"
echo "SPOKE TEST ACCOUNT SETUP COMPLETE (SIMPLIFIED)"
echo "============================================================================"
echo ""
echo "Resources Created:"
echo "  - Workload VPC: $VPC_ID (CIDR: 10.0.0.0/16)"
echo "  - Private Subnet: $PRIVATE_SUBNET_ID"
echo "  - Test Instance: $TEST_INSTANCE_ID"
echo "  - VPC Association: $VPC_ASSOC_ID"
echo ""
echo "Cross-Account PHZ Associations (from Hub):"
echo "  - SSM PHZ: $SSM_PHZ_ID"
echo "  - SSM Messages PHZ: $SSMMSG_PHZ_ID"
echo "  - EC2 Messages PHZ: $EC2MSG_PHZ_ID"
echo "  - STS PHZ: $STS_PHZ_ID"
echo ""
echo "KEY SIMPLIFICATION:"
echo "  - NO Service Network Endpoint needed"
echo "  - NO manual routes needed"
echo "  - VPC Association alone enables Lattice connectivity"
echo ""
echo "============================================================================"
echo " TESTING INSTRUCTIONS"
echo "============================================================================"
echo ""
echo "Connect to the test instance via SSM:"
echo "  aws ssm start-session --target $TEST_INSTANCE_ID --profile $PROFILE --region $REGION"
echo ""
echo "Test DNS resolution:"
echo "  nslookup ssm.${REGION}.amazonaws.com"
echo ""
echo "============================================================================"

# Save outputs
cat > /tmp/spoke-test-outputs.env << ENVEOF
VPC_ID=$VPC_ID
PRIVATE_SUBNET_ID=$PRIVATE_SUBNET_ID
TEST_INSTANCE_ID=$TEST_INSTANCE_ID
VPC_ASSOC_ID=$VPC_ASSOC_ID
ENVEOF

log_info "Outputs saved to /tmp/spoke-test-outputs.env"
