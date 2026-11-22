#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/hook-messages.sh"

fail() {
    write_hook_message "[FAIL] $1" >&2
    exit 1
}

region=$1
subscription=$2
vm_size=$3
publisher=$4
offer=$5
sku=$6
version=$7
zone=$8
zone_mode=${9:-optional}

[[ "$region" =~ ^[a-z0-9]+$ ]] || fail 'AZURE_LOCATION must be a lowercase Azure region code.'
[[ "$vm_size" =~ ^[A-Za-z0-9_]+$ ]] || fail 'VM size must contain only letters, numbers, and underscores.'
[[ -n "$subscription" ]] || fail 'AZURE_SUBSCRIPTION_ID is required for regional availability checks.'
command -v az >/dev/null || fail 'Azure CLI is required for regional availability checks.'
grep -Fxq "$region" "$script_dir/bastion-developer-regions.txt" \
    || fail "Bastion Developer is not in the documented region list for $region. Choose another AZURE_LOCATION or update the list after checking Microsoft documentation."

write_hook_message "[INFO] Checking VM image and size availability in $region; the SKU lookup can take several minutes." >&2
if ! images=$(az vm image list --subscription "$subscription" --location "$region" \
    --publisher "$publisher" --offer "$offer" --sku "$sku" --all \
    --query '[].[publisher,offer,sku,version]' --output tsv --only-show-errors); then
    fail "Could not query VM images in $region for the selected subscription. Check Azure CLI authentication and permissions."
fi

image_found=false
publisher_lower=$(printf '%s' "$publisher" | tr '[:upper:]' '[:lower:]')
offer_lower=$(printf '%s' "$offer" | tr '[:upper:]' '[:lower:]')
sku_lower=$(printf '%s' "$sku" | tr '[:upper:]' '[:lower:]')
while IFS=$'\t' read -r candidate_publisher candidate_offer candidate_sku candidate_version; do
    if [[ "$(printf '%s' "$candidate_publisher" | tr '[:upper:]' '[:lower:]')" == "$publisher_lower" \
        && "$(printf '%s' "$candidate_offer" | tr '[:upper:]' '[:lower:]')" == "$offer_lower" \
        && "$(printf '%s' "$candidate_sku" | tr '[:upper:]' '[:lower:]')" == "$sku_lower" \
        && ( "$version" == latest || "$candidate_version" == "$version" ) ]]; then
        image_found=true
        break
    fi
done <<< "$images"
[[ "$image_found" == true ]] || fail "VM image $publisher:$offer:$sku:$version is not available in $region for the selected subscription."

query="[?name=='$vm_size'].[name, length(restrictions[?type=='Location']), join(',', locationInfo[].zones[]), join(',', restrictions[?type=='Zone'].restrictionInfo.zones[]), length(restrictions[?type!='Location' && type!='Zone']), length(restrictions[?type=='Zone']), length(restrictions[?type=='Zone' && length(restrictionInfo.zones || \`[]\`) > \`0\`]), join(',', locationInfo[].location)]"
if ! sku_info=$(az vm list-skus --subscription "$subscription" --location "$region" \
    --resource-type virtualMachines --size "$vm_size" --all --query "$query" \
    --output tsv --only-show-errors); then
    fail "Could not query VM sizes in $region for the selected subscription. Check Azure CLI authentication and permissions."
fi
[[ -n "$sku_info" ]] || fail "VM size $vm_size is not available in $region for the selected subscription."

sku_name=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $1}')
location_restrictions=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $2}')
zones=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $3}')
restricted_zones=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $4}')
other_restrictions=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $5}')
zone_restrictions=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $6}')
known_zone_restrictions=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $7}')
sku_location=$(printf '%s\n' "$sku_info" | awk -F '\t' '{print $8}' | tr '[:upper:]' '[:lower:]')
[[ "$sku_name" == "$vm_size" && "$location_restrictions" =~ ^[0-9]+$ && "$other_restrictions" =~ ^[0-9]+$ \
    && "$zone_restrictions" =~ ^[0-9]+$ && "$known_zone_restrictions" =~ ^[0-9]+$ ]] \
    || fail "Azure CLI returned an unexpected VM size response for $vm_size in $region."
(( location_restrictions == 0 && other_restrictions == 0 )) \
    || fail "VM size $vm_size is restricted in $region for the selected subscription."
if [[ "$zone_mode" == select ]]; then
    [[ "$sku_location" == "$region" ]] \
        || fail "Azure CLI returned unexpected zone locations for $vm_size in $region."
    (( zone_restrictions == known_zone_restrictions )) \
        || fail "Azure CLI returned incomplete zone restrictions for $vm_size in $region."
    [[ -z "$zone" || "$zone" =~ ^[1-4]$ ]] || fail 'VM_ZONE must be a zone number from 1 to 4.'
    [[ -n "$zones" ]] || fail "No availability zones were reported for VM size $vm_size in $region."
    IFS=',' read -r -a candidates <<< "$zones"
    if [[ -n "$restricted_zones" ]]; then
        IFS=',' read -r -a restrictions <<< "$restricted_zones"
        for restricted in "${restrictions[@]}"; do
            [[ "$restricted" =~ ^[1-4]$ ]] || fail "Azure CLI returned an invalid zone restriction for $vm_size in $region."
        done
    fi
    selected=''
    for candidate in "${candidates[@]}"; do
        [[ "$candidate" =~ ^[1-4]$ ]] || fail "Azure CLI returned an unsupported zone for $vm_size in $region."
        if [[ ",$restricted_zones," != *",$candidate,"* && ( -z "$selected" || "$candidate" -lt "$selected" ) ]]; then
            selected=$candidate
        fi
    done
    [[ -n "$selected" ]] || fail "No unrestricted availability zones were reported for VM size $vm_size in $region."
    if [[ -n "$zone" ]]; then
        [[ ",$zones," == *",$zone,"* && ",$restricted_zones," != *",$zone,"* ]] \
        || fail "VM size $vm_size is not available in zone $zone in $region for the selected subscription."
        selected=$zone
    fi
    printf '%s\n' "$selected"
fi
write_hook_message "[PASS] VM image, size, and Bastion Developer region checks passed for $region." >&2
