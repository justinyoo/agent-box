#!/usr/bin/env bash
set -euo pipefail

if ! response=$(curl -q --ipv4 --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 https://api.ipify.org); then
    printf '%s\n' 'Unable to determine the public IPv4 address from ipify.' >&2
    exit 1
fi

pattern='^[[:space:]]*([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})[[:space:]]*$'
if [[ ! $response =~ $pattern ]]; then
    printf '%s\n' 'ipify did not return a valid IPv4 address.' >&2
    exit 1
fi

source_ip=${BASH_REMATCH[1]}
IFS=. read -r -a octets <<< "$source_ip"
for octet in "${octets[@]}"; do
    if [[ ! $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( octet > 255 )); then
        printf '%s\n' 'ipify did not return a valid IPv4 address.' >&2
        exit 1
    fi
done

printf '%s/32\n' "$source_ip"
