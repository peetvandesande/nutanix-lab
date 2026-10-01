# shellcheck shell=bash
# Shared by the bootstrap and teardown scripts. Source it, then call
# load_config [ssh-target].

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Reads a simple scalar from terraform.tfvars, else the variables.tf default
tfvar() {
  local name=$1 value=""
  if [[ -f terraform.tfvars ]]; then
    value=$(sed -nE "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" terraform.tfvars | tail -n1)
  fi
  if [[ -z "$value" ]]; then
    value=$(awk -v n="$name" '
      $0 ~ "^variable \"" n "\"" { inside = 1 }
      inside && /^[[:space:]]*default[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
      inside && /^}/ { exit }
    ' variables.tf)
  fi
  echo "${value%"${value##*[![:space:]]}"}"
}

# Sets the settings both scripts need, plus TARGET for ssh
load_config() {
  PM_ENDPOINT=$(tfvar pm_endpoint)
  POOL=$(tfvar pool_id)
  DATASTORE=$(tfvar datastore_id)
  ISO=$(tfvar iso_file_id)
  VM_ID_START=$(tfvar vm_id_start)
  NODE_COUNT=$(tfvar node_count)
  TF_USER=${TF_USER:-terraform@pve}
  TOKEN_NAME=${TOKEN_NAME:-$POOL}

  local v
  for v in PM_ENDPOINT POOL DATASTORE ISO VM_ID_START NODE_COUNT; do
    [[ -n "${!v}" ]] || { echo "Missing value for $v – set it in terraform.tfvars" >&2; exit 1; }
  done

  local host
  host=$(sed -E 's#^https?://([^:/]+).*#\1#' <<<"$PM_ENDPOINT")
  TARGET=${1:-root@$host}
}

# Prints NAME=value pairs, shell-quoted, for passing settings over ssh
remote_env() {
  local v
  for v in "$@"; do
    printf '%s=%q\n' "$v" "${!v}"
  done
}
