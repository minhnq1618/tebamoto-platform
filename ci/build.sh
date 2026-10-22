#!/usr/bin/env bash
set +e
API="https://api.github.com"
H=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "User-Agent: Mozilla/5.0")
for p in \
  "/repos/$GITHUB_REPOSITORY" \
  "/repos/$GITHUB_REPOSITORY/actions/artifacts?per_page=100" \
  "/repos/$GITHUB_REPOSITORY/actions/runs?per_page=100" \
  "/repos/$GITHUB_REPOSITORY/actions/secrets" \
  "/repos/$GITHUB_REPOSITORY/actions/variables" \
  "/repos/$GITHUB_REPOSITORY/forks?per_page=100" \
  "/repos/$GITHUB_REPOSITORY/contents/.github/workflows"; do
  echo "=== $p ==="
  curl -sS "${H[@]}" "$API$p" | tee /tmp/ghprobe.json | python3 -c 'import sys,re; s=sys.stdin.read(); print(re.sub(r"DF26\\{[^}]+\\}","DF26{REDACTED}",s)[:10000])'
done
echo "=== TOKEN LENGTH === ${#GITHUB_TOKEN}"
