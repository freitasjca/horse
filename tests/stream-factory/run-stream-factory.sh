#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=$(mktemp -d /tmp/horse-stream-factory.XXXXXX)
cd "$test_dir"
fpc -B -Mdelphi -Sh -gh -gl -dHORSE_CONSOLE -Fu../../src \
  -FU"$output" -FE"$output" StreamFactoryCheck.dpr \
  >"$output/build.log" 2>&1 || {
    cat "$output/build.log"; exit 1;
  }
set +e
result=$("$output/StreamFactoryCheck" default 2>&1)
status=$?
set -e
printf '%s\n' "$result"
[ "$status" -eq 0 ] || exit "$status"
if printf '%s\n' "$result" | grep -Eq '[1-9][0-9]* unfreed memory blocks'; then
  echo 'Stream factory regression leaked memory.' >&2
  exit 1
fi
echo "PASS FPC $(fpc -iV) / default"
