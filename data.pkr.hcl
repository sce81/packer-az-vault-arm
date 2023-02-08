locals {
  timestamp = formatdate("YYYY-MM-DD-hhmm-ss", timestamp())
}

#data "azurerm_resource_group" "terraform" {
#  name = "terraform"
#}
