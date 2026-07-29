#!/bin/bash
# Counts compiler warnings and static-analyzer findings from a clean
# build+analyze. Pass a baseline count to fail when the total regresses above it.
#
#   ./Tests/count_warnings.sh        # report only
#   ./Tests/count_warnings.sh 117    # report, and fail if total > 117

set -o pipefail
cd "$(dirname "$0")/.." || exit 1

BASELINE="$1"
LOG=$(mktemp -t chicken-warnings)
trap 'rm -f "$LOG" "$LOG.warn"' EXIT

echo "Building (clean build analyze)..." >&2
xcodebuild clean build analyze -scheme Chicken \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$LOG" 2>&1
STATUS=$?

if ! grep -q '^\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
    echo "BUILD FAILED -- errors:" >&2
    grep -E "error:" "$LOG" | sed 's|.*/Source/|Source/|' | sort -u >&2
    exit 1
fi

# Unique warning sites. Compiler warnings declared in a header repeat once per
# translation unit; sort -u collapses them to the site that must actually be
# fixed, so the number tracks work remaining rather than TU count.
grep -E "warning:" "$LOG" \
    | sed 's|.*/cotvnc/Source/|Source/|' \
    | sed 's|^/.*/Chicken.build/|(generated) |' \
    | sort -u > "$LOG.warn"

echo
echo "=== By flag ==="
sed -n 's|.*\[\(-W[a-z0-9-]*\)\]$|\1|p' "$LOG.warn" | sort | uniq -c | sort -rn
echo "=== Static analyzer ==="
sed -n 's|.*\[\([a-z][a-zA-Z]*\.[a-zA-Z.]*\)\]$|\1|p' "$LOG.warn" | sort | uniq -c | sort -rn
echo
echo "=== Sites ==="
cat "$LOG.warn"

TOTAL=$(wc -l < "$LOG.warn" | tr -d ' ')
echo
echo "TOTAL: $TOTAL unique warning sites"

if [ -n "$BASELINE" ] && [ "$TOTAL" -gt "$BASELINE" ]; then
    echo "REGRESSION: $TOTAL > baseline $BASELINE" >&2
    exit 1
fi
exit $STATUS
