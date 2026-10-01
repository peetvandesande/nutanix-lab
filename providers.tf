terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = ">=1.0.0"
    }
  }
}

provider "proxmox" {
  ca_cert_file = "gain-g3.pem"
  pm_api_url = "https://192.168.1.21:8006/api2/json"
  pm_user = var.pm_username
  pm_password = var.pm_password
}
