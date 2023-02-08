source "azure-arm" "main" {
  location                          = "UK West"
  managed_image_name                = "hashicorp-vault-${legacy_isotime("02-01-06-1504")}"
  managed_image_resource_group_name = "vault"

  temp_compute_name                      = "packer-build-hashicorp-vault-${legacy_isotime("02-01-06-1504")}"
  temp_nic_name                          = "packer-build-hashicorp-vault-${legacy_isotime("02-01-06-1504")}"
  virtual_network_name                   = "primary_network"
  virtual_network_resource_group_name    = "network"
  virtual_network_subnet_name            = "public"
  os_type                                = "Linux"
  image_offer                            = "UbuntuServer"
  image_publisher                        = "Canonical"
  image_sku                              = "18_04-lts-gen2"
  vm_size                                = "Standard_DS2_v2"
  private_virtual_network_with_public_ip = true

  azure_tags = {
    dept          = "Engineering"
    task          = "Vault"
    Vault_Version = var.VAULTVERSION
  }
}

build {
  sources = ["source.azure-arm.main"]

  provisioner "file" {
    source      = "files/run-vault.sh"
    destination = "/tmp/run-vault"
  }
  provisioner "file" {
    source      = "files/install-vault.sh"
    destination = "/tmp/install-vault"
  }
  provisioner "file" {
    source      = "files/supervisord.conf"
    destination = "/tmp/supervisord.conf"
  }
  provisioner "file" {
    source      = "files/update-certificate-store.sh"
    destination = "/tmp/update-certificate-store.sh"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
      "curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash",
      "/tmp/install-vault --version ${var.VAULTVERSION}",
    ]
    inline_shebang = "/bin/sh -x"
  }
}