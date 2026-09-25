#!/bin/bash
# What Settings ▸ About ▸ "Update to X…" runs, in the clone install.sh
# recorded. Brings the clone up to date and reinstalls, and keeps whatever the
# user (or their Claude) changed in it.
#
# Until 1.2.19 the app ran `git pull --ff-only && ./install.sh`, which failed
# for good on any clone with edits in it, and INSTALL.md invites exactly that
# ("ask Claude to change it"). Now:
#   - uncommitted edits are set aside, the update lands, and they go back on top
#   - local commits are replayed on top of the update (a rebase)
#   - if either clashes with the update, everything is put back exactly as it
#     was, nothing is installed, and the app offers a prompt that has the
#     user's Claude do the merge.
#
# Exit codes (the app words its message from them):
#   0 updated and installed        2 could not reach the repository
#   1 install.sh failed            3 local changes clash with the update
#   4 this checkout cannot update itself (not a clone, detached, no upstream,
#     a merge or rebase already in progress)
# SPEAKYSPEAK_INSTALL_CMD replaces ./install.sh; it exists only for tests/.
set -u
cd "$(dirname "$0")/.." || exit 4
INSTALL=${SPEAKYSPEAK_INSTALL_CMD:-./install.sh}
note() { echo "update: $*"; }

git rev-parse --git-dir >/dev/null 2>&1 || { note "$PWD is not a git clone"; exit 4; }
gd=$(git rev-parse --git-dir)
if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || [ -f "$gd/MERGE_HEAD" ]; then
  note "a merge or rebase is already in progress in $PWD; finish or abort it first"; exit 4
fi
git symbolic-ref -q HEAD >/dev/null || { note "HEAD is detached in $PWD"; exit 4; }
git fetch -q || { note "could not fetch from $(git remote get-url origin 2>/dev/null)"; exit 2; }
upstream=$(git rev-parse -q --verify '@{u}') || { note "the current branch tracks no remote branch"; exit 4; }
before=$(git rev-parse HEAD)
# Setting edits aside and replaying commits both write commits, which git
# refuses to do for someone who never set a name and email. That is most
# people who only cloned this, so lend the updater's own for these steps.
if [ -z "$(git config user.email 2>/dev/null)" ]; then
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-SpeakySpeak updater}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-updater@speakyspeak.invalid}"
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-SpeakySpeak updater}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-updater@speakyspeak.invalid}"
fi

stashed=0
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git stash push -q -m "speakyspeak update $(date +%F-%H%M)" || { note "could not set local edits aside"; exit 4; }
  stashed=1
  note "set local edits aside"
fi

# Back to exactly where we started: the pre-update commit, then the edits.
# The stash was taken on $before, so popping it there always applies cleanly.
put_back() {
  git rebase --abort >/dev/null 2>&1
  git reset -q --hard "$before"
  [ "$stashed" = 1 ] && git stash pop -q
  note "CONFLICT: local changes clash with the update; the clone is back as it was"
  exit 3
}

# With no local commits this is a fast-forward; with some it replays them.
git rebase -q "$upstream" >/dev/null 2>&1 || put_back
if [ "$stashed" = 1 ]; then
  # A failed pop keeps the stash and leaves conflict markers; undo those first.
  if ! git stash pop -q >/dev/null 2>&1; then
    git reset -q --hard HEAD
    put_back
  fi
  note "local edits put back on top of the update"
fi
[ "$before" = "$(git rev-parse HEAD)" ] || note "updated $(git rev-parse --short "$before") -> $(git rev-parse --short HEAD)"

$INSTALL || exit 1
exit 0
