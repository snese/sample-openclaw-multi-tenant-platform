#!/usr/bin/env bash
# Create a tenant by adding it to the ApplicationSet.
# ArgoCD automatically creates the Application → Helm syncs all resources.
# Usage: ./scripts/create-tenant.sh <name> [--email <email>]
set -euo pipefail

usage() {
  echo "Usage: $0 <tenant-name> [--email <email>]"
  exit 1
}

TENANT="" EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) TENANT="$1"; shift ;;
  esac
done

[[ -z "$TENANT" ]] && usage
[[ -z "$EMAIL" ]] && EMAIL="${TENANT}@example.com"

echo "Creating tenant: ${TENANT}"
echo "  Email: ${EMAIL}"

# Read current ApplicationSet, append element, write back
APPSET=$(kubectl get applicationset openclaw-tenants -n argocd -o json)

# Check if tenant already exists
if echo "$APPSET" | python3 -c "
import json, sys
d = json.load(sys.stdin)
elements = d.get('spec',{}).get('generators',[{}])[0].get('list',{}).get('elements',[])
sys.exit(0 if any(e.get('name')=='${TENANT}' for e in elements) else 1)
" 2>/dev/null; then
  echo "Tenant ${TENANT} already exists in ApplicationSet"
  exit 0
fi

# Append new element
UPDATED=$(echo "$APPSET" | python3 -c "
import json, sys
d = json.load(sys.stdin)
elements = d['spec']['generators'][0]['list']['elements']
elements.append({'name': '${TENANT}', 'email': '${EMAIL}'})
json.dump(d, sys.stdout)
")

echo "$UPDATED" | kubectl apply -f - >/dev/null

echo ""
echo "Tenant added to ApplicationSet. ArgoCD will create the workspace:"
echo "  kubectl get application tenant-${TENANT} -n argocd -w"
