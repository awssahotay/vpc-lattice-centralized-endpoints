#!/bin/bash
# Centralized VPC Endpoints via VPC Lattice - Deployment Script
#
# Usage:
#   ./deploy.sh --hub-profile <PROFILE> \
#               --spoke-dev-profile <PROFILE> \
#               --spoke-test-profile <PROFILE> \
#               [--region <REGION>] [--prefix <STACK_PREFIX>] \
#               <COMMAND>
#
# Commands:
#   all         - Deploy all resources (hub + both spokes)
#   hub         - Deploy hub account only
#   spoke-dev   - Deploy spoke dev account only
#   spoke-test  - Deploy spoke test account only
#   cleanup     - Delete all resources
#   status      - Show deployment status

set -e

# Default values
REGION="us-east-2"
STACK_PREFIX="central-vpce"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "${BLUE}=== $1 ===${NC}"; }

# Parse arguments
HUB_PROFILE=""
SPOKE_DEV_PROFILE=""
SPOKE_TEST_PROFILE=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --hub-profile)
            HUB_PROFILE="$2"
            shift 2
            ;;
        --spoke-dev-profile)
            SPOKE_DEV_PROFILE="$2"
            shift 2
            ;;
        --spoke-test-profile)
            SPOKE_TEST_PROFILE="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --prefix)
            STACK_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] COMMAND"
            echo ""
            echo "Options:"
            echo "  --hub-profile         AWS CLI profile for hub/endpoint account"
            echo "  --spoke-dev-profile   AWS CLI profile for spoke dev account"
            echo "  --spoke-test-profile  AWS CLI profile for spoke test account"
            echo "  --region              AWS region (default: us-east-2)"
            echo "  --prefix              Stack prefix (default: central-vpce)"
            echo ""
            echo "Commands:"
            echo "  all         Deploy all resources"
            echo "  hub         Deploy hub account only"
            echo "  spoke-dev   Deploy spoke dev account only"
            echo "  spoke-test  Deploy spoke test account only"
            echo "  cleanup     Delete all resources"
            echo "  status      Show deployment status"
            exit 0
            ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Get account ID from profile
get_account_id() {
    local profile="$1"
    aws sts get-caller-identity --profile "$profile" --query 'Account' --output text 2>/dev/null
}

# Validate parameters
validate_hub_params() {
    if [[ -z "$HUB_PROFILE" ]]; then
        log_error "Missing --hub-profile"
        exit 1
    fi
    if [[ -z "$SPOKE_DEV_PROFILE" ]] || [[ -z "$SPOKE_TEST_PROFILE" ]]; then
        log_error "Missing --spoke-dev-profile or --spoke-test-profile (needed for RAM sharing)"
        exit 1
    fi
}

validate_spoke_dev_params() {
    if [[ -z "$SPOKE_DEV_PROFILE" ]]; then
        log_error "Missing --spoke-dev-profile"
        exit 1
    fi
}

validate_spoke_test_params() {
    if [[ -z "$SPOKE_TEST_PROFILE" ]]; then
        log_error "Missing --spoke-test-profile"
        exit 1
    fi
}

validate_all_params() {
    if [[ -z "$HUB_PROFILE" ]]; then
        log_error "Missing --hub-profile"
        exit 1
    fi
    validate_spoke_dev_params
    validate_spoke_test_params
}

