#!/bin/sh
# mirror.sh (source of truth) -> templates/mirror.yml (generated).
#
# Replaces the @@MIRROR_SH@@ marker in templates/mirror.yml.in with the full
# content of mirror.sh, indented to match the marker line, as ONE YAML literal
# block. Keeping mirror.sh as a single block is mandatory: its SSH_COMMAND uses
# line continuations ("ssh \") that would break if the file were split into
# separate `script:` list items.
#
# The body is passed through a temp file, never via `awk -v`: awk would
# interpret backslash escapes in -v values and corrupt the line continuations.
#
# Usage: sh ci/embed.sh [OUTPUT]
#   OUTPUT defaults to templates/mirror.yml

set -eu

cd "$(dirname "$0")/.."

SRC="mirror.sh"
TEMPLATE="templates/mirror.yml.in"
OUT="${1:-templates/mirror.yml}"
MARKER="@@MIRROR_SH@@"

if [ ! -f "$SRC" ]; then
  echo "source $SRC not found" >&2
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "template $TEMPLATE not found" >&2
  exit 1
fi

# Indentation of the marker line (leading whitespace before the marker).
INDENT=$(grep "^[[:space:]]*${MARKER}" "$TEMPLATE" | head -1 | sed -E "s/^(.*)${MARKER}.*/\1/")

# Indented body of mirror.sh, written to a temp file (no -v, no backslash mangle).
BODY=$(mktemp /tmp/mirror-body.XXXXXX)
awk -v indent="$INDENT" 'BEGIN { OFS="" } { printf "%s%s\n", indent, $0 }' "$SRC" > "$BODY"

awk -v marker="$MARKER" -v bodyfile="$BODY" '
  $0 ~ marker {
    while ((getline line < bodyfile) > 0) print line
    close(bodyfile)
    next
  }
  { print }
' "$TEMPLATE" > "$OUT"

rm -f "$BODY"

echo "wrote $OUT"
