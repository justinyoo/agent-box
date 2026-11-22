#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
shared_dir="$script_dir/../../../shared"
source "$shared_dir/hook-messages.sh"

fail() {
    write_hook_message "[FAIL] $1" >&2
    exit 1
}

get_value() {
    local value
    value=$(azd env get-value "$1" --environment "$AZURE_ENV_NAME" 2>/dev/null) || value=''
    printf '%s' "$value"
}

[[ -n "${AZURE_ENV_NAME:-}" ]] || fail 'azd did not provide AZURE_ENV_NAME.'

vm_size=${APP_MOD_VM_SIZE:-$(get_value APP_MOD_VM_SIZE)}
disk_size=${APP_MOD_OS_DISK_SIZE_GB:-$(get_value APP_MOD_OS_DISK_SIZE_GB)}
shutdown_enabled=${APP_MOD_AUTO_SHUTDOWN_ENABLED:-$(get_value APP_MOD_AUTO_SHUTDOWN_ENABLED)}
shutdown_time=${APP_MOD_AUTO_SHUTDOWN_TIME:-$(get_value APP_MOD_AUTO_SHUTDOWN_TIME)}
vm_size=${vm_size:-Standard_D8s_v5}
disk_size=${disk_size:-256}
shutdown_enabled=${shutdown_enabled:-true}
shutdown_time=${shutdown_time:-0000}
[[ "$shutdown_time" =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]] \
    || fail 'APP_MOD_AUTO_SHUTDOWN_TIME must be a valid 24-hour time in HHmm format.'

location=${AZURE_LOCATION:-$(get_value AZURE_LOCATION)}
subscription=${AZURE_SUBSCRIPTION_ID:-$(get_value AZURE_SUBSCRIPTION_ID)}
[[ -n "$location" ]] || fail 'Set AZURE_LOCATION in the azd environment before provisioning.'
[[ -n "$subscription" ]] || fail 'Set AZURE_SUBSCRIPTION_ID in the azd environment before provisioning.'
bash "$shared_dir/validate-region.sh" "$location" "$subscription" "$vm_size" \
    MicrosoftWindowsDesktop windows-11 win11-26h2-ent latest ''

set_values=(
    "APP_MOD_VM_SIZE=$vm_size" "APP_MOD_OS_DISK_SIZE_GB=$disk_size"
    "APP_MOD_AUTO_SHUTDOWN_ENABLED=$shutdown_enabled" "APP_MOD_AUTO_SHUTDOWN_TIME=$shutdown_time"
)
azd env set "${set_values[@]}" --environment "$AZURE_ENV_NAME"
bash "$script_dir/package-user-scripts.sh"
payload=$(< ./infra/.generated/payload.json)
payload=${payload#'{"content":"'}
payload=${payload%'"}'}
[[ "$payload" =~ ^[A-Za-z0-9+/=]+$ && ${#payload} -le 90000 ]] || fail 'Invalid script payload.'
for part in 1 2 3; do
    offset=$(( (part - 1) * 30000 ))
    azd env set "VM_SCRIPT_PAYLOAD_${part}=${payload:offset:30000}" --environment "$AZURE_ENV_NAME"
done
write_hook_message "[PASS] app-modernisation-workshop is ready for azd environment $AZURE_ENV_NAME."