# Export environment variables for child scripts
export_env() {
    export VPCE_REGION="$REGION"
    export VPCE_STACK_PREFIX="$STACK_PREFIX"
    export VPCE_HUB_PROFILE="$HUB_PROFILE"
    export VPCE_SPOKE_DEV_PROFILE="$SPOKE_DEV_PROFILE"
    export VPCE_SPOKE_TEST_PROFILE="$SPOKE_TEST_PROFILE"
    
    if [[ -n "$SPOKE_DEV_PROFILE" ]]; then
        export VPCE_SPOKE_DEV_ACCOUNT=$(get_account_id "$SPOKE_DEV_PROFILE")
    fi
    if [[ -n "$SPOKE_TEST_PROFILE" ]]; then
        export VPCE_SPOKE_TEST_ACCOUNT=$(get_account_id "$SPOKE_TEST_PROFILE")
    fi
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Command handlers
run_hub() {
    log_header "Deploying Hub Account (Centralized Endpoints)"
    validate_hub_params
    export_env
    "$SCRIPT_DIR/01-hub-account.sh"
}

run_spoke_dev() {
    log_header "Deploying Spoke Dev Account"
    validate_spoke_dev_params
    export_env
    "$SCRIPT_DIR/02-spoke-dev.sh"
}

run_spoke_test() {
    log_header "Deploying Spoke Test Account"
    validate_spoke_test_params
    export_env
    "$SCRIPT_DIR/03-spoke-test.sh"
}

run_all() {
    log_header "Deploying All Resources"
    validate_all_params
    export_env
    
    log_info "Step 1/3: Hub Account (Centralized Endpoints)"
    "$SCRIPT_DIR/01-hub-account.sh"
    
    log_info "Step 2/3: Spoke Dev Account"
    "$SCRIPT_DIR/02-spoke-dev.sh"
    
    log_info "Step 3/3: Spoke Test Account"
    "$SCRIPT_DIR/03-spoke-test.sh"
    
    log_info "All deployments complete!"
}

run_cleanup() {
    log_header "Cleaning Up All Resources"
    validate_all_params
    export_env
    "$SCRIPT_DIR/cleanup.sh"
}

run_status() {
    log_header "Deployment Status"
    
    echo ""
    log_info "Hub Account Resources:"
    if [[ -n "$HUB_PROFILE" ]]; then
        echo "  CloudFormation Stacks:"
        aws cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
            --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].{Name:StackName,Status:StackStatus}" \
            --output table --region "$REGION" --profile "$HUB_PROFILE" 2>/dev/null || echo "    None found"
        
        echo "  VPC Lattice Service Networks:"
        aws vpc-lattice list-service-networks \
            --query "items[?contains(name, '${STACK_PREFIX}')].{Name:name,Id:id}" \
            --output table --region "$REGION" --profile "$HUB_PROFILE" 2>/dev/null || echo "    None found"
        
        echo "  VPC Endpoints:"
        aws ec2 describe-vpc-endpoints \
            --filters "Name=tag:Name,Values=*${STACK_PREFIX}*" \
            --query "VpcEndpoints[*].{Service:ServiceName,State:State}" \
            --output table --region "$REGION" --profile "$HUB_PROFILE" 2>/dev/null || echo "    None found"
    else
        echo "  (--hub-profile not provided)"
    fi
    
    echo ""
    log_info "Spoke Dev Account Resources:"
    if [[ -n "$SPOKE_DEV_PROFILE" ]]; then
        aws cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
            --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].{Name:StackName,Status:StackStatus}" \
            --output table --region "$REGION" --profile "$SPOKE_DEV_PROFILE" 2>/dev/null || echo "    None found"
    else
        echo "  (--spoke-dev-profile not provided)"
    fi
    
    echo ""
    log_info "Spoke Test Account Resources:"
    if [[ -n "$SPOKE_TEST_PROFILE" ]]; then
        aws cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
            --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].{Name:StackName,Status:StackStatus}" \
            --output table --region "$REGION" --profile "$SPOKE_TEST_PROFILE" 2>/dev/null || echo "    None found"
    else
        echo "  (--spoke-test-profile not provided)"
    fi
}

# Main
if [[ -z "$COMMAND" ]]; then
    log_error "No command specified. Use --help for usage."
    exit 1
fi

case "$COMMAND" in
    all)
        run_all
        ;;
    hub)
        run_hub
        ;;
    spoke-dev)
        run_spoke_dev
        ;;
    spoke-test)
        run_spoke_test
        ;;
    cleanup)
        run_cleanup
        ;;
    status)
        run_status
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        log_error "Use --help for usage."
        exit 1
        ;;
esac
