#!/usr/bin/env bash
# npm run test:linux [-- <word>...]: the test suite in a Debian container. Starts Colima
# when Docker is not running, and stops it again afterwards, leaving the machine as it was.
set -eu
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
started=0
if ! docker info >/dev/null 2>&1; then
  command -v colima >/dev/null || { echo "test:linux needs Docker running, or Colima (brew install colima docker)" >&2; exit 1; }
  colima start >/dev/null 2>&1 || { echo "colima start failed: run it by hand to see why" >&2; exit 1; }
  started=1
fi
stop() { ((started)) && colima stop >/dev/null 2>&1; return 0; }
trap stop EXIT
docker build -q -t cabinet-test "$KIT/test/linux" >/dev/null
docker run --rm -v "$KIT":/kit:ro cabinet-test /kit/test/smoke.sh "$@"
