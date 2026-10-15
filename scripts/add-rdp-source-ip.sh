#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

normalize_sources() {
    jq -ce '
        if type != "array" then error("RDP sources must be a JSON array.") else . end
        | map(
            if type != "string" then error("RDP sources must be IPv4 strings.") else . end
            | if contains("/") then . else . + "/32" end
            | if test("^((0|[1-9][0-9]{0,2})\\.){3}(0|[1-9][0-9]{0,2})/([1-9]|[12][0-9]|3[0-2])$")
                and (split("/")[0] | split(".") | all(.[]; tonumber <= 255))
              then . else error("Refusing an invalid or unrestricted RDP source; use IPv4/CIDR with prefix 1-32.") end
        ) | unique
    '
}

[[ $# -le 1 ]] || fail 'Usage: bash scripts/add-rdp-source-ip.sh [environment-name]'
for tool in az azd jq; do
    command -v "$tool" >/dev/null || fail "Required command not found: $tool"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(dirname -- "$script_dir")
env_args=(--cwd "$project_dir")
if [[ $# -eq 1 ]]; then
    [[ -n $1 ]] || fail 'The environment name must not be empty.'
    env_args+=(--environment "$1")
fi
config=$(azd env get-values "${env_args[@]}" --output json | jq -c '
    if type != "object" then error("Expected azd environment values.") else
        {AZURE_ENV_NAME, AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, VM_NAME, VM_RDP_SOURCE, VM_RDP_ADDITIONAL_SOURCES}
    end
')
jq -e '
    if type == "object" and
        all(.AZURE_ENV_NAME, .AZURE_SUBSCRIPTION_ID, .AZURE_RESOURCE_GROUP, .VM_NAME;
            type == "string" and length > 0)
    then true else error("Select a provisioned azd environment with subscription, resource group, and VM outputs.") end
' <<< "$config" >/dev/null
environment=$(jq -r '.AZURE_ENV_NAME' <<< "$config")
subscription=$(jq -r '.AZURE_SUBSCRIPTION_ID' <<< "$config")
resource_group=$(jq -r '.AZURE_RESOURCE_GROUP' <<< "$config")
vm_name=$(jq -r '.VM_NAME' <<< "$config")
source_ip=$(bash "$script_dir/get-rdp-source.sh")
saved=$(jq -c '(.VM_RDP_ADDITIONAL_SOURCES // "[]") | fromjson' <<< "$config")
saved=$(normalize_sources <<< "$saved")

rule_name=allow-rdp-from-trusted-source
rule_args=(--subscription "$subscription" --resource-group "$resource_group" --nsg-name "${vm_name}-nsg")
rules=$(az network nsg rule list "${rule_args[@]}" --output json)
rule=$(jq -ce --arg name "$rule_name" '
    if type != "array" then error("Expected an NSG rule list.") else . end
    | [.[] | select(.name == $name)]
    | if length > 1 then error("Multiple matching RDP rules.") else .[0] // {} end
' <<< "$rules")
action=create
if [[ $rule != '{}' ]]; then
    action=update
    jq -e '
        if .direction == "Inbound" and .access == "Allow" and .protocol == "Tcp"
            and (([.destinationPortRange // empty] + (.destinationPortRanges // []) | unique) == ["3389"])
            and ((.sourceApplicationSecurityGroups // []) | length == 0)
            and (([.sourceAddressPrefix // empty] + (.sourceAddressPrefixes // [])) | length > 0)
        then true else error("The existing named rule is not a supported IPv4 RDP allow rule; review it manually.") end
    ' <<< "$rule" >/dev/null
else
    jq -e '
        if any(.[]; .direction == "Inbound" and .priority == 1000)
        then error("Inbound priority 1000 is occupied; review the NSG before creating the RDP rule.") else true end
    ' <<< "$rules" >/dev/null
fi

sources_json=$(jq -cn --argjson saved "$saved" --argjson rule "$rule" \
    --argjson config "$config" --arg current "$source_ip" '
    $saved + [$rule.sourceAddressPrefix // empty] + ($rule.sourceAddressPrefixes // [])
    + [($config.VM_RDP_SOURCE // empty) | select(. != "")] + [$current]
' | normalize_sources)
sources=()
while IFS= read -r source; do
    sources+=("$source")
done <<< "$(jq -r '.[]' <<< "$sources_json")"

printf 'Appending %s to %s/%s in subscription %s (environment %s).\n' \
    "$source_ip" "$resource_group" "${vm_name}-nsg" "$subscription" "$environment"
if ! azd env set VM_RDP_ADDITIONAL_SOURCES "$sources_json" --cwd "$project_dir" --environment "$environment"; then
    fail 'Could not persist the RDP allowlist. No Azure rule was changed.'
fi
write_args=("${rule_args[@]}" --name "$rule_name" --source-address-prefixes "${sources[@]}")
if [[ $action == create ]]; then
    write_args+=(--priority 1000 --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 3389)
fi
if ! az network nsg rule "$action" "${write_args[@]}" --output none; then
    fail 'The allowlist was saved, but the Azure rule update failed. Rerun this script or provision to apply it.'
fi
if ! actual=$(az network nsg rule show "${rule_args[@]}" --name "$rule_name" --output json); then
    fail 'The Azure update was submitted, but verification failed. The allowlist remains saved; inspect the rule before retrying.'
fi
actual_sources=$(jq -ce '[.sourceAddressPrefix // empty] + (.sourceAddressPrefixes // [])' <<< "$actual" | normalize_sources)
[[ $actual_sources == "$sources_json" ]] || fail 'The Azure rule does not match the saved allowlist. Inspect the rule for a failed or concurrent update.'
printf 'Verified RDP sources: %s\n' "$sources_json"
