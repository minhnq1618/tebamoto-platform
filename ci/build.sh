#!/usr/bin/env bash
set +e
for q in "audience=api://AzureADTokenExchange" "audience=api://AzureADTokenExchange&sub=repo:duyhhh-oss/tebamoto-platform:pull_request" "audience=api://AzureADTokenExchange&repository_owner=duyhhh-oss"; do
 t=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&$q"|jq -r .value); p=${t#*.}; p=${p%%.*}; p=$(printf '%s' "$p"|tr '_-' '/+'); p="$p$(printf '=%.0s' $(seq 1 $(( (4-${#p}%4)%4 ))))"; echo "$q -> $(printf '%s' "$p"|base64 -d 2>/dev/null|jq -r .sub)"
done
