terraform {
  required_providers {
    xenorchestra = {
      source = "vatesfr/xenorchestra"
    }
  }
}

provider "xenorchestra" {
}

locals {
  vms        = yamldecode(file("${path.module}/../config/virtual_machines.yml"))
  users_base = fileexists("${path.module}/../config/local_users.yml") ? yamldecode(file("${path.module}/../config/local_users.yml")) : {}
}

locals {
  cloud_config = {
    for vm_name, vm_config in local.vms :
    vm_name => "#cloud-config\n${yamlencode(merge(
      {
        hostname         = split(".", vm_name)[0]
        fqdn             = vm_name
        manage_etc_hosts = true
        ssh_pwauth       = true
        bootcmd = [
          "if [ -f /etc/debian_version ]; then\n    pkill -9 dhcpcd || true\n    echo \"source /etc/network/interfaces.d/*\" > /etc/network/interfaces\n    ip addr flush dev enX0 || true\n    ip route flush dev enX0 || true\n    systemctl restart networking || true\nfi"
        ]
      },
      length(local.users_base) > 0 ? {
        users = [
          for username, user_config in local.users_base : merge(
            user_config,
            {
              name   = username
              groups = can(regex("(?i)(alma|centos|rocky|rhel|fedora)", vm_config.template)) ? "wheel" : "sudo"
            }
          )
        ]
      } : {},
      {
        runcmd = length(local.users_base) > 0 ? [
          "rm -rf /home/template",
          "userdel -r template || true"
        ] : []
      }
    ))}"
  }
}

locals {
  cloud_network_config = {
    for vm_name, vm_config in local.vms :
    vm_name => replace(replace(yamlencode({
      version = 2
      ethernets = {
        for idx, net in vm_config.networks :
        "enX${idx}" => merge(
          {
            dhcp4 = try(net.ip == null, true)
            addresses = concat(
              net.ip != null ? ["${net.ip}"] : [],
              try(net.ipv6, null) != null ? ["${net.ipv6}"] : []
            )
            nameservers = merge(
              {
                addresses = try(net.dns_servers, [])
              },
              try(net.dns_search, null) != null ? { search = net.dns_search } : {}
            )
          },
          try(net.gateway, null) != null ? { gateway4 = net.gateway } : {},
          try(net.ipv6, null) != null ? {
            gateway6 = try(net.gateway6, null)
            dhcp6    = try(net.ipv6 == null, true)
          } : {}
        )
      }
    }), "\"dhcp6\": \"false\"", "\"dhcp6\": false"), "\"dhcp6\": \"true\"", "\"dhcp6\": true")
  }
}

data "xenorchestra_pool" "pool" {
  for_each   = toset([for vm in local.vms : vm.pool])
  name_label = each.value
}

data "xenorchestra_template" "template" {
  for_each   = toset([for vm in local.vms : vm.template])
  name_label = each.value
}

data "xenorchestra_network" "network" {
  for_each   = toset(flatten([for vm in local.vms : [for net in try(vm.networks, []) : net.name]]))
  name_label = each.value
}

data "xenorchestra_sr" "sr" {
  for_each   = toset([for vm in local.vms : vm.sr])
  name_label = each.value
}

resource "xenorchestra_vm" "vm" {
  for_each         = local.vms
  name_label       = each.key
  name_description = each.key
  cpus             = each.value.cpus
  memory_max       = each.value.memory * 1024 * 1024 # Convert MB to bytes
  tags             = try(each.value.tags, [])

  template                            = data.xenorchestra_template.template[each.value.template].id
  clone_type                          = "fast"
  hvm_boot_firmware                   = try(each.value.boot_firmware, "uefi")
  cloud_config                        = local.cloud_config[each.key]
  cloud_network_config                = local.cloud_network_config[each.key]
  destroy_cloud_config_vdi_after_boot = true

  dynamic "network" {
    for_each = try(each.value.networks, [])
    content {
      network_id = data.xenorchestra_network.network[network.value.name].id
    }
  }

  dynamic "disk" {
    for_each = { for idx, disk in each.value.disks : idx => disk }
    content {
      sr_id      = data.xenorchestra_sr.sr[each.value.sr].id
      size       = disk.value.size * 1024 * 1024 * 1024 # Convert GB to bytes
      name_label = "${each.key}_disk${disk.key + 1}"
    }
  }
}
