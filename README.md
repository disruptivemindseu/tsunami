# Tsunami

Tsunami is an infrastructure automation tool for provisioning and configuring virtual machines on Xen Orchestra. It uses Terraform to define and manage VM resources, and Ansible to handle post-provisioning configuration and customization.

## Overview

Tsunami simplifies the deployment of virtual machines by combining:
- **Terraform**: Infrastructure as Code for VM provisioning on Xen Orchestra
- **Ansible**: Configuration management and post-provisioning customization
- **Cloud-init**: Initial VM setup and network configuration

The tool reads declarative YAML configuration files and automates the entire process of creating, configuring, and preparing VMs for use.

## Prerequisites

- **Terraform**: [Installation guide](https://www.terraform.io/downloads)
- **Ansible**: [Installation guide](https://docs.ansible.com/ansible/latest/installation_guide/)
- **Xen Orchestra**: Access to a running Xen Orchestra instance with configured API credentials
- **Network access**: To the Xen Orchestra API and SSH access to created VMs

## Configuration

### 1. Xen Orchestra Provider

The Xen Orchestra provider is configured via environment variables. Set these before running:

**Using username and password:**

```bash
export XOA_URL="https://your-xen-orchestra-instance.com"
export XOA_USERNAME="your-username"
export XOA_PASSWORD="your-password"
```

**Or using an authentication token (recommended):**

```bash
export XOA_URL="https://your-xen-orchestra-instance.com"
export XOA_TOKEN="your-api-token"
```

**For self-signed certificates (optional):**

```bash
export XOA_INSECURE="true"
```

### 2. Virtual Machines Configuration (`config/virtual_machines.yml`)

Define your virtual machines in YAML format. Each VM must specify:

- **pool**: Xen Orchestra pool name (e.g., "Example Pool")
- **sr**: Storage repository name for VM disks (e.g., "Example Storage")
- **template**: Template name to clone from (e.g., "Debian 13 (cloud-init)")
- **cpus**: Number of CPUs to allocate
- **memory**: Memory in MB to allocate
- **boot_firmware**: Boot firmware type (e.g., "uefi" or "bios")
- **disks**: List of disk configurations with size in GB
- **networks**: List of network configurations with IP, DNS, and gateway settings
- **tags**: Optional tags for VM organization

Example:

```yaml
vm1.example.com:
  boot_firmware: uefi
  cpus: 4
  memory: 8192
  pool: Example Pool
  sr: Example Storage
  template: Debian 13 (cloud-init)
  disks:
    - name: system
      size: 32
  networks:
    - name: Public Network
      ip: 192.168.0.102/24
      ipv6: 2001:db8::11/64
      gateway: 192.168.0.254
      gateway6: 2001:db8::1
      dns_servers:
        - 192.168.0.11
        - 192.168.0.12
      dns_search:
        - example.com
  tags:
    - production
    - web
```

Copy the example file to get started:

```bash
cp config/virtual_machines.yml.example config/virtual_machines.yml
```

### 3. Local Users Configuration (`config/local_users.yml`)

(Optional) Create user accounts on VMs during provisioning:

```yaml
example_user:
  gecos: "Example User"
  shell: "/bin/bash"
  passwd: "$6$examplepwdsalt$examplehashedpassword"
  lock_passwd: false
  ssh_authorized_keys:
    - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACA... example@hostname"
```

To generate password hashes, use:

```bash
python3 -c 'import crypt; print(crypt.crypt("your-password", crypt.METHOD_SHA512))'
```

Copy the example file:

```bash
cp config/local_users.yml.example config/local_users.yml
```

## Usage

### Basic Deployment

Run the main orchestration script:

```bash
./tsunami.sh
```

This will:
1. Validate that Terraform and Ansible are installed
2. Check for required configuration files (`virtual_machines.yml`)
3. Validate the project directory structure
4. Initialize Terraform
5. Show a plan of changes
6. Prompt for confirmation
7. Apply Terraform changes (create VMs)
8. Extract VM IP addresses
9. Run Ansible playbooks for post-provisioning:
   - `remove_cloud_init.yml`: Remove cloud-init and convert to static networking
   - `customize_vm.yml`: Install and configure basic tools

The script includes robust error handling and will provide clear error messages if any validation fails.

### Destroying Infrastructure

To remove all resources:

```bash
./tsunami.sh destroy
```

You'll be prompted to confirm by typing "destroy".

### Terraform Operations

For more control, work directly with Terraform:

```bash
cd terraform

# Initialize Terraform
terraform init

# Plan changes
terraform plan -out=tfplan

# Apply changes
terraform apply tfplan

# Destroy resources
terraform destroy
```

**Note**: The `tsunami.sh` script automates these operations and includes additional validation and error handling.

### Manual Ansible Operations

Run post-provisioning playbooks manually:

```bash
# Remove cloud-init from VMs
ansible-playbook -i "IP1,IP2,IP3," ansible/remove_cloud_init.yml

# Customize VMs (install tools, etc.)
ansible-playbook -i "IP1,IP2,IP3," ansible/customize_vm.yml
```

## Ansible Configuration

The `ansible.cfg` file includes several important settings optimized for this infrastructure:

| Setting | Value | Purpose |
|---------|-------|---------|
| `deprecation_warnings` | false | Reduces noise from deprecated Ansible features |
| `inject_facts_as_vars` | false | Forward compatible with Ansible 2.24+ |
| `interpreter_python` | auto_silent | Auto-detects Python on target hosts |
| `host_key_checking` | false | Allows SSH to new VMs without manual verification |
| `pipelining` | true | Reduces number of SSH operations for faster execution |

Additionally, each playbook includes SSH configuration in its `vars` section:
- `ansible_ssh_common_args: -o StrictHostKeyChecking=false` - Ensures SSH can connect to new VMs without host key verification

These settings together ensure smooth SSH connections to newly provisioned VMs without requiring manual intervention.

## Ansible Playbooks

### `remove_cloud_init.yml`

This playbook:
- Removes cloud-init packages and dependencies
- Parses cloud-init generated network configuration
- Converts cloud-init network config to static Debian `interfaces` format
- Creates proper `/etc/network/interfaces` with IPv4 and IPv6 settings
- Removes cloud-init generated SSH configuration
- Reboots the system and verifies successful removal

Run after VM creation to transition from cloud-init managed networking to standard network configuration.

### `customize_vm.yml`

This playbook:
- Updates the package cache
- Installs vim
- Installs tmux

Customize this playbook to install additional tools, configure services, or perform other setup tasks.

## Script Features and Improvements

### Error Handling and Validation

The `tsunami.sh` script includes comprehensive validation and error handling:

- **Dependency verification**: Checks that Terraform, Ansible, and ansible-playbook are installed
- **Configuration validation**: Verifies required `virtual_machines.yml` exists with helpful setup instructions
- **Directory structure validation**: Ensures all required directories exist
- **IP extraction validation**: Confirms IP addresses are properly extracted from configuration
- **Error traps**: Automatic cleanup of temporary files on error or exit
- **Detailed error messages**: Clear, actionable messages to help troubleshoot issues
- **Exit codes**: Explicit error handling at each critical step with appropriate exit codes

### Command Usage

```bash
./tsunami.sh                 # Default: apply infrastructure
./tsunami.sh apply           # Explicitly apply infrastructure  
./tsunami.sh destroy         # Destroy all managed resources (with confirmation)
```

### Script Improvements

- Uses `/usr/bin/env bash` shebang for maximum portability
- Implements `set -euo pipefail` for strict error handling
- Function-based architecture for maintainability
- Automatic cleanup of Terraform plan files in all scenarios

## Project Structure

```
tsunami/
├── README.md                                  # This file
├── tsunami.sh                                 # Main orchestration script
├── ansible.cfg                                # Ansible configuration
├── .ansible-lint                              # Ansible linting rules
├── config/
│   ├── virtual_machines.yml.example           # VM configuration template
│   └── local_users.yml.example                # User configuration template
├── ansible/
│   ├── remove_cloud_init.yml                  # Playbook: remove cloud-init
│   └── customize_vm.yml                       # Playbook: customize VMs
└── terraform/
    ├── main.tf                                # Terraform configuration
    └── .terraform/                            # Terraform state and providers
```

## How It Works

### 1. Terraform Phase

Terraform reads the VM configuration from `config/virtual_machines.yml` and:
- Queries Xen Orchestra for available pools, templates, networks, and storage
- Generates cloud-init user-data with hostname, network config, and user definitions
- Creates VMs with specified resources (CPU, memory, disks, networks)
- Automatically configures network settings and cloud-init

### 2. IP Extraction Phase

The script parses the VM configuration to extract IP addresses for Ansible.

### 3. Ansible Phase

Ansible connects to each VM (using cloud-init provided networking) and runs two playbooks:
1. **remove_cloud_init.yml**: Removes cloud-init and its dependencies
   - Converts network configuration to standard Linux networking
   - Reboots the system to apply changes
2. **customize_vm.yml**: Optionally customizes the system (installs tools, etc.)
   - Updates package cache
   - Installs vim and tmux

Both playbooks run automatically as part of the infrastructure deployment.

## Troubleshooting

### Terraform errors

**Provider not found**: Ensure the xenorchestra provider is available. Terraform will auto-download it on `init`.

**Authentication failed**: Check Xen Orchestra credentials in environment variables.

**Resource not found**: Verify that the pool, template, storage repository, and network names in `config/virtual_machines.yml` exist in your Xen Orchestra instance.

### Ansible connectivity

**SSH connection refused**: 
- Wait a few seconds after VM creation for SSH to be ready
- Check that VMs have network connectivity
- Verify SSH credentials and key access

**Python not found on target**: Ansible requires Python. Ensure your template includes Python.

### Cloud-init issues

**Network config not parsed**: Check the format of the cloud-init generated network config in `/etc/network/interfaces.d/50-cloud-init`.

**Hostname not set**: Ensure `manage_etc_hosts: true` is set in cloud-init config (done by default).

## Customization

### Adding new VMs

Add entries to `config/virtual_machines.yml` following the example format.

### Creating custom Ansible playbooks

Create new `.yml` files in the `ansible/` directory and reference them in `tsunami.sh` or run them manually.

### Modifying cloud-init configuration

Edit the cloud-config generation in `terraform/main.tf` (locals: cloud_config section).

### Adjusting network configuration

Modify network settings in `terraform/main.tf` (locals: cloud_network_config section) or in individual VM configurations.

## Environment Variables

Xen Orchestra authentication (choose one method):

**Method 1: Username and password**
- `XOA_URL`: Xen Orchestra API URL
- `XOA_USERNAME`: API username
- `XOA_PASSWORD`: API password

**Method 2: Authentication token (recommended)**
- `XOA_URL`: Xen Orchestra API URL
- `XOA_TOKEN`: API token

**Optional:**
- `XOA_INSECURE`: Set to "true" for self-signed certificates

## License

See LICENSE file for details.

## Support

For issues or questions:
- Check the troubleshooting section above
- Review Terraform and Ansible documentation
- Check Xen Orchestra API documentation for provider-specific issues
