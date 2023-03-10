#!/bin/bash
# This script is used to configure and run Vault on an Azure server.

set -e

readonly VAULT_CONFIG_FILE="default.hcl"
readonly SUPERVISOR_CONFIG_PATH="/etc/supervisor/conf.d/run-vault.conf"

readonly DEFAULT_PORT=8200
readonly DEFAULT_LOG_LEVEL="info"

readonly AZURE_INSTANCE_METADATA_URL="http://169.254.169.254/metadata/instance?api-version=2017-08-01"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"

function print_usage {
  echo
  echo "Usage: run-vault [OPTIONS]"
  echo
  echo "This script is used to configure and run Vault on an Azure server."
  echo
  echo "Options:"
  echo
  echo -e "  --azure-account-name\tSpecifies the Azure Storage account name where Vault data should be stored. Required."
  echo -e "  --azure-account-key\tSpecifies the Azure Storage account key for --azure-account-name. Required."
  echo -e "  --azure-container\tSpecifies the Azure Storage Blob container name. Required."
  echo -e "  --tls-cert-file\tSpecifies the path to the certificate for TLS. Required. To use a CA certificate, concatenate the primary certificate and the CA certificate together."
  echo -e "  --tls-key-file\tSpecifies the path to the private key for the certificate. Required."
  echo -e "  --port\t\tThe port for Vault to listen on. Optional. Default is $DEFAULT_PORT."
  echo -e "  --cluster-port\tThe port for Vault to listen on for server-to-server requests. Optional. Default is --port + 1."
  echo -e "  --config-dir\t\tThe path to the Vault config folder. Optional. Default is the absolute path of '../config', relative to this script."
  echo -e "  --bin-dir\t\tThe path to the folder with Vault binary. Optional. Default is the absolute path of the parent folder of this script."
  echo -e "  --log-dir\t\tThe path to the Vault log folder. Optional. Default is the absolute path of '../log', relative to this script."
  echo -e "  --log-level\t\tThe log verbosity to use with Vault. Optional. Default is $DEFAULT_LOG_LEVEL."
  echo -e "  --user\t\tThe user to run Vault as. Optional. Default is to use the owner of --config-dir."
  echo -e "  --skip-vault-config\tIf this flag is set, don't generate a Vault configuration file. Optional. Default is false."
  echo
  echo "Example:"
  echo
  echo "  run-vault --azure-account-name my-account-name --azure-account-key [REDACTED] --azure-container my-container-name --tls-cert-file /opt/vault/tls/vault.crt.pem --tls-key-file /opt/vault/tls/vault.key.pem"
}

function log {
  local readonly level="$1"
  local readonly message="$2"
  local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local readonly message="$1"
  log "INFO" "$message"
}

function log_warn {
  local readonly message="$1"
  log "WARN" "$message"
}

function log_error {
  local readonly message="$1"
  log "ERROR" "$message"
}

function lookup_path_in_instance_metadata {
  local readonly path="$1"
  curl --silent --show-error --header Metadata:true --location "$AZURE_INSTANCE_METADATA_URL" | jq -r "$path"
}

function get_instance_ip_address {
  lookup_path_in_instance_metadata ".network.interface[0].ipv4.ipAddress[0].privateIpAddress"
}


# Based on code from: http://stackoverflow.com/a/16623897/483528
function strip_prefix {
  local readonly str="$1"
  local readonly prefix="$2"
  echo "${str#$prefix}"
}

