#!/bin/sh
# Offline checks: shell syntax, generated template structure, drift.
#
# Runs in the project pipeline and locally:
#   docker run --rm -v "$PWD:/w" -w /w alpine:3.21 \
#     sh -c 'apk add --no-cache yq >/dev/null && sh ci/validate.sh'
#
# Does not touch the GitLab API, so it works before push. Two checks carry the
# weight here:
#
#   * drift - templates/mirror.yml is GENERATED from mirror.sh; editing the
#     generated file by hand must fail rather than ship a second, divergent
#     copy of the truth.
#   * document layout - a component whose spec: is not separated from the job
#     by a YAML document separator is silently unusable: GitLab answers every
#     consumer with "Given inputs not defined in the spec section". That is
#     how 1.0.0 shipped broken, so the shape is asserted explicitly.
#
# templates/mirror-standalone.yml is generated from the same body for peers on
# another GitLab instance, which cannot reference this catalog at all. It is
# held to the mirror image of the component's shape: one document, no spec:,
# no input interpolation left in it.

set -eu

cd "$(dirname "$0")/.."

# Owner/repo of the public GitHub mirror of this project. The reusable workflow
# must reference the composite action by this path, never by "./" - see below.
GH_REPO="2serenity/repo-mirror"

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

# 2. mirror.sh is inlined into a file that GitLab runs input interpolation over.
#    A literal $[[ in the script body would be eaten by that pass.
if grep -q '\$\[\[' mirror.sh; then
  bad "mirror.sh: contains \$[[ - would collide with input interpolation"
else
  ok "mirror.sh: no \$[[ sequences"
fi

# 3. yq must be present.
if ! command -v yq >/dev/null 2>&1; then
  echo "yq not installed; install it (apk add yq)" >&2
  exit 1
fi

# 4. Generated template: two documents, spec: in the first, one job in the second.
if [ ! -f templates/mirror.yml ]; then
  bad "templates/mirror.yml missing (run sh ci/embed.sh)"
else
  # The body of mirror.sh is inlined indented, so ^---$ can only be the header
  # separator.
  NSEP=$(grep -c '^---$' templates/mirror.yml || true)
  if [ "$NSEP" -eq 1 ]; then
    ok "templates/mirror.yml: exactly one document separator"
  else
    bad "templates/mirror.yml: expected 1 '---' separator after spec:, found $NSEP"
  fi

  DOC0=$(yq -r 'select(di == 0) | keys | .[]' templates/mirror.yml 2>/dev/null || true)
  if [ "$DOC0" = "spec" ]; then
    ok "templates/mirror.yml: first document is the spec: header"
  else
    bad "templates/mirror.yml: first document must contain only spec:, found [$DOC0]"
  fi

  JOBS=$(yq -r 'select(di == 1) | keys | .[]' templates/mirror.yml 2>/dev/null || true)
  NJOB=$(printf '%s\n' "$JOBS" | grep -c . || true)

  if [ "$NJOB" -eq 1 ]; then
    ok "templates/mirror.yml: exactly one visible job ($JOBS)"
  else
    bad "templates/mirror.yml: expected 1 visible job, found $NJOB ($JOBS)"
  fi

  JOBKEY=$(printf '%s\n' "$JOBS" | head -1)

  if yq -e "select(di == 1) | .[\"$JOBKEY\"] | has(\"rules\")" templates/mirror.yml >/dev/null 2>&1; then
    ok "$JOBKEY: has rules:"
  else
    bad "$JOBKEY: missing rules:"
  fi

  if yq -e "select(di == 1) | .[\"$JOBKEY\"].variables.GIT_DEPTH" templates/mirror.yml >/dev/null 2>&1; then
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

# 5. Standalone artefact: exactly the opposite shape - a single plain job with
#    no spec: header, because the consuming side includes it as a local file and
#    has no way to pass component inputs.
STANDALONE="templates/mirror-standalone.yml"

if [ ! -f "$STANDALONE" ]; then
  bad "$STANDALONE missing (run sh ci/embed.sh)"
else
  NSEP=$(grep -c '^---$' "$STANDALONE" || true)
  if [ "$NSEP" -eq 0 ]; then
    ok "$STANDALONE: single document, no spec: separator"
  else
    bad "$STANDALONE: must be one document, found $NSEP '---' separators"
  fi

  if grep -q '\$\[\[' "$STANDALONE"; then
    bad "$STANDALONE: contains \$[[ - inputs do not exist outside a component"
  else
    ok "$STANDALONE: no input interpolation"
  fi

  SJOBS=$(yq -r 'keys | .[]' "$STANDALONE" 2>/dev/null || true)
  SNJOB=$(printf '%s\n' "$SJOBS" | grep -c . || true)

  if [ "$SNJOB" -eq 1 ] && [ "$SJOBS" != "spec" ]; then
    ok "$STANDALONE: exactly one job ($SJOBS)"
  else
    bad "$STANDALONE: expected 1 job and no spec:, found $SNJOB ($SJOBS)"
  fi

  SJOBKEY=$(printf '%s\n' "$SJOBS" | head -1)

  if yq -e ".[\"$SJOBKEY\"].variables.GIT_DEPTH" "$STANDALONE" >/dev/null 2>&1; then
    ok "$SJOBKEY: variables.GIT_DEPTH present"
  else
    bad "$SJOBKEY: variables.GIT_DEPTH missing"
  fi

  if grep -q '@@MIRROR_SH@@' "$STANDALONE"; then
    bad "$STANDALONE: marker not expanded (run sh ci/embed.sh)"
  else
    ok "$STANDALONE: marker expanded"
  fi
