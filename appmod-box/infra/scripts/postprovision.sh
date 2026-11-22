#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../../../shared/hook-messages.sh"

fail() { write_hook_message "[FAIL] $1" >&2; exit 1; }
[[ -n "${AZURE_RESOURCE_GROUP:-}" ]] || fail 'AZURE_RESOURCE_GROUP is missing from the deployment outputs.'
[[ -n "${AZURE_VM_NAME:-}" ]] || fail 'AZURE_VM_NAME is missing from the deployment outputs.'
[[ -n "${AZURE_VM_ADMIN_USERNAME:-}" ]] || fail 'AZURE_VM_ADMIN_USERNAME is missing from the deployment outputs.'
admin_username=$AZURE_VM_ADMIN_USERNAME
write_hook_message "[INFO] Resource group: $AZURE_RESOURCE_GROUP"
write_hook_message "[INFO] VM: $AZURE_VM_NAME"
write_hook_message "[INFO] Windows Login Username: $admin_username"
write_hook_message '[MANUAL] Connect: Azure portal > VM > Connect > Bastion'
write_hook_message "[MANUAL] Sign in with .\\$admin_username and the password you entered."
write_hook_message '[MANUAL] After sign-in, open an elevated PowerShell terminal and run:'
write_hook_message '[MANUAL]   powershell.exe -NoProfile -File "$HOME\scripts\install-vm-tools.ps1"'
write_hook_message '[MANUAL] Tools are not installed during deployment. Approve installations and restart manually when requested.'
write_hook_message '[MANUAL] Verify WSL2 and Docker manually. See README.md for installation, licensing, and cleanup.'
