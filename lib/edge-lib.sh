#!/usr/bin/env bash
# Shared helpers for Alpine edge-node provisioning.

append_authorized_key() {
  local home_dir=${1:?home directory required}
  local user=${2:?user required}
  local group=${3:?group required}
  local public_key=${4:?public key required}
  local ssh_dir="$home_dir/.ssh"
  local key_file="$ssh_dir/authorized_keys"

  mkdir -p "$ssh_dir"
  touch "$key_file"
  if ! grep -Fxq -- "$public_key" "$key_file"; then
    printf '%s\n' "$public_key" >> "$key_file"
  fi
  chmod 700 "$ssh_dir"
  chmod 600 "$key_file"
  if [ "$(id -u)" -eq 0 ] && id "$user" >/dev/null 2>&1; then
    chown -R "$user:$group" "$ssh_dir"
  fi
}

append_authorized_keys() {
  local home_dir=${1:?home directory required}
  local user=${2:?user required}
  local group=${3:?group required}
  local keys=${4:?public keys required}
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    append_authorized_key "$home_dir" "$user" "$group" "$key"
  done <<< "$keys"
}