fi

# 6. Drift: regenerate each artefact to a temp file and diff against the
#    committed one. This is what makes "single source of truth" true rather
#    than aspirational - and it now covers both packagings.
check_drift() { # <generated file> <template>
  TMP=$(mktemp /tmp/mirror-gen.XXXXXX)
  sh ci/embed.sh "$TMP" "$2" >/dev/null
  if diff -u "$TMP" "$1" >/dev/null 2>&1; then
    ok "no drift: $1 matches mirror.sh"
  else
    bad "drift: $1 out of sync with mirror.sh (run sh ci/embed.sh)"
  fi
  rm -f "$TMP"
}

check_drift templates/mirror.yml            templates/mirror.yml.in
check_drift "$STANDALONE"                   templates/mirror-standalone.yml.in

# 7. GitHub reusable workflow must not use a local action path. When a reusable
#    workflow is called from another repository, steps run in the CALLER's
#    workspace, so "uses: ./" looks for action.yml in the consumer's checkout,
#    where it does not exist. It must name this repository explicitly, at a tag
#    whose major matches the newest released major in CHANGELOG.md.
WF=".github/workflows/mirror.yml"

# Nothing else in this pipeline parses the GitHub-side YAML, so a typo there
# would ship to the public repository unnoticed.
for f in action.yml "$WF"; do
  if [ ! -f "$f" ]; then
    bad "$f: missing"
  elif yq -e '.' "$f" >/dev/null 2>&1; then
    ok "$f: parses as YAML"
  else
    bad "$f: not valid YAML"
  fi
done

if [ -f "$WF" ]; then
  if grep -qE '^[[:space:]]*uses:[[:space:]]*\./' "$WF"; then
    bad "$WF: uses local action path './' - resolves against the caller's repo"
  else
    ok "$WF: no local action path"
  fi

  # Every workflow_call input must declare `type:`. GitHub requires it here
  # (unlike workflow_dispatch, where it defaults to string), and a file missing
  # it does not parse as a workflow at all. The failure is invisible in the way
  # that matters: the file is still valid YAML, so the check above passes, and
  # GitHub - unable to read `on:` - reports a startup failure attributed to
  # `push`, a run with no jobs. Six of those shipped before anyone looked. Same
  # shape as the missing `---` in the component: green build, dead artefact.
  UNTYPED=$(yq -r '.on.workflow_call.inputs // {} | to_entries | map(select(.value.type == null)) | .[].key' "$WF" 2>/dev/null || true)
  if [ -z "$UNTYPED" ]; then
    ok "$WF: every workflow_call input declares type:"
  else
    bad "$WF: workflow_call inputs without type: $(echo $UNTYPED)"
  fi

  MAJOR=$(grep -oE '^## v[0-9]+' CHANGELOG.md | head -1 | sed 's|^## v||' || true)
  WANT="$GH_REPO@v${MAJOR}"
  GOT=$(grep -oE "uses:[[:space:]]*${GH_REPO}@v[0-9]+" "$WF" | head -1 | sed -E 's/uses:[[:space:]]*//' || true)

  if [ -z "$MAJOR" ]; then
    bad "CHANGELOG.md: no released '## vX.Y.Z' heading to derive the major from"
  elif [ "$GOT" = "$WANT" ]; then
    ok "$WF: action pinned to $WANT"
  else
    bad "$WF: action ref is [$GOT], expected [$WANT]"
  fi

  # Third-party actions must be pinned to a commit, not a moving tag.
  if grep -qE '^[[:space:]]*uses:[[:space:]]*actions/[A-Za-z0-9_-]+@[0-9a-f]{40}' "$WF"; then
    ok "$WF: third-party actions pinned to a SHA"
  else
    bad "$WF: an actions/* reference is not pinned to a 40-char SHA"
  fi

  # The self-test calls the reusable workflow the way a consumer does - by full
  # path at the released tag. If that reference drifts behind the current major
  # the job still passes, while silently exercising a version nobody consumes.
  ST=".github/workflows/selftest.yml"
  SWANT="${GH_REPO}/.github/workflows/mirror.yml@v${MAJOR}"
  SGOT=$(grep -oE "uses:[[:space:]]*${GH_REPO}/\\.github/workflows/mirror\\.yml@v[0-9]+" "$ST" 2>/dev/null \
         | head -1 | sed -E 's/uses:[[:space:]]*//' || true)

  if [ ! -f "$ST" ]; then
    bad "$ST: missing - the GitHub packaging would again have no check of its own"
  elif [ "$SGOT" = "$SWANT" ]; then
    ok "$ST: calls the reusable workflow at $SWANT"
  else
    bad "$ST: reusable workflow call is [$SGOT], expected [$SWANT]"
  fi
fi

echo
echo "checks: $CHECKS, failed: $FAILED"

[ "$FAILED" -eq 0 ]
