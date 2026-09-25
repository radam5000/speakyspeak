# Sourced by install.sh just before it copies the hooks into ~/.claude/hooks.
#
# install.sh overwrites the installed hooks on every install and every in-app
# update. A copy that someone edited in place (their Claude "customized the
# hook" straight in ~/.claude/hooks) used to vanish without a word. Now: if
# the installed file matches no version this clone has ever shipped, it is
# someone's own edit, so it is kept next to the new one as
# <name>.mine-<date> and install.sh says so. A copy that matches any shipped
# version is replaced quietly, as before. Outside a git clone (a zip
# download) there is no history to compare with, so nothing changes.
keep_edited_hooks() {
  local name f blob
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  for name in speak-reply.sh session-end.sh tts-daemon.py; do
    f="$HOME/.claude/hooks/$name"
    [ -f "$f" ] || continue
    cmp -s "$f" "hooks/$name" && continue
    blob=$(git hash-object "$f")
    git log --all --format=%H -- "hooks/$name" 2>/dev/null \
      | while read -r c; do git rev-parse -q --verify "$c:hooks/$name" 2>/dev/null; done \
      | grep -qx "$blob" && continue
    cp -p "$f" "$f.mine-$(date +%Y%m%d-%H%M%S)"
    echo "NOTE: ~/.claude/hooks/$name had edits of its own. They are kept in $name.mine-$(date +%Y%m%d)*;"
    echo "      the new version is installed. To keep an edit through updates, make it in"
    echo "      $PWD/hooks/$name and commit it there."
  done
  return 0
}
