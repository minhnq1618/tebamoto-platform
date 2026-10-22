#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

echo "=== AZ ACR LOGIN ==="
ARM=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
ACR_RT=$(curl -sS "https://crtblplatprodx3euoz.azurecr.io/oauth2/exchange" \
  -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=access_token&service=crtblplatprodx3euoz.azurecr.io&access_token=$ARM" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)

echo "$ACR_RT" | docker login crtblplatprodx3euoz.azurecr.io --username "00000000-0000-0000-0000-000000000000" --password-stdin 2>&1

echo ""
echo "=== DOCKER PULL catalog-api ==="
docker pull crtblplatprodx3euoz.azurecr.io/catalog-api:latest 2>&1 | head -20

echo ""
echo "=== INSPECT catalog-api IMAGE ==="
docker inspect crtblplatprodx3euoz.azurecr.io/catalog-api:latest 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
if not d:
    print("No image")
else:
    img=d[0]
    cfg=img.get("Config",{})
    print("Env:")
    for e in cfg.get("Env",[]):
        print(" ",e)
    print("Cmd:", cfg.get("Cmd",[]))
    print("Entrypoint:", cfg.get("Entrypoint",[]))
    print("Labels:", cfg.get("Labels",{}))
    print("WorkingDir:", cfg.get("WorkingDir",""))
'

echo ""
echo "=== EXTRACT FILES FROM catalog-api ==="
CTID=$(docker create crtblplatprodx3euoz.azurecr.io/catalog-api:latest 2>/dev/null)
echo "Container ID: $CTID"

if [ -n "$CTID" ]; then
  # List all files in the container
  echo "--- File listing ---"
  docker export "$CTID" | tar -t 2>/dev/null | grep -v "^proc/" | grep -v "^sys/" | grep -v "^dev/" | head -100

  echo ""
  echo "--- Python/Shell/config files ---"
  docker export "$CTID" | tar -t 2>/dev/null | grep -E '\.(py|sh|env|json|yaml|yml|txt|cfg|conf|ini)$' | grep -v "\.pyc$" | head -50

  echo ""
  echo "--- Extract /app/ directory ---"
  mkdir -p /tmp/catalog_app
  docker export "$CTID" | tar -x -C /tmp/catalog_app 2>/dev/null \
    --include="./app/*" --include="./home/*" --include="./etc/environment" \
    --include="./etc/*.env" --include="./opt/*" 2>/dev/null || \
  docker export "$CTID" | tar -x -C /tmp/catalog_app 2>/dev/null app/ home/ opt/ 2>/dev/null || true

  find /tmp/catalog_app -type f 2>/dev/null | while read f; do
    echo "=== $f ==="
    file "$f" 2>/dev/null
    head -c 3000 "$f" 2>/dev/null
    echo ""
  done

  docker rm "$CTID" 2>/dev/null
fi

echo ""
echo "=== DOCKER HISTORY catalog-api ==="
docker history crtblplatprodx3euoz.azurecr.io/catalog-api:latest 2>/dev/null

echo ""
echo "=== ALSO PULL tebamoto-reporting-api ==="
docker pull crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest 2>&1 | head -10

echo ""
echo "=== INSPECT reporting-api ==="
docker inspect crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
if not d:
    print("No image")
else:
    img=d[0]
    cfg=img.get("Config",{})
    print("Env:")
    for e in cfg.get("Env",[]):
        print(" ",e)
    print("Cmd:", cfg.get("Cmd",[]))
    print("Entrypoint:", cfg.get("Entrypoint",[]))
    print("Labels:", cfg.get("Labels",{}))
    print("WorkingDir:", cfg.get("WorkingDir",""))
'

echo ""
echo "=== EXTRACT REPORTING API /app ==="
RTID=$(docker create crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest 2>/dev/null)
echo "Container ID: $RTID"

if [ -n "$RTID" ]; then
  echo "--- Python files in reporting-api ---"
  docker export "$RTID" | tar -t 2>/dev/null | grep "\.py$" | head -30

  echo ""
  echo "--- Extract /app/ ---"
  mkdir -p /tmp/reporting_app
  docker export "$RTID" | tar -x -C /tmp/reporting_app app/ 2>/dev/null || true

  find /tmp/reporting_app -type f -name "*.py" 2>/dev/null | while read f; do
    echo "=== $f ==="
    cat "$f" 2>/dev/null | head -c 5000
    echo ""
  done

  docker rm "$RTID" 2>/dev/null
fi

echo "DONE"
