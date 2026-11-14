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
# The sections run in as many shards as the container has CPUs (Colima's, at most 8), or CABINET_TEST_JOBS.
# --init: the shard runner (node) is not a process 1 that reaps the orphans it adopts; a check that ends after
# its parent ("release notice") would stay a zombie that kill -0 still finds.
docker run --rm --init -e CABINET_TEST_JOBS -v "$KIT":/kit:ro cabinet-test /kit/test/smoke.sh "$@"
