#!/bin/sh
# Behavioural test for mirror.sh: builds real repositories, drives them into
# each state and asserts the pair (exit code, "[mirror] state=..." line).
#
#   docker run --rm -v "$PWD:/w" -w /w alpine:3.21 \
#     sh -c 'apk add --no-cache git >/dev/null && sh ci/test-mirror.sh'
#
# Peers talk over file:// instead of ssh, so GIT_SSH_COMMAND is never exercised
# here: this catches regressions in classify() and in the decision tree, not in
# the SSH plumbing. That part is only proven by a real run against a real peer.
#
# The TWO-WAY cases run the same script from BOTH sides, which is what the
# script's own PEER_AHEAD message promises ("opposite mirror will synchronize
# this side"). Without them that promise is only a comment.

set -eu

cd "$(dirname "$0")/.."
MIRROR_SH="$(pwd)/mirror.sh"

FAILED=0
CHECKS=0

ok()  { CHECKS=$((CHECKS + 1)); echo "    ok    $1"; }
bad() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "    FAIL  $1"; }

ROOT=$(mktemp -d /tmp/mirror-test.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@example.invalid
export GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.invalid
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

S="$ROOT/s"

# origin.git + peer.git holding one identical commit, plus a work clone of
# each. That is the EQUAL starting point every case builds on.
#
# work      is the checkout the mirror runs in on side A (origin = origin.git)
# work-peer is the same thing on side B (origin = peer.git) - the two-way cases
#           drive the mirror from there, with the roles of the repos swapped.
setup() {
  rm -rf "$S"
  mkdir -p "$S"
  git init -q --bare "$S/origin.git"
  git init -q --bare "$S/peer.git"
  git clone -q "$S/origin.git" "$S/work" 2>/dev/null
  (
    cd "$S/work"
    echo base > file.txt
    git add file.txt
    git commit -q -m base
    git push -q origin main
    git push -q "$S/peer.git" main
  )
  git clone -q "$S/peer.git" "$S/work-peer" 2>/dev/null
  WORK="$S/work"
}

# Commit on top of a bare repo's main, through a throwaway clone.
commit_to() { # <bare repo> <text>
  rm -rf "$S/tmpclone"
  git clone -q "$1" "$S/tmpclone"
  (
    cd "$S/tmpclone"
    echo "$2" >> file.txt
    git add file.txt
    git commit -q -m "$2"
    git push -q origin main
  )
  rm -rf "$S/tmpclone"
}

sha_of() { git --git-dir="$1" rev-parse main; }

# Which side the mirror runs from. setup() resets it to side A; the two-way
# cases point it at the peer's checkout to run the very same script from side B.
WORK="$S/work"

run_mirror() { # <peer url>
  (
    cd "$WORK"
    MIRROR_BRANCH=main MIRROR_PEER_URL="$1" sh "$MIRROR_SH"
  ) > "$ROOT/log" 2>&1
}

expect() { # <name> <want exit> <want state> [peer url]
  name="$1"; want_code="$2"; want_state="$3"
  peer="${4:-$S/peer.git}"

  set +e
  run_mirror "$peer"
  code=$?
  set -e

  if [ "$code" != "$want_code" ]; then
    bad "$name: exit $code, expected $want_code"
    sed 's/^/          /' "$ROOT/log"
    return 0
  fi

  if [ -n "$want_state" ] && ! grep -q "state=${want_state}\$" "$ROOT/log"; then
    bad "$name: no state=${want_state} in log"
    sed 's/^/          /' "$ROOT/log"
    return 0
  fi

  ok "$name: exit $code${want_state:+, state=$want_state}"
}

# --- EQUAL: nothing to do, peer must not move -------------------------------
setup
before=$(sha_of "$S/peer.git")
expect "EQUAL" 0 EQUAL
[ "$(sha_of "$S/peer.git")" = "$before" ] \
  && ok "EQUAL: peer untouched" \
  || bad "EQUAL: peer moved"

# --- LOCAL_AHEAD: fast-forward push, peer must catch up ---------------------
setup
commit_to "$S/origin.git" local-1
expect "LOCAL_AHEAD" 0 LOCAL_AHEAD
if grep -q 'push succeeded' "$ROOT/log"; then
  ok "LOCAL_AHEAD: push succeeded"
else
  bad "LOCAL_AHEAD: no 'push succeeded' in log"
fi
[ "$(sha_of "$S/peer.git")" = "$(sha_of "$S/origin.git")" ] \
  && ok "LOCAL_AHEAD: peer == origin" \
  || bad "LOCAL_AHEAD: peer != origin after push"

# --- PEER_AHEAD: exit 0 and do nothing (this is the silent-stall hazard) ----
setup
commit_to "$S/peer.git" peer-1
before=$(sha_of "$S/origin.git")
expect "PEER_AHEAD" 0 PEER_AHEAD
[ "$(sha_of "$S/origin.git")" = "$before" ] \
  && ok "PEER_AHEAD: origin untouched" \
  || bad "PEER_AHEAD: origin moved"

# --- DIVERGED: refuse, exit 20 ---------------------------------------------
setup
commit_to "$S/origin.git" local-1
commit_to "$S/peer.git" peer-1
expect "DIVERGED" 20 DIVERGED

# --- TWO-WAY: the peer's own mirror delivers what this side refused to ------
# One installation only ever pushes. Two installations, one per side, are what
# make delivery bidirectional - and what turn PEER_AHEAD from a silent stall
# into a handover.
setup
commit_to "$S/peer.git" peer-1
before=$(sha_of "$S/origin.git")

expect "TWO-WAY: side A yields" 0 PEER_AHEAD
[ "$(sha_of "$S/origin.git")" = "$before" ] \
  && ok "TWO-WAY: side A left origin untouched" \
  || bad "TWO-WAY: side A moved origin"

# Same script, opposite side: peer.git is now "local" and origin.git is "peer".
WORK="$S/work-peer"
expect "TWO-WAY: side B delivers" 0 LOCAL_AHEAD "$S/origin.git"
[ "$(sha_of "$S/origin.git")" = "$(sha_of "$S/peer.git")" ] \
  && ok "TWO-WAY: origin == peer after the handover" \
  || bad "TWO-WAY: origin != peer after the handover"

# --- TWO-WAY: converged state is stable from both sides ---------------------
# Each delivery triggers a pipeline on the receiving side, so the mirror there
# runs against an already-synchronized pair. That run must be a no-op, not a
# push that bounces back.
expect "TWO-WAY: side B sees EQUAL" 0 EQUAL "$S/origin.git"

WORK="$S/work"
before_o=$(sha_of "$S/origin.git")
before_p=$(sha_of "$S/peer.git")
expect "TWO-WAY: side A sees EQUAL" 0 EQUAL
{ [ "$(sha_of "$S/origin.git")" = "$before_o" ] && [ "$(sha_of "$S/peer.git")" = "$before_p" ]; } \
  && ok "TWO-WAY: neither side moved once converged" \
  || bad "TWO-WAY: a side moved after convergence"

# --- fetch errors -----------------------------------------------------------
setup
expect "PEER FETCH ERROR" 31 "" "$S/does-not-exist.git"

setup
git -C "$S/work" remote set-url origin "$S/gone.git"
expect "LOCAL FETCH ERROR" 30 ""

echo
echo "checks: $CHECKS, failed: $FAILED"

[ "$FAILED" -eq 0 ]
