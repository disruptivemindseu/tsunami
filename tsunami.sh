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
ANSIBLE_INVENTORY=""

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
    if [ -f "$ANSIBLE_INVENTORY" ]; then
        rm -f "$ANSIBLE_INVENTORY"
    fi
}

# Extract password from template name
# Template name format: template-{PASSWORD}_{TIMESTAMP}
extract_template_password() {
    local template_name="$1"
    echo "$template_name" | sed 's/^template-//' | sed 's/_[0-9]*$//'
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

    # Check if custom users are configured
    if [ -f "$CONFIG_DIR/local_users.yml" ]; then
        echo "⚠️  WARNING: Custom users configured (local_users.yml exists)"
        echo "   Template user will be DELETED during VM setup"
        echo "   You must create an Ansible inventory file with your custom user credentials:"
        echo ""
        echo "   Create inventory file (e.g., inventory.ini):"
        echo "   ---"
        echo "   192.168.1.10 ansible_user=myuser ansible_ssh_pass=mypassword ansible_become_password=mypassword"
        echo "   192.168.1.11 ansible_user=myuser ansible_ssh_pass=mypassword ansible_become_password=mypassword"
        echo "   ---"
        echo ""
        echo "   Then run playbooks:"
        echo "   ansible-playbook -i inventory.ini $SCRIPT_DIR/ansible/remove_cloud_init.yml"
        echo "   ansible-playbook -i inventory.ini $SCRIPT_DIR/ansible/customize_vm.yml"
        echo ""
        read -rp "Continue with manual Ansible setup? (yes/no): " confirmation
        if [[ ! $confirmation =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Deployment cancelled."
            exit 0
        fi
        ANSIBLE_INVENTORY=""
    else
        # Extract template name and derive password
        echo "Extracting template information..."
        TEMPLATE_NAME=$(grep "template:" "$CONFIG_DIR/virtual_machines.yml" | head -1 | awk '{print $2}')
        TEMPLATE_PASSWORD=$(extract_template_password "$TEMPLATE_NAME")
        echo "  Template: $TEMPLATE_NAME"
        echo "  Username: template"
        echo "  Password: $TEMPLATE_PASSWORD"

        # Extract IPs and run Ansible playbook
        echo "Extracting VM IP addresses..."
        IPS=$(grep -E "^\s+ip:\s+" "$CONFIG_DIR/virtual_machines.yml" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")

        if [ -z "$IPS" ]; then
            echo "❌ Error: No IP addresses found in virtual_machines.yml" >&2
            echo "   Expected format: '      ip: 192.168.1.10'" >&2
            exit 1
        fi

        echo "  Found IPs: $(echo "$IPS" | tr '\n' ' ')"

        # Clean old host keys from known_hosts (for reused IPs)
        echo "Cleaning old host keys from ~/.ssh/known_hosts..."
        for ip in $(echo "$IPS" | tr '\n' ' '); do
            ssh-keygen -f ~/.ssh/known_hosts -R "$ip" 2>/dev/null || true
        done

        # Create temporary Ansible inventory with credentials
        ANSIBLE_INVENTORY=$(mktemp)
        for ip in $(echo "$IPS" | tr '\n' ' '); do
            echo "$ip ansible_user=template ansible_ssh_pass=$TEMPLATE_PASSWORD ansible_become_password=$TEMPLATE_PASSWORD ansible_host_key_checking=False" >> "$ANSIBLE_INVENTORY"
        done
    fi

    if [ -n "$ANSIBLE_INVENTORY" ]; then
        echo ""
        echo "Running Ansible playbooks..."

        # Run remove_cloud_init playbook
        echo "  • Running remove_cloud_init playbook..."
        if ! ansible-playbook -i "$ANSIBLE_INVENTORY" "$SCRIPT_DIR/ansible/remove_cloud_init.yml"; then
            echo "❌ Error: remove_cloud_init playbook failed" >&2
            exit 1
        fi
        echo "  ✅ remove_cloud_init completed"

        echo ""

        # Run customize_vm playbook
        echo "  • Running customize_vm playbook..."
        if ! ansible-playbook -i "$ANSIBLE_INVENTORY" "$SCRIPT_DIR/ansible/customize_vm.yml"; then
            echo "❌ Error: customize_vm playbook failed" >&2
            exit 1
        fi
        echo "  ✅ customize_vm completed"

        echo ""
        echo "✅ All Ansible playbooks completed successfully!"
    else
        echo ""
        echo "⏭️  Skipping automated Ansible playbooks (custom users configured)"
        echo "   Run manually when ready:"
        echo "   ansible-playbook -i <inventory> $SCRIPT_DIR/ansible/remove_cloud_init.yml"
        echo "   ansible-playbook -i <inventory> $SCRIPT_DIR/ansible/customize_vm.yml"
    fi
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

