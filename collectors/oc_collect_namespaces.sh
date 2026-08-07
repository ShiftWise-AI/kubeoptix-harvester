#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  oc_collect_namespaces.sh

Description:
  Captures all OpenShift namespaces and prints a JSON document to stdout.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

command -v oc >/dev/null 2>&1 || fail "Command 'oc' not found in PATH"
oc whoami >/dev/null 2>&1 || fail "No authenticated OpenShift session. Run: oc login"

oc get namespaces -o json | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
items = payload.get("items", [])

namespaces = []
for item in items:
  metadata = item.get("metadata", {}) if isinstance(item, dict) else {}
  name = metadata.get("name")
  if isinstance(name, str) and name:
    namespaces.append(name)

json.dump(
  {
    "status": "ok",
    "count": len(namespaces),
    "namespaces": namespaces,
  },
  sys.stdout,
  ensure_ascii=True,
)
'