#!/bin/bash
# Compiles and runs the standalone unit tests. These cover pure logic that is
# painful to reach through the running app, so they need no Xcode test target
# and no VNC server -- just a compiler.
#
#   ./Tests/run_tests.sh
#
# Exits non-zero if any test fails.

set -euo pipefail

cd "$(dirname "$0")/.."

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

status=0

for src in Tests/test_*.m; do
    name=$(basename "$src" .m)
    printf '%s: ' "$name"

    if ! clang -Wall -Werror -framework Foundation \
            -ISource "$src" -o "$build_dir/$name"; then
        echo "COMPILE FAILED"
        status=1
        continue
    fi

    if "$build_dir/$name"; then
        :
    else
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "all tests passed"
else
    echo "TESTS FAILED"
fi

exit "$status"
