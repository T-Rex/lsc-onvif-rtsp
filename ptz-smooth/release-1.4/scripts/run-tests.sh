#!/bin/sh
# run-tests.sh - DEV-HOST wrapper that builds onvif_ptz_bridge 1.4 and runs the
# full offline test suite (unit + daemon/mock-motor + ONVIF SOAP + hardened
# restore.sh) inside the onvif-armv5-builder Docker image. No hardware.
#
# Usage (from the repo root or anywhere):
#   sh ptz-smooth/release-1.4/scripts/run-tests.sh
# Requires Docker and the onvif-armv5-builder:latest image (see docs/BUILD.md).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)                 # .../ptz-smooth/release-1.4
REPO=$(cd "$HERE/../.." && pwd)
IMG=${IMG:-onvif-armv5-builder:latest}

echo "=== building + testing onvif_ptz_bridge 1.4 in $IMG ==="
docker run --rm -v "$REPO:/work" "$IMG" sh -c '
  set -e
  cd /work/ptz-smooth/release-1.4
  tr -d "\r" < build.sh > /tmp/b14.sh
  HERE=/work/ptz-smooth/release-1.4 bash /tmp/b14.sh
  echo
  echo "=== hardened restore.sh offline tests ==="
  mkdir -p /tmp/rl/scripts /tmp/rl/tests
  tr -d "\r" < scripts/restore.sh    > /tmp/rl/scripts/restore.sh
  tr -d "\r" < tests/test-restore.sh > /tmp/rl/tests/test-restore.sh
  busybox sh /tmp/rl/tests/test-restore.sh
'
rc=$?
echo "run-tests wrapper rc=$rc"
exit $rc
