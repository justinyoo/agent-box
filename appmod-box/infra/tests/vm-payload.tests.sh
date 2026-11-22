#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT/.test-output"
fixture="$(mktemp -d "$ROOT/.test-output/vm-payload.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

repo="$fixture/repo with spaces"
mkdir -p "$repo/infra/scripts" "$repo/scripts" "$fixture/shared"
cp "$ROOT/scripts/"* "$repo/infra/scripts/"
cp "$ROOT/../scripts/"* "$repo/scripts/"
cp "$ROOT/../../shared/hook-messages.sh" "$fixture/shared/"
builder="$repo/infra/scripts/package-user-scripts.sh"

# Run outside the repository to verify script-relative source and output paths.
(cd "$fixture" && bash "$builder")
python3 - "$repo" "$repo/infra/.generated/payload.json" <<'PY'
import base64
import gzip
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
content = json.loads(pathlib.Path(sys.argv[2]).read_text())["content"]
assert len(content) <= 90000
payload = json.loads(gzip.decompress(base64.b64decode(content, validate=True)))
assert payload["schemaVersion"] == 1
expected = {
    name: root / "scripts" / name
    for name in (
        "install-vm-tools.ps1", "buildtools.vsconfig",
    )
}
assert len(payload["files"]) == len(expected)
assert {item["name"] for item in payload["files"]} == set(expected)
for item in payload["files"]:
    assert base64.b64decode(item["content"], validate=True) == expected[item["name"]].read_bytes()
PY

bash "$builder" "$fixture/custom output/payload.json"
cp "$fixture/custom output/payload.json" "$fixture/original.json"
expect_failure() {
    if "$@" > "$fixture/failure.log" 2>&1; then
        printf '%s\n' '[FAIL] Expected packaging failure.' >&2
        exit 1
    fi
    grep -q '\[FAIL\]' "$fixture/failure.log"
    cmp "$fixture/original.json" "$fixture/custom output/payload.json"
}
expect_failure bash "$builder" one two
mv "$repo/scripts/buildtools.vsconfig" "$fixture/buildtools.vsconfig"
expect_failure bash "$builder" "$fixture/custom output/payload.json"
mv "$fixture/buildtools.vsconfig" "$repo/scripts/buildtools.vsconfig"
cp "$repo/scripts/install-vm-tools.ps1" "$fixture/installer.ps1"
python3 - "$repo/scripts/install-vm-tools.ps1" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"x" * 1048576)
PY
expect_failure bash "$builder" "$fixture/custom output/payload.json"
grep -q '1 MiB' "$fixture/failure.log"
python3 - "$repo/scripts/install-vm-tools.ps1" <<'PY'
import os
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(os.urandom(100000))
PY
expect_failure bash "$builder" "$fixture/custom output/payload.json"
grep -q 'inline delivery' "$fixture/failure.log"
cp "$fixture/installer.ps1" "$repo/scripts/install-vm-tools.ps1"
mkdir "$fixture/bin"
printf '#!/usr/bin/env bash\nexit 42\n' > "$fixture/bin/gzip"
chmod +x "$fixture/bin/gzip"
expect_failure env PATH="$fixture/bin:$PATH" bash "$builder" "$fixture/custom output/payload.json"
if find "$repo/infra/.generated" "$fixture/custom output" -name '.payload.*' | grep -q .; then
    printf '%s\n' '[FAIL] Packaging left temporary files behind.' >&2
    exit 1
fi

AZURE_RESOURCE_GROUP='rg-test with spaces' AZURE_VM_NAME='vm-test' \
    bash "$ROOT/scripts/postprovision.sh" > "$fixture/instructions"
grep -Fq 'Resource group: rg-test with spaces' "$fixture/instructions"
grep -Fq 'VM: vm-test' "$fixture/instructions"
grep -Fq '$HOME\scripts\install-vm-tools.ps1' "$fixture/instructions"
if AZURE_RESOURCE_GROUP='' bash "$ROOT/scripts/postprovision.sh" > "$fixture/missing.log" 2>&1; then
    printf '%s\n' '[FAIL] Missing deployment outputs were accepted.' >&2
    exit 1
fi
printf '%s\n' '[PASS] VM Bash payload fidelity, paths, limits, failures, cleanup and connection instructions.'
