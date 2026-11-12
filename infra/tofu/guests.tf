# The lab's guests, imported from Proxmox. Change them here, not in its UI.
# prevent_destroy stands until a person removes it for one named guest.

resource "proxmox_virtual_environment_container" "themis" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "themis - see homelab/dns\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 4
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "themis"
    dns {
      domain  = "home"
      servers = ["192.168.8.1"]
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 512
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:DA:9B:4B"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "delphi" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "delphi - see homelab/dns\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 2
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 8
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "delphi"
    dns {
      domain  = "home"
      servers = ["192.168.8.1"]
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 6144
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:7D:3B:06"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "navidrome" {
  delete_unreferenced_disks_on_destroy = false
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 2
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "local-zfs"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 8
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "navidrome"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 1024
    swap      = 512
  }
  mount_point {
    acl           = false
    backup        = false
    mount_options = []
    path          = "/var/media"
    quota         = false
    read_only     = false
    replicate     = true
    shared        = false
    volume        = "/hddpool/media"
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = true
    host_managed = false
    mac_address  = "BC:24:11:D8:D6:21"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_vm" "hermes" {
  acpi                                 = true
  bios                                 = "seabios"
  boot_order                           = ["scsi0"]
  delete_unreferenced_disks_on_destroy = true
  description                          = "hermes - mailcow for the Proxmox labs, see homelab/hermes"
  keyboard_layout                      = "en-us"
  machine                              = "q35"
  migrate                              = false
  name                                 = "hermes"
  network_device {
    bridge       = "vmbr0"
    disconnected = false
    firewall     = false
    mac_address  = "BC:24:11:1B:5D:14"
    model        = "virtio"
    mtu          = 0
    queues       = 0
    rate_limit   = 0
    vlan_id      = 0
  }
  node_name           = "lenora"
  on_boot             = false
  pool_id             = "Infrastructure"
  protection          = false
  purge_on_destroy    = true
  reboot              = false
  reboot_after_update = true
  scsi_hardware       = "virtio-scsi-single"
  started             = false
  stop_on_destroy     = false
  tablet_device       = true
  tags                = []
  template            = false
  timeout_clone       = 1800
  timeout_create      = 1800
  timeout_migrate     = 1800
  timeout_reboot      = 1800
  timeout_shutdown_vm = 1800
  timeout_start_vm    = 1800
  timeout_stop_vm     = 300
  vm_id               = 109
  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }
  cpu {
    cores      = 2
    flags      = []
    hotplugged = 0
    limit      = 0
    numa       = false
    sockets    = 1
    type       = "host"
  }
  disk {
    aio               = "io_uring"
    backup            = true
    cache             = "none"
    datastore_id      = "ssdpool"
    discard           = "on"
    file_format       = "raw"
    interface         = "scsi0"
    iothread          = true
    path_in_datastore = "vm-109-disk-0"
    queues            = 0
    replicate         = true
    size              = 40
    ssd               = true
  }
  initialization {
    datastore_id = "ssdpool"
    interface    = "ide2"
    upgrade      = true
    dns {
      domain = "home"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
      ipv6 {
        address = "auto"
      }
    }
    user_account {
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW5phwQWtosKuBdP6pzX6EwenL9jLuMTPWL0tq9tiii peet@mbp", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOdQ066rf4GAQliNffyKmUHRAKpnODAmZeE83yo7ybU peet@mba"]
      username = "debian"
    }
  }
  memory {
    dedicated      = 6144
    floating       = 0
    keep_hugepages = false
    shared         = 0
  }
  operating_system {
    type = "l26"
  }
  serial_device {
    device = "socket"
  }
  vga {
    memory = 16
    type   = "serial0"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_virtual_environment_container" "jellyfin" {
  delete_unreferenced_disks_on_destroy = false
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 8
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 32
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "jellyfin"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 8192
    swap      = 512
  }
  mount_point {
    acl           = false
    backup        = false
    mount_options = []
    path          = "/var/media"
    quota         = false
    read_only     = true
    replicate     = true
    shared        = false
    volume        = "/hddpool/media"
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = true
    host_managed = false
    mac_address  = "BC:24:11:E5:B1:3B"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "pistis" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "pistis - smallstep CA, see homelab/ca\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 2
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 8
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "pistis"
    dns {
      domain = "home"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 1024
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:04:F7:03"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "loki" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "loki - Loki log store, see homelab/loki\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 2
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 20
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "loki"
    dns {
      domain = "home"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 2048
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:5E:A6:45"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "pythia" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "pythia - see homelab/dns\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 4
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "pythia"
    dns {
      domain  = "home"
      servers = ["192.168.8.1"]
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 512
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:06:D9:87"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "moby" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "moby - Docker container host, see homelab/moby\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 8
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 80
  }
  features {
    fuse    = false
    keyctl  = true
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "moby"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 16384
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = true
    host_managed = false
    mac_address  = "BC:24:11:13:54:B8"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "forgejo" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "forgejo - Forgejo, see homelab/forgejo\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 4
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 32
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "forgejo"
    dns {
      domain = "home"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 4096
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = true
    host_managed = false
    mac_address  = "BC:24:11:14:EC:A4"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "talos" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "Talos: a deploy runner, with checks that gate publishing to GitHub\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 4
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 16
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "talos"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 4096
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:21:4D:0D"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_vm" "homeassistant" {
  acpi                                 = true
  bios                                 = "ovmf"
  boot_order                           = ["scsi0"]
  delete_unreferenced_disks_on_destroy = true
  description                          = "Home Assistant OS 18.3. 192.168.1.90 static, IPv6 SLAAC (set inside HAOS)."
  keyboard_layout                      = "en-us"
  machine                              = "q35"
  migrate                              = false
  name                                 = "homeassistant"
  network_device {
    bridge       = "vmbr0"
    disconnected = false
    firewall     = true
    mac_address  = "BC:24:11:A3:34:EA"
    model        = "virtio"
    mtu          = 0
    queues       = 0
    rate_limit   = 0
    vlan_id      = 0
  }
  node_name           = "lenora"
  on_boot             = true
  pool_id             = "Production"
  protection          = false
  purge_on_destroy    = true
  reboot              = false
  reboot_after_update = true
  scsi_hardware       = "virtio-scsi-single"
  started             = true
  stop_on_destroy     = false
  tablet_device       = false
  tags                = []
  template            = false
  timeout_clone       = 1800
  timeout_create      = 1800
  timeout_migrate     = 1800
  timeout_reboot      = 1800
  timeout_shutdown_vm = 1800
  timeout_start_vm    = 1800
  timeout_stop_vm     = 300
  vm_id               = 302
  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }
  cpu {
    cores      = 4
    flags      = []
    hotplugged = 0
    limit      = 0
    numa       = false
    sockets    = 1
    type       = "host"
  }
  disk {
    aio               = "io_uring"
    backup            = true
    cache             = "none"
    datastore_id      = "ssdpool"
    discard           = "on"
    file_format       = "raw"
    interface         = "scsi0"
    iothread          = true
    path_in_datastore = "vm-302-disk-1"
    queues            = 0
    replicate         = true
    size              = 64
    ssd               = true
  }
  efi_disk {
    datastore_id      = "ssdpool"
    file_format       = "raw"
    pre_enrolled_keys = false
    type              = "4m"
  }
  memory {
    dedicated      = 8192
    floating       = 0
    keep_hugepages = false
    shared         = 0
  }
  operating_system {
    type = "l26"
  }
  usb {
    host = "10c4:ea60"
    usb3 = false
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_virtual_environment_container" "grafana" {
  delete_unreferenced_disks_on_destroy = false
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 8
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "grafana"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 1024
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:8F:A8:C9"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_vm" "metis" {
  acpi                                 = true
  bios                                 = "seabios"
  boot_order                           = ["scsi0"]
  delete_unreferenced_disks_on_destroy = true
  description                          = "metis - Ollama on the Quadro P2200 for the job search pipelines, see homelab/metis"
  keyboard_layout                      = "en-us"
  machine                              = "q35"
  migrate                              = false
  name                                 = "metis"
  network_device {
    bridge       = "vmbr0"
    disconnected = false
    firewall     = false
    mac_address  = "BC:24:11:6E:7A:19"
    model        = "virtio"
    mtu          = 0
    queues       = 0
    rate_limit   = 0
    vlan_id      = 0
  }
  node_name           = "lenora"
  on_boot             = true
  pool_id             = "Infrastructure"
  protection          = false
  purge_on_destroy    = true
  reboot              = false
  reboot_after_update = true
  scsi_hardware       = "virtio-scsi-single"
  started             = true
  stop_on_destroy     = false
  tablet_device       = true
  tags                = []
  template            = false
  timeout_clone       = 1800
  timeout_create      = 1800
  timeout_migrate     = 1800
  timeout_reboot      = 1800
  timeout_shutdown_vm = 1800
  timeout_start_vm    = 1800
  timeout_stop_vm     = 300
  vm_id               = 110
  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }
  cpu {
    cores      = 8
    flags      = []
    hotplugged = 0
    limit      = 0
    numa       = false
    sockets    = 1
    type       = "host"
  }
  disk {
    aio               = "io_uring"
    backup            = true
    cache             = "none"
    datastore_id      = "ssdpool"
    discard           = "on"
    file_format       = "raw"
    interface         = "scsi0"
    iothread          = true
    path_in_datastore = "vm-110-disk-0"
    queues            = 0
    replicate         = true
    size              = 80
    ssd               = true
  }
  hostpci {
    device  = "hostpci0"
    mapping = "uc1-gpu"
    pcie    = true
    rombar  = false
    xvga    = false
  }
  initialization {
    datastore_id = "ssdpool"
    interface    = "ide2"
    upgrade      = true
    dns {
      domain = "home"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    user_account {
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW5phwQWtosKuBdP6pzX6EwenL9jLuMTPWL0tq9tiii peet@mbp", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOdQ066rf4GAQliNffyKmUHRAKpnODAmZeE83yo7ybU peet@mba"]
      username = "debian"
    }
  }
  memory {
    dedicated      = 16384
    floating       = 0
    keep_hugepages = false
    shared         = 0
  }
  operating_system {
    type = "l26"
  }
  serial_device {
    device = "socket"
  }
  vga {
    memory = 16
    type   = "serial0"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_virtual_environment_container" "lexie" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "General tooling and shell server\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 4
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = ["noatime"]
    quota         = false
    replicate     = false
    size          = 150
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "lexie"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 4096
    swap      = 512
  }
  mount_point {
    acl           = false
    backup        = false
    mount_options = []
    path          = "/var/media"
    quota         = false
    read_only     = false
    replicate     = true
    shared        = false
    volume        = "/hddpool/media"
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:35:82:57"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

resource "proxmox_virtual_environment_container" "prometheus" {
  delete_unreferenced_disks_on_destroy = false
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 2
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 20
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "prometheus"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  memory {
    dedicated = 2048
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:65:AD:6B"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # Neither reaches Proxmox's reported config: the template is only used
    # at creation, and timeout_start is the provider's own setting.
    ignore_changes = [operating_system[0].template_file_id, timeout_start]
  }
}

# GLPI, the lab's ITSM suite, at itsm.sogode.com – homelab/glpi. Created here
# rather than imported: the first guest born in OpenTofu.
#
# The MAC is fixed so the router's reservation (192.168.8.63) can be made
# before the guest first starts, and so its SLAAC ULA is known in advance.
# The keys are written only at creation: two for the owner, and talos's deploy
# key with the restrictions infra/ansible/deploy-access.yml would give it, so
# apply-on-merge can reach the host from its first boot.
resource "proxmox_virtual_environment_container" "glpi" {
  delete_unreferenced_disks_on_destroy = false
  description                          = "glpi - GLPI, see homelab/glpi\n"
  environment_variables                = {}
  migrate                              = false
  node_name                            = "lenora"
  pool_id                              = "Production"
  protection                           = false
  purge_on_destroy                     = true
  start_on_boot                        = true
  started                              = true
  tags                                 = []
  template                             = false
  timeout_clone                        = 1800
  timeout_create                       = 1800
  timeout_delete                       = 60
  timeout_migrate                      = 1800
  timeout_update                       = 1800
  unprivileged                         = true
  vm_id                                = 304
  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }
  cpu {
    architecture = "amd64"
    cores        = 2
    limit        = 0
  }
  disk {
    acl           = false
    datastore_id  = "ssdpool"
    mount_options = []
    quota         = false
    replicate     = false
    size          = 16
  }
  features {
    fuse    = false
    keyctl  = false
    mknod   = false
    mount   = []
    nesting = true
  }
  initialization {
    hostname = "glpi"
    dns {
      domain = "home"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    user_account {
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW5phwQWtosKuBdP6pzX6EwenL9jLuMTPWL0tq9tiii peet@mbp",
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOdQ066rf4GAQliNffyKmUHRAKpnODAmZeE83yo7ybU peet@mba",
        "from=\"192.168.8.59\",no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKVlnwYBn2FgNTyZF5/1hpSAbeMPhZToRotgm3bG8YG forgejo-runner@talos-deploy",
      ]
    }
  }
  memory {
    dedicated = 2048
    swap      = 512
  }
  network_interface {
    bridge       = "vmbr0"
    enabled      = true
    firewall     = false
    host_managed = false
    mac_address  = "BC:24:11:47:4C:50"
    mtu          = 0
    name         = "eth0"
    rate_limit   = 0
    vlan_id      = 0
  }
  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }
  lifecycle {
    prevent_destroy = true
    # The template and the keys are only used at creation, and timeout_start
    # is the provider's own setting; none of them reaches Proxmox's config.
    ignore_changes = [
      operating_system[0].template_file_id,
      timeout_start,
      initialization[0].user_account,
    ]
  }
}
