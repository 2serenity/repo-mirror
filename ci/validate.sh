#!/bin/sh
# Offline checks: shell syntax, generated template structure, drift.
#
# Runs in the project pipeline and locally:
#   docker run --rm -v "$PWD:/w" -w /w alpine:3.21 \
#     sh -c 'apk add --no-cache jq yq >/dev/null && sh ci/validate.sh'
#
# Does not touch the GitLab API, so it works before push. The drift check is the
# important one: templates/mirror.yml is GENERATED from mirror.sh; if someone
# edits the generated file by hand, this job must fail rather than ship a
# second, divergent copy of the truth.

set -eu

cd "$(dirname "$0")/.."

FAILED=0
CHECKS=0

ok()  { CHECKS=$((CHECKS + 1)); echo "    ok    $1"; }
bad() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "    FAIL  $1"; }

# 1. Shell syntax of the source of truth.
if sh -n mirror.sh 2>/tmp/ms.err; then
  ok "mirror.sh: shell syntax"
else
  bad "mirror.sh: $(cat /tmp/ms.err)"
fi

# 2. yq must be present.
if ! command -v yq >/dev/null 2>&1; then
  echo "yq not installed; install it (apk add yq)" >&2
  exit 1
fi

# 3. Generated template: spec: present, exactly one visible job, key fields.
if [ ! -f templates/mirror.yml ]; then
  bad "templates/mirror.yml missing (run sh ci/embed.sh)"
else
  if yq -e '.spec' templates/mirror.yml >/dev/null 2>&1; then
    ok "templates/mirror.yml: has spec:"
  else
    bad "templates/mirror.yml: no spec: section"
  fi

  # Top-level keys that are not 'spec' are visible jobs.
  JOBS=$(yq -r 'keys | .[] | select(. != "spec")' templates/mirror.yml)
  NJOB=$(printf '%s\n' "$JOBS" | grep -c . || true)

  if [ "$NJOB" -eq 1 ]; then
    ok "templates/mirror.yml: exactly one visible job ($JOBS)"
  else
    bad "templates/mirror.yml: expected 1 visible job, found $NJOB ($JOBS)"
  fi

  JOBKEY=$(printf '%s\n' "$JOBS" | head -1)

  if yq -e ".[\"$JOBKEY\"] | has(\"rules\")" templates/mirror.yml >/dev/null 2>&1; then
    ok "$JOBKEY: has rules:"
  else
    bad "$JOBKEY: missing rules:"
  fi

  if yq -e ".[\"$JOBKEY\"].variables.GIT_DEPTH" templates/mirror.yml >/dev/null 2>&1; then
    ok "$JOBKEY: variables.GIT_DEPTH present"
  else
    bad "$JOBKEY: variables.GIT_DEPTH missing"
  fi

  # The inline script must actually contain mirror.sh (not just the marker).
  if grep -q '@@MIRROR_SH@@' templates/mirror.yml; then
    bad "templates/mirror.yml: marker not expanded (run sh ci/embed.sh)"
  else
    ok "templates/mirror.yml: marker expanded"
  fi
fi

# 4. Drift: regenerate to a temp file and diff against the committed one.
TMP=$(mktemp /tmp/mirror-gen.XXXXXX)
sh ci/embed.sh "$TMP" >/dev/null
if diff -u "$TMP" templates/mirror.yml >/dev/null 2>&1; then
  ok "no drift: templates/mirror.yml matches mirror.sh"
else
  bad "drift: templates/mirror.yml out of sync with mirror.sh (run sh ci/embed.sh)"
fi
rm -f "$TMP"

echo
echo "checks: $CHECKS, failed: $FAILED"

[ "$FAILED" -eq 0 ]
