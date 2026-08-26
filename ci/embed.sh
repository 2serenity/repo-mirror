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
# Two artefacts are generated from the same body:
#
#   templates/mirror.yml             the CI/CD Catalog component (spec: + job)
#   templates/mirror-standalone.yml  a plain job, for a peer on ANOTHER GitLab
#                                    instance, where `include: component:`
#                                    cannot reach this catalog at all
#
# Usage: sh ci/embed.sh                    regenerate both artefacts
#        sh ci/embed.sh OUTPUT [TEMPLATE]  render one, e.g. into a temp file
#                                          for the drift check

set -eu

cd "$(dirname "$0")/.."

SRC="mirror.sh"
MARKER="@@MIRROR_SH@@"

if [ ! -f "$SRC" ]; then
  echo "source $SRC not found" >&2
  exit 1
fi

render() { # <output> <template>
  OUT="$1"
  TEMPLATE="$2"

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
}

if [ $# -eq 0 ]; then
  render "templates/mirror.yml"            "templates/mirror.yml.in"
  render "templates/mirror-standalone.yml" "templates/mirror-standalone.yml.in"
else
  render "$1" "${2:-templates/mirror.yml.in}"
fi
