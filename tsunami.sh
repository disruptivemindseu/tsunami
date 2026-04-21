#!/usr/bin/env bash

set -euo pipefail

# Error handling
trap 'cleanup_on_error' ERR
trap 'cleanup_on_exit' EXIT

# Global variables
SCRIPT_DIR=""
TERRAFORM_DIR=""
CONFIG_DIR=""
TFPLAN_FILE=""
CLEANUP_TFPLAN=0

cleanup_on_error() {
    local line_number=$?
    echo "❌ Error: Script failed at line $line_number" >&2
    if [ -f "$TFPLAN_FILE" ] && [ "$CLEANUP_TFPLAN" -eq 1 ]; then
        echo "Cleaning up Terraform plan file..." >&2
        rm -f "$TFPLAN_FILE"
    fi
    exit 1
}

cleanup_on_exit() {
    if [ "$CLEANUP_TFPLAN" -eq 1 ] && [ -f "$TFPLAN_FILE" ]; then
        rm -f "$TFPLAN_FILE"
    fi
}

# Check if command exists
check_command() {
    local cmd="$1"
    local url="$2"
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Error: '$cmd' is not installed or not in PATH" >&2
        echo "Please install from: $url" >&2
        exit 1
    fi
}

# Validate file existence
validate_file() {
    local file="$1"
    local required="${2:-true}"
    if [ ! -f "$file" ]; then
        if [ "$required" = "true" ]; then
            echo "❌ Error: Required file not found: $file" >&2
            echo "Please create it from the example:" >&2
            echo "  cp ${file}.example $file" >&2
            exit 1
        else
            echo "⚠️  Warning: Optional file not found: $file" >&2
            return 1
        fi
    fi
    return 0
}

# Initialize script
initialize() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TERRAFORM_DIR="$SCRIPT_DIR/terraform"
    CONFIG_DIR="$SCRIPT_DIR/config"
    TFPLAN_FILE="$TERRAFORM_DIR/tfplan"

    # Validate directories exist
    if [ ! -d "$TERRAFORM_DIR" ]; then
        echo "❌ Error: Terraform directory not found: $TERRAFORM_DIR" >&2
        exit 1
    fi
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "❌ Error: Config directory not found: $CONFIG_DIR" >&2
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    check_command "terraform" "https://www.terraform.io/downloads"
    check_command "ansible" "https://docs.ansible.com/ansible/latest/installation_guide/"
    check_command "ansible-playbook" "https://docs.ansible.com/ansible/latest/installation_guide/"
}

# Validate configuration files
validate_configs() {
    validate_file "$CONFIG_DIR/virtual_machines.yml" "true" || exit 1
    validate_file "$CONFIG_DIR/local_users.yml" "false" || true
}

# Run Terraform destroy
run_destroy() {
    echo "⚠️  WARNING: You are about to destroy all Terraform-managed resources!"
    read -rp "Type 'destroy' to confirm: " confirmation
    echo
    if [ "$confirmation" != "destroy" ]; then
        echo "Destroy cancelled."
        exit 0
    fi

    echo "Running terraform destroy..."
    if ! terraform destroy; then
        echo "❌ Error: Terraform destroy failed" >&2
        exit 1
    fi
    echo "✅ Resources destroyed successfully"
}

# Run Terraform apply
run_apply() {
    echo "Initializing Terraform..."
    if ! terraform init > /dev/null 2>&1; then
        echo "❌ Error: Terraform init failed" >&2
        exit 1
    fi

    echo "Planning Terraform changes..."
    if ! terraform plan -out="$TFPLAN_FILE" > /dev/null 2>&1; then
        echo "❌ Error: Terraform plan failed" >&2
        exit 1
    fi

    echo ""
    echo "Ready to apply changes:"
    terraform show "$TFPLAN_FILE"
    echo ""

    read -rp "Do you want to apply these changes? (yes/no): " confirmation
    echo
    if [[ ! $confirmation =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Terraform apply cancelled."
        rm -f "$TFPLAN_FILE"
        exit 0
    fi

    CLEANUP_TFPLAN=1

    if ! terraform apply "$TFPLAN_FILE"; then
        echo "❌ Error: Terraform apply failed" >&2
        exit 1
    fi

    rm -f "$TFPLAN_FILE"
    CLEANUP_TFPLAN=0
    echo "✅ Terraform apply completed successfully!"
    echo ""

    # Extract IPs and run Ansible playbook
    echo "Extracting VM IP addresses..."
    if ! IPS=$(grep -A 10 "networks:" "$CONFIG_DIR/virtual_machines.yml" | grep "ip:" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}"); then
        echo "❌ Error: Failed to extract IP addresses from configuration" >&2
        exit 1
    fi

    if [ -z "$IPS" ]; then
        echo "❌ Error: No IP addresses found in virtual_machines.yml" >&2
        exit 1
    fi

    # Format IPs for Ansible inventory (comma-separated)
    IPS_COMMA=$(echo "$IPS" | tr '\n' ',' | sed 's/,$//')

    echo ""
    echo "Running Ansible playbooks..."

    # Run remove_cloud_init playbook
    echo "  • Running remove_cloud_init playbook..."
    if ! ansible-playbook -i "$IPS_COMMA," "$SCRIPT_DIR/ansible/remove_cloud_init.yml"; then
        echo "❌ Error: remove_cloud_init playbook failed" >&2
        exit 1
    fi
    echo "  ✅ remove_cloud_init completed"

    echo ""

    # Run customize_vm playbook
    echo "  • Running customize_vm playbook..."
    if ! ansible-playbook -i "$IPS_COMMA," "$SCRIPT_DIR/ansible/customize_vm.yml"; then
        echo "❌ Error: customize_vm playbook failed" >&2
        exit 1
    fi
    echo "  ✅ customize_vm completed"

    echo ""
    echo "✅ All Ansible playbooks completed successfully!"
}

# Main execution
main() {
    initialize
    check_dependencies
    validate_configs

    local command="${1:-apply}"

    cd "$TERRAFORM_DIR" || exit 1

    case "$command" in
        destroy)
            run_destroy
            ;;
        apply)
            run_apply
            ;;
        *)
            echo "❌ Error: Unknown command '$command'" >&2
            echo "Usage: $0 [apply|destroy]" >&2
            exit 1
            ;;
    esac
}

main "$@"

