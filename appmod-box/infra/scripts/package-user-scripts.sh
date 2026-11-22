#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../../../shared/hook-messages.sh"

if [[ $# -gt 1 ]]; then
    write_hook_message '[FAIL] Usage: package-user-scripts.sh [output-path]' >&2
    exit 2
fi

target="${1:-$script_dir/../.generated/payload.json}"
work=''
trap 'if [[ -n "$work" ]]; then rm -rf -- "$work"; fi' EXIT
trap 'write_hook_message "[FAIL] VM script packaging failed." >&2' ERR

mkdir -p -- "$(dirname -- "$target")"
work="$(mktemp -d "$(dirname -- "$target")/.payload.XXXXXX")"

names=(install-vm-tools.ps1 buildtools.vsconfig)
printf '{"schemaVersion":1,"files":[' > "$work/files.json"
separator=''
for name in "${names[@]}"; do
    printf '%s{"name":"%s","content":"' "$separator" "$name" >> "$work/files.json"
    base64 < "$script_dir/../../scripts/$name" | tr -d '\r\n' >> "$work/files.json"
    printf '"}' >> "$work/files.json"
    separator=','
done
printf ']}' >> "$work/files.json"

if [[ $(wc -c < "$work/files.json") -gt 1048576 ]]; then
    write_hook_message '[FAIL] VM script payload exceeds the 1 MiB uncompressed limit.' >&2
    exit 1
fi
gzip -c < "$work/files.json" | base64 | tr -d '\r\n' > "$work/content"
length="$(wc -c < "$work/content" | tr -d '[:space:]')"
if [[ "$length" -gt 90000 ]]; then
    write_hook_message '[FAIL] Compressed VM payload is too large for inline delivery.' >&2
    exit 1
fi
{
    printf '{"content":"'
    cat "$work/content"
    printf '"}\n'
} > "$work/payload.json"
mv -f -- "$work/payload.json" "$target"
write_hook_message "[PASS] VM script payload: $length base64 characters."
