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

is_noninteractive() {
    case "${AZD_NON_INTERACTIVE:-}" in
        [Tt][Rr][Uu][Ee]) return 0 ;;
    esac
    [[ -n "${CI:-}" || ! -r /dev/tty ]]
}

prompt_mai_region() {
    local answer
    is_noninteractive && fail 'Set MAI_FOUNDRY_REGION explicitly before running azd in CI or non-interactive mode.'
    write_hook_message '[INFO] Choose the Foundry region (verify current model availability and quota):' >&2
    printf '%s\n' \
        '  1. East US (eastus)' \
        '  2. Sweden Central (swedencentral)' \
        '  3. West Europe (westeurope)' \
        '  4. West US (westus)' >&2
    read -r -p 'Selection [1-4 or region]: ' answer </dev/tty \
        || fail 'MAI Foundry region selection was cancelled.'
    case "$answer" in
        1) answer=eastus ;;
        2) answer=swedencentral ;;
        3) answer=westeurope ;;
        4) answer=westus ;;
    esac
    printf '%s' "$answer"
}

[[ -n "${AZURE_ENV_NAME:-}" ]] || fail 'azd did not provide AZURE_ENV_NAME.'

set_values=()
mai_region=${MAI_FOUNDRY_REGION:-$(get_value MAI_FOUNDRY_REGION)}
if [[ -z "$mai_region" ]]; then
    configured_region=$(azd env config get infra.parameters.maiFoundryRegion --environment "$AZURE_ENV_NAME" 2>/dev/null) || configured_region=''
    case "$configured_region" in
        '"eastus"'|'"swedencentral"'|'"westeurope"'|'"westus"')
            mai_region=${configured_region//\"/} ;;
        '') ;;
        *) fail 'Configured maiFoundryRegion must be one of: eastus, swedencentral, westeurope, westus.' ;;
    esac
fi
[[ -n "$mai_region" ]] || mai_region=$(prompt_mai_region)
case "$mai_region" in
    eastus|swedencentral|westeurope|westus) ;;
    *) fail 'MAI_FOUNDRY_REGION must be one of: eastus, swedencentral, westeurope, westus.' ;;
esac
capacity=${MAI_IMAGE_CAPACITY:-$(get_value MAI_IMAGE_CAPACITY)}
capacity=${capacity:-1}
[[ "$capacity" =~ ^[0-9]+$ ]] || fail 'MAI_IMAGE_CAPACITY must be a positive whole number.'
(( 10#$capacity > 0 )) || fail 'MAI_IMAGE_CAPACITY must be a positive whole number.'
set_values+=("MAI_FOUNDRY_REGION=$mai_region" "MAI_IMAGE_CAPACITY=$capacity")

location=${AZURE_LOCATION:-$(get_value AZURE_LOCATION)}
subscription=${AZURE_SUBSCRIPTION_ID:-$(get_value AZURE_SUBSCRIPTION_ID)}
[[ -n "$location" ]] || fail 'Set AZURE_LOCATION in the azd environment before provisioning.'
[[ -n "$subscription" ]] || fail 'Set AZURE_SUBSCRIPTION_ID in the azd environment before provisioning.'
vm_size=${VM_SIZE:-$(get_value VM_SIZE)}
image_publisher=${VM_IMAGE_PUBLISHER:-$(get_value VM_IMAGE_PUBLISHER)}
image_offer=${VM_IMAGE_OFFER:-$(get_value VM_IMAGE_OFFER)}
image_sku=${VM_IMAGE_SKU:-$(get_value VM_IMAGE_SKU)}
image_version=${VM_IMAGE_VERSION:-$(get_value VM_IMAGE_VERSION)}
if [[ ${VM_ZONE+x} ]]; then
    zone=$VM_ZONE
else
    zone=$(get_value VM_ZONE)
fi
vm_size=${vm_size:-Standard_D64ds_v7}
image_publisher=${image_publisher:-microsoftwindowsdesktop}
image_offer=${image_offer:-windows-11}
image_sku=${image_sku:-win11-26h2-ent}
image_version=${image_version:-latest}
vm_id=${AZURE_VM_ID:-$(get_value AZURE_VM_ID)}
if [[ -n "$vm_id" ]]; then
    vm_id_lower=$(printf '%s' "$vm_id" | tr '[:upper:]' '[:lower:]')
    subscription_lower=$(printf '%s' "$subscription" | tr '[:upper:]' '[:lower:]')
    [[ "$vm_id_lower" == "/subscriptions/$subscription_lower/resourcegroups/"* ]] \
        || fail 'The previously deployed VM is not in the selected subscription. Use a new azd environment for a new VM.'
    vm_query="join('|', [location, join(',', zones || \`[]\`)])"
    if ! vm_info=$(az vm show --ids "$vm_id" --subscription "$subscription" \
        --query "$vm_query" --output tsv --only-show-errors); then
        fail 'Could not verify the previously deployed VM. Check its AZURE_VM_ID and Azure CLI access.'
    fi
    IFS='|' read -r existing_location existing_zone <<< "$vm_info"
    existing_location=$(printf '%s' "$existing_location" | tr '[:upper:]' '[:lower:]')
    [[ "$existing_location" == "$location" && "$existing_zone" =~ ^[1-4]$ ]] \
        || fail 'The previously deployed VM has a different region or no supported single zone. Use a new azd environment for a new VM.'
    [[ -z "$zone" || "$zone" == "$existing_zone" ]] \
        || fail "VM_ZONE $zone differs from the existing VM zone $existing_zone. An existing VM cannot be moved by reprovisioning."
    zone=$existing_zone
fi
selected_zone=$(bash "$shared_dir/validate-region.sh" "$location" "$subscription" "$vm_size" \
    "$image_publisher" "$image_offer" "$image_sku" "$image_version" "$zone" select)
set_values+=("VM_ZONE=$selected_zone")
write_hook_message "[INFO] Using VM availability zone $selected_zone in $location."

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
write_hook_message "[PASS] agent-box is ready for azd environment $AZURE_ENV_NAME."
