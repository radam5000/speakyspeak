#!/bin/bash
# Contract tests for scripts/update.sh, the in-app updater's clone step, and
# for install.sh's rule that a hand-edited installed hook is kept, not
# overwritten. A throwaway "mirror" repo stands in for GitHub; install.sh is
# replaced by a marker command so nothing is built or installed.
#
#   1. clean clone                    -> fast-forward, install runs
#   2. uncommitted edit, no clash     -> updated, edit still there, installs
#   3. local commit, no clash         -> replayed on top, installs
#   4. uncommitted edit that clashes  -> exit 3, clone byte-for-byte as before,
#                                        no install
#   5. local commit that clashes      -> exit 3, HEAD unchanged, no install
#   6. no network                     -> exit 2, nothing touched
#   7. install.sh keeps a hand-edited ~/.claude/hooks copy aside, and replaces
#      one that matches any shipped version silently
set -u
cd "$(dirname "$0")/.."
REPO="$PWD"
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# upstream: a bare mirror seeded with a tiny tree that has update.sh in it
git init -q --bare -b main "$TDIR/mirror.git"
git clone -q "$TDIR/mirror.git" "$TDIR/seed" 2>/dev/null
mkdir -p "$TDIR/seed/scripts"
cp "$REPO/scripts/update.sh" "$TDIR/seed/scripts/update.sh"
printf 'line1\nline2\nline3\nline4\nline5\n' > "$TDIR/seed/hook.txt"
echo 1.0.0 > "$TDIR/seed/VERSION"
git -C "$TDIR/seed" add -A && git -C "$TDIR/seed" commit -q -m "1.0.0" && git -C "$TDIR/seed" push -q origin main 2>/dev/null

release() {  # upstream edits line 5 and bumps VERSION
  printf 'line1\nline2\nline3\nline4\nline5 upstream %s\n' "$1" > "$TDIR/seed/hook.txt"
  echo "$1" > "$TDIR/seed/VERSION"
  git -C "$TDIR/seed" commit -qam "$1" && git -C "$TDIR/seed" push -q origin main 2>/dev/null
}
fresh() { git clone -q "$TDIR/mirror.git" "$1" 2>/dev/null; }
upd() {  # $1 clone -> rc in $RC, output in $OUT
  OUT=$(cd "$1" && SPEAKYSPEAK_INSTALL_CMD="touch $1/.installed" bash scripts/update.sh 2>&1); RC=$?
}
snap() { (cd "$1" && git rev-parse HEAD && git status --porcelain && cat hook.txt && git stash list); }

echo "update 1: clean clone fast-forwards and installs"
C="$TDIR/c1"; fresh "$C"; release 1.0.1; upd "$C"
[ "$RC" = 0 ] && [ "$(cat "$C/VERSION")" = 1.0.1 ] && [ -e "$C/.installed" ] && ok "updated to 1.0.1, installed" || bad "rc=$RC $OUT"

echo "update 2: an uncommitted edit that does not clash is carried over"
C="$TDIR/c2"; fresh "$C"; sed -i '' 's/^line1$/line1 MINE/' "$C/hook.txt"; release 1.0.2; upd "$C"
[ "$RC" = 0 ] && grep -q 'line1 MINE' "$C/hook.txt" && grep -q 'upstream 1.0.2' "$C/hook.txt" && [ -e "$C/.installed" ] \
  && ok "edit kept, update applied, installed" || bad "rc=$RC $OUT $(cat "$C/hook.txt")"
[ -z "$(git -C "$C" stash list)" ] && ok "no stash left behind" || bad "stash left: $(git -C "$C" stash list)"

echo "update 3: a local commit that does not clash is replayed on top"
C="$TDIR/c3"; fresh "$C"; sed -i '' 's/^line1$/line1 COMMITTED/' "$C/hook.txt"; git -C "$C" commit -qam "my voice tweak"
release 1.0.3; upd "$C"
[ "$RC" = 0 ] && grep -q 'line1 COMMITTED' "$C/hook.txt" && [ "$(cat "$C/VERSION")" = 1.0.3 ] && [ -e "$C/.installed" ] \
  && ok "commit kept on top of 1.0.3" || bad "rc=$RC $OUT"
[ "$(git -C "$C" log -1 --format=%s)" = "my voice tweak" ] && ok "the user's commit is the newest" || bad "log: $(git -C "$C" log --oneline | head -3)"