function assert_not_empty {
  local readonly arg_name="$1"
  local readonly arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function generate_vault_config {
  local readonly tls_cert_file="$1"
  local readonly tls_key_file="$2"
  local readonly port="$3"
  local readonly cluster_port="$4"
  local readonly config_dir="$5"
  local readonly user="$6"
  local readonly azure_account_name="$7"
  local readonly azure_account_key="$8"
  local readonly azure_container="$9"
  local readonly config_path="$config_dir/$VAULT_CONFIG_FILE"

  local instance_ip_address
  instance_ip_address=$(get_instance_ip_address)

  log_info "Creating default Vault config file in $config_path"
  cat > "$config_path" <<EOF
storage "azure" {
  accountName = "$azure_account_name"
  accountKey  = "$azure_account_key"
  container   = "$azure_container"
}
###ha_storage "consul" {
###  address = "127.0.0.1:8500"
###  path    = "vault/"
###  scheme  = "http"
###  service = "vault"
###  # HA settings
###  cluster_addr  = "https://$instance_ip_address:$cluster_port"
###  redirect_addr = "https://$instance_ip_address:$cluster_port"
###}
listener "tcp" {
  address         = "0.0.0.0:$port"
  cluster_address = "0.0.0.0:$cluster_port"
  tls_cert_file   = "$tls_cert_file"
  tls_key_file    = "$tls_key_file"
}
EOF
  chown "$user:$user" "$config_path"
}

function generate_supervisor_config {
  local readonly supervisor_config_path="$1"
  local readonly vault_config_dir="$2"
  local readonly vault_bin_dir="$3"
  local readonly vault_log_dir="$4"
  local readonly vault_log_level="$5"
  local readonly vault_user="$6"

  log_info "Creating Supervisor config file to run Vault in $supervisor_config_path"
  cat > "$supervisor_config_path" <<EOF
[program:vault]
command=$vault_bin_dir/vault server -config $vault_config_dir -log-level=$vault_log_level
stdout_logfile=$vault_log_dir/vault-stdout.log
stderr_logfile=$vault_log_dir/vault-error.log
numprocs=1
autostart=true
autorestart=true
stopsignal=INT
user=$vault_user
EOF
}

function start_vault {
  log_info "Reloading Supervisor config and starting Vault"
  supervisorctl reread
  supervisorctl update
}

# Based on: http://unix.stackexchange.com/a/7732/215969
function get_owner_of_path {
  local readonly path="$1"
  ls -ld "$path" | awk '{print $3}'
}

function run {
  local tls_cert_file=""
  local tls_key_file=""
  local port="$DEFAULT_PORT"
  local cluster_port=""
  local azure_account_name=""
  local azure_account_key=""
  local azure_container=""
  local config_dir=""
  local bin_dir=""
  local log_dir=""
  local log_level="$DEFAULT_LOG_LEVEL"
  local user=""
  local skip_vault_config="false"
  local all_args=()

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      --tls-cert-file)
        tls_cert_file="$2"
        shift
        ;;
      --tls-key-file)
        tls_key_file="$2"
        shift
        ;;
      --azure-account-name)
        azure_account_name="$2"
        shift
        ;;
      --azure-account-key)
        azure_account_key="$2"
        shift
        ;;
      --azure-container)
        azure_container="$2"
        shift
        ;;
      --port)
        assert_not_empty "$key" "$2"
        port="$2"
        shift
        ;;
      --cluster-port)
        assert_not_empty "$key" "$2"
        cluster_port="$2"
        shift
        ;;
      --config-dir)
        assert_not_empty "$key" "$2"
        config_dir="$2"
        shift
        ;;
      --bin-dir)
        assert_not_empty "$key" "$2"
        bin_dir="$2"
        shift
        ;;
      --log-dir)
        assert_not_empty "$key" "$2"
        log_dir="$2"
        shift
        ;;
      --log-level)
        assert_not_empty "$key" "$2"
        log_level="$2"
        shift
        ;;
      --user)
        assert_not_empty "$key" "$2"
        user="$2"
        shift
        ;;
      --skip-vault-config)
        skip_vault_config="true"
        ;;
      --help)
        print_usage
        exit
        ;;
      *)
        log_error "Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  assert_not_empty "--tls-cert-file" "$tls_cert_file"
  assert_not_empty "--tls-key-file" "$tls_key_file"
  assert_not_empty "--azure-account-name" "$azure_account_name"
  assert_not_empty "--azure-account-key" "$azure_account_key"
  assert_not_empty "--azure-container" "$azure_container"

  assert_is_installed "supervisorctl"
  assert_is_installed "az"
  assert_is_installed "curl"
  assert_is_installed "jq"

  if [[ -z "$config_dir" ]]; then
    config_dir=$(cd "$SCRIPT_DIR/../config" && pwd)
  fi

  if [[ -z "$bin_dir" ]]; then
    bin_dir=$(cd "$SCRIPT_DIR/../bin" && pwd)
  fi

  if [[ -z "$log_dir" ]]; then
    log_dir=$(cd "$SCRIPT_DIR/../log" && pwd)
  fi

  if [[ -z "$user" ]]; then
    user=$(get_owner_of_path "$config_dir")
  fi

  if [[ -z "$cluster_port" ]]; then
    cluster_port=$(( $port + 1 ))
  fi

  if [[ "$skip_vault_config" == "true" ]]; then
    log_info "The --skip-vault-config flag is set, so will not generate a default Vault config file."
  else
    generate_vault_config "$tls_cert_file" "$tls_key_file" "$port" "$cluster_port" "$config_dir" "$user" "$azure_account_name" "$azure_account_key" "$azure_container"
  fi

  generate_supervisor_config "$SUPERVISOR_CONFIG_PATH" "$config_dir" "$bin_dir" "$log_dir" "$log_level" "$user"
  start_vault
}

run "$@"