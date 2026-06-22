#!/bin/bash
# Build VPN & DNS.app via StatusItemKit's shared make-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh VPNDNSMenuBar "VPN & DNS"