echo "update 4: an uncommitted edit that clashes leaves the clone exactly as it was"
C="$TDIR/c4"; fresh "$C"; sed -i '' 's/^line5.*/line5 MINE/' "$C/hook.txt"; release 1.0.4
before=$(snap "$C"); upd "$C"
[ "$RC" = 3 ] && ok "exit 3" || bad "rc=$RC $OUT"
[ "$(snap "$C")" = "$before" ] && ok "HEAD, edits and stash list unchanged" || bad "clone changed: $(snap "$C")"
[ -e "$C/.installed" ] && bad "installed anyway" || ok "nothing installed"
echo "$OUT" | grep -q CONFLICT && ok "says CONFLICT" || bad "output: $OUT"

echo "update 5: a local commit that clashes is rolled back to where it was"
C="$TDIR/c5"; fresh "$C"; sed -i '' 's/^line5.*/line5 COMMITTED/' "$C/hook.txt"; git -C "$C" commit -qam "mine"
release 1.0.5; before=$(snap "$C"); upd "$C"
[ "$RC" = 3 ] && [ "$(snap "$C")" = "$before" ] && [ ! -e "$C/.installed" ] && ok "exit 3, untouched, no install" || bad "rc=$RC $OUT $(snap "$C")"
[ -d "$C/.git/rebase-merge" ] || [ -d "$C/.git/rebase-apply" ] && bad "left mid-rebase" || ok "no rebase left open"

echo "update 6: no network touches nothing"
C="$TDIR/c6"; fresh "$C"; git -C "$C" remote set-url origin "$TDIR/nowhere.git"; before=$(snap "$C"); upd "$C"
[ "$RC" = 2 ] && [ "$(snap "$C")" = "$before" ] && ok "exit 2, untouched" || bad "rc=$RC $OUT"

echo "update 8: a stranger with no git name or email still gets edits and commits carried over"
C="$TDIR/c8"; fresh "$C"; sed -i '' 's/^line1$/line1 C/' "$C/hook.txt"; git -C "$C" commit -qam "mine"
sed -i '' 's/^line2$/line2 U/' "$C/hook.txt"; release 1.0.8
OUT=$(cd "$C" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
      EMAIL= SPEAKYSPEAK_INSTALL_CMD="touch $C/.installed" bash scripts/update.sh 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q 'line1 C' "$C/hook.txt" && grep -q 'line2 U' "$C/hook.txt" && grep -q 'upstream 1.0.8' "$C/hook.txt" \
  && ok "commit and edit both carried over with no identity set" || bad "rc=$RC $OUT"

echo "update 7: install.sh keeps a hand-edited installed hook, replaces a shipped one"
H="$TDIR/home"; mkdir -p "$H/.claude/hooks"
# (a) the installed copy is an older shipped version -> replaced, no backup
git -C "$REPO" log --format=%H -n 40 -- hooks/speak-reply.sh | sed -n 2p | while read -r c; do
  git -C "$REPO" show "$c:hooks/speak-reply.sh" > "$H/.claude/hooks/speak-reply.sh"; done
(cd "$REPO" && HOME="$H" bash -c 'source scripts/keep-edited-hooks.sh; keep_edited_hooks') > "$TDIR/k1" 2>&1
ls "$H/.claude/hooks/" | grep -q mine && bad "backed up a shipped version: $(cat "$TDIR/k1")" || ok "shipped version replaced quietly"
# (b) the installed copy has the user's own edit -> kept aside
printf '\n# my own tweak\n' >> "$H/.claude/hooks/speak-reply.sh"
(cd "$REPO" && HOME="$H" bash -c 'source scripts/keep-edited-hooks.sh; keep_edited_hooks') > "$TDIR/k2" 2>&1
ls "$H/.claude/hooks/"speak-reply.sh.mine-* >/dev/null 2>&1 && grep -q 'my own tweak' "$H/.claude/hooks/"speak-reply.sh.mine-* \
  && ok "hand-edited copy kept as speak-reply.sh.mine-*" || bad "not kept: $(ls "$H/.claude/hooks/") $(cat "$TDIR/k2")"
grep -q 'speak-reply.sh' "$TDIR/k2" && ok "and says so" || bad "silent: $(cat "$TDIR/k2")"

echo; echo "update tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
