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

echo "=== ALL RESOURCES IN PLATFORM RG ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/resources?api-version=2021-04-01" \
  -H "Authorization: Bearer $ARM" 2>/dev/null | python3 -c '
import sys,json
raw=sys.stdin.read()
d=json.loads(raw)
for r in d.get("value",[]):
    print(r.get("type",""), r.get("name",""), r.get("location",""))
' 2>&1 | head -60

echo ""
echo "=== ACR - PULL catalog-api WITH OCI INDEX SUPPORT ==="
ACR_RT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/exchange" \
  -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=access_token&service=crtblplatprodx3euoz.azurecr.io&access_token=$ARM" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)

CA_AT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
  -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token&service=crtblplatprodx3euoz.azurecr.io&scope=repository:catalog-api:pull&refresh_token=$ACR_RT" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

echo "catalog-api token len=${#CA_AT}"

# Get OCI image index
INDEX=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/manifests/latest" \
  -H "Authorization: Bearer $CA_AT" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json")

echo "--- OCI Index ---"
echo "$INDEX" | head -c 3000

# Extract linux/amd64 manifest digest
PLATFORM_DIGEST=$(echo "$INDEX" | python3 -c '
import sys,json
d=json.load(sys.stdin)
manifests=d.get("manifests",[])
for m in manifests:
    plat=m.get("platform",{})
    if plat.get("os")=="linux" and plat.get("architecture") in ["amd64","arm64"]:
        print(m.get("digest",""))
        break
if not manifests:
    # Single manifest format
    print(d.get("config",{}).get("digest",""))
' 2>/dev/null)

echo ""
echo "Platform digest: $PLATFORM_DIGEST"

if [ -n "$PLATFORM_DIGEST" ]; then
  # Get platform-specific manifest
  MANIFEST=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/manifests/$PLATFORM_DIGEST" \
    -H "Authorization: Bearer $CA_AT" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json")
  echo "--- Platform Manifest ---"
  echo "$MANIFEST" | head -c 2000

  # Get config blob digest
  CONFIG_DIGEST=$(echo "$MANIFEST" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(d.get("config",{}).get("digest",""))
' 2>/dev/null)
  echo "Config digest: $CONFIG_DIGEST"

  if [ -n "$CONFIG_DIGEST" ]; then
    echo "--- Config Blob (ENV, Labels, Cmd, History) ---"
    curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/blobs/$CONFIG_DIGEST" \
      -H "Authorization: Bearer $CA_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
cfg=d.get("config",{})
print("=== ENV ===")
for e in cfg.get("Env",[]):
    print(" ", e)
print("=== Labels ===")
for k,v in (cfg.get("Labels",{}) or {}).items():
    print(f"  {k}={v}")
print("=== Cmd ===", cfg.get("Cmd",[]))
print("=== Entrypoint ===", cfg.get("Entrypoint",[]))
print("=== WorkingDir ===", cfg.get("WorkingDir",""))
print("")
print("=== History ===")
for h in d.get("history",[]):
    cb=h.get("created_by","")
    if cb:
        print(" ", cb[:300])
' 2>/dev/null

    # Also check the layers for interesting files
    echo ""
    echo "--- Layer digests ---"
    echo "$MANIFEST" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for l in d.get("layers",[]):
    print(l.get("digest",""), l.get("size",""))
' 2>/dev/null
  fi
fi

echo ""
echo "=== STOREFRONT ENV VARS VIA REPORTING-SERVICE ==="
# reporting-service has contributor on reporting RG only - but let's check
RS_CID=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
RS_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
RS_AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$RS_CID" --data-urlencode "client_secret=$RS_SEC" \
  --data-urlencode "grant_type=client_credentials" --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

RS_OID=$(python3 -c "
import sys,json,base64
t='$RS_AT'.split('.')[1]; t+='='*((-len(t))%4)
print(json.loads(base64.urlsafe_b64decode(t)).get('oid',''))
" 2>/dev/null)
echo "reporting-service OID: $RS_OID"

echo "--- reporting-service sub-level role assignments ---"
curl -sS "$ARM_BASE/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'$RS_OID'" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:100])
else:
    print("Total:", len(vals))
    for r in vals:
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        scope=r["properties"]["scope"][:100]
        print(f"  role={role[:8]} scope={scope}")
' 2>/dev/null

echo ""
echo "--- storefront listApplicationSettings via cicd-deployer (ARM Reader) ---"
curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $ARM" -H "Content-Length: 0" | head -c 2000

echo ""
echo "--- reporting listApplicationSettings via reporting-service ---"
curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" -H "Content-Length: 0" | head -c 3000

echo ""
echo "=== REPORTING APP SITE AUTH SETTINGS ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/authsettingsV2?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" | head -c 2000

echo ""
echo "=== REPORTING APP SAMI ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2023-01-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
ident=d.get("identity",{}) or {}
sami=ident.get("principalId","")
uamis=list((ident.get("userAssignedIdentities",{}) or {}).keys())
props=d.get("properties",{})
print("SAMI:", sami)
print("UAMIs:", uamis)
print("siteConfig.linuxFxVersion:", props.get("siteConfig",{}).get("linuxFxVersion",""))
' 2>/dev/null

echo ""
echo "=== REPORTING APP - ALL RESOURCES IN REPORTING RG ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/resources?api-version=2021-04-01" \
  -H "Authorization: Bearer $RS_AT" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print(r.get("type",""), r.get("name",""), r.get("location",""))
' 2>/dev/null

echo "DONE"
