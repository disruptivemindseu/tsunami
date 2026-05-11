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
- **description**: Optional VM description (displayed in Xen Orchestra; automatically adds `fqdn:<FQDN>` tag)
- **name**: Optional VM name in Xen Orchestra (if not set, the YAML key is used)

Example:

```yaml
vm1.example.com:
  # Optional: override the VM name in Xen Orchestra (defaults to "vm1.example.com" if not set)
  # name: "application-server"
  description: Primary application server
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

To generate password hashes, use one of these methods:

**Option 1: Using mkpasswd (simpler)**
```bash
mkpasswd --method=sha-512
```

**Option 2: Using Python**
```bash
python3 -c 'import crypt; print(crypt.crypt("your-password", crypt.METHOD_SHA512))'
```

Copy the example file:

```bash
cp config/local_users.yml.example config/local_users.yml
```

**When using custom users**: After VMs are created, the template user is deleted. You must create an Ansible inventory file manually with your custom user credentials (see section below).

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
8. Extract VM IP addresses and credentials (if no custom users)
9. **Clean old host keys from `~/.ssh/known_hosts`** (handles IP reuse automatically)
10. Run Ansible playbooks for post-provisioning (if using default template user):
    - `remove_cloud_init.yml`: Remove cloud-init and convert to static networking
    - `customize_vm.yml`: Install and configure basic tools

**If custom users are configured** (`local_users.yml` exists):
- Terraform will create VMs with your custom users
- Template user will be deleted
- You'll be prompted to create an `inventory.ini` file with custom credentials
- Playbooks must be run manually with your custom inventory

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

#### With default template user (no local_users.yml):

The tsunami.sh script automatically handles this. The template user credentials are extracted and passed to Ansible.

#### With custom users (local_users.yml configured):

Create an `inventory.ini` file in the project root with your custom user credentials:

```bash
cat > inventory.ini << EOF
# VMs with custom user credentials
192.168.0.102 ansible_user=example_user ansible_ssh_pass=user_password ansible_become_password=user_password ansible_host_key_checking=False
192.168.0.103 ansible_user=example_user ansible_ssh_pass=user_password ansible_become_password=user_password ansible_host_key_checking=False
EOF
```

Then run the playbooks:

```bash
# Remove cloud-init from VMs
ansible-playbook -i inventory.ini ansible/remove_cloud_init.yml

# Customize VMs (install tools, etc.)
ansible-playbook -i inventory.ini ansible/customize_vm.yml
```

**⚠️ Security Note**: The `inventory.ini` file contains credentials and is already added to `.gitignore` to prevent accidental commits.

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

## SSH Authentication and Brute-Force Protection

The deployment process uses the template user credentials for Ansible authentication. The password is automatically extracted from the template name during deployment.

**Template name format**: `template-{PASSWORD}_{TIMESTAMP}`

For example, template `template-debian13-uefi-lvm_20260415091359` yields password `debian13-uefi-lvm`.

To prevent SSH brute-force lockout and allow the system to fully boot:
- **remove_cloud_init.yml** (first playbook): **60-second pause** before first connection
- **customize_vm.yml** (second playbook): No pause (system already booted from first playbook)

This optimizes deployment time while ensuring stable SSH connections.

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
- Installs vim, tmux, and bash-completion

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
- Automatic cleanup of old SSH host keys from `~/.ssh/known_hosts` before running Ansible (handles IP reuse)
- Template password extraction from template name format: `template-{PASSWORD}_{TIMESTAMP}`

## Project Structure

```
tsunami/
├── README.md                                  # This file
├── tsunami.sh                                 # Main orchestration script
├── inventory.ini                              # Ansible inventory (created when using custom users)
├── ansible.cfg                                # Ansible configuration
├── .ansible-lint                              # Ansible linting rules
├── .gitignore                                 # Git ignore patterns
├── config/
│   ├── virtual_machines.yml.example           # VM configuration template
│   ├── virtual_machines.yml                   # VM configuration (created from example)
│   ├── local_users.yml.example                # User configuration template
│   └── local_users.yml                        # User configuration (optional, created from example)
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

**If using default template user (no local_users.yml):**
- Ansible credentials are automatically extracted from the template name
- Playbooks run automatically as part of the infrastructure deployment
- Two playbooks execute:
  1. **remove_cloud_init.yml**: Removes cloud-init and converts to static networking
  2. **customize_vm.yml**: Installs vim, tmux, and bash-completion

**If using custom users (local_users.yml configured):**
- Template user is deleted during VM setup
- You must create an `inventory.ini` file with your custom user credentials
- Run playbooks manually after VMs are created

## Troubleshooting

### Terraform errors

**Provider not found**: Ensure the xenorchestra provider is available. Terraform will auto-download it on `init`.

**Authentication failed**: Check Xen Orchestra credentials in environment variables.

**Resource not found**: Verify that the pool, template, storage repository, and network names in `config/virtual_machines.yml` exist in your Xen Orchestra instance.

### Ansible connectivity

**SSH connection refused or host identification changed**: 
- **Automatic cleanup**: The tsunami.sh script automatically removes old host keys from `~/.ssh/known_hosts` before running Ansible
- Manual cleanup (if needed):
  ```bash
  ssh-keygen -f ~/.ssh/known_hosts -R '185.119.254.123'
  ```
- The first playbook (remove_cloud_init) waits 60 seconds before attempting SSH to allow system boot and prevent brute-force protection
- After VM creation, the second playbook (customize_vm) proceeds immediately since the system is already booted
- Check that VMs have network connectivity
- Verify the template user credentials are correct
- Ensure the password can be extracted from the template name (format: `template-{PASSWORD}_{TIMESTAMP}`)

**Authentication failed for template user**:
- Verify the template user password matches the extracted password from the template name
- Check that password authentication is enabled in SSH
- Run with verbose output to debug: `ansible-playbook -i inventory.ini -vvv playbook.yml`

**Authentication failed with custom users**:
- Verify the custom user credentials in your `inventory.ini` file are correct
- Ensure the user account was created successfully during cloud-init
- Check the user's password and sudo permissions in your `local_users.yml` config
- Verify `ansible_become_password` matches the user's password (needed for sudo access)

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
