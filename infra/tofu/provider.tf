# The API token comes from PROXMOX_VE_API_TOKEN; infra/scripts/tofu.sh sets it.
provider "proxmox" {
  endpoint = "https://lenora.home:8006/"
}
