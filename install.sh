#!/bin/bash
# ============================================================================
#  install.sh — install rangers-memories without an agent
# ----------------------------------------------------------------------------
#  INSTALL.md is a runbook for an AI to execute. This is the same thing as one
#  command, for a human, a CI job, or an assistant whose shell access is easier
#  to point at a script than to step through prose.
#
#      ./install.sh              install
#      ./install.sh --check      report what is installed, change nothing
#      ./install.sh --uninstall  remove the hook, keep every database
#
#  Safe to re-run. It never overwrites a database, never replaces
#  settings.json, and backs that file up before touching it.
#
#  CONFIGURE: RM_HOME (default ~/.rangers-memories)
#  REQUIRES:  bash, sqlite3, jq
# ============================================================================
set -uo pipefail

RM_HOME="${RM_HOME:-$HOME/.rangers-memories}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DST="$CLAUDE_DIR/hooks/save-conversation.sh"
CMD='bash ~/.claude/hooks/save-conversation.sh'
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="install"

case "${1:-}" in
  --check)     MODE="check" ;;
  --uninstall) MODE="uninstall" ;;
  -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")          ;;
  *)           echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }
note() { printf '    %s\n' "$1"; }
die()  { bad "$1"; echo; echo "Stopped. Nothing further was changed." >&2; exit 1; }

echo "rangers-memories — $MODE"
echo

# ── 1 · prerequisites ───────────────────────────────────────────────────────
echo "prerequisites"
missing=""
for t in sqlite3 jq; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not found"; missing="$missing $t"; fi
done
if [ -n "$missing" ]; then
  note "Debian/Ubuntu/Kali:  sudo apt install -y sqlite3 jq"
  note "macOS:               brew install sqlite jq"
  note "Fedora:              sudo dnf install -y sqlite jq"
  die "install the missing tool(s) above, then re-run"
fi
echo

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$MODE" = "uninstall" ]; then
  echo "removing the hook"
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    tmp=$(mktemp)
    if jq --arg c "$CMD" '
        if .hooks.Stop then
          .hooks.Stop |= map(.hooks |= map(select(.command != $c)))
          | .hooks.Stop |= map(select((.hooks|length) > 0))
          | if (.hooks.Stop|length) == 0 then del(.hooks.Stop) else . end
          | if (.hooks|length) == 0 then del(.hooks) else . end
        else . end' "$SETTINGS" > "$tmp" && jq -e . "$tmp" >/dev/null; then
      mv "$tmp" "$SETTINGS"; ok "settings.json entry removed (backup kept)"
    else
      rm -f "$tmp"; die "could not rewrite settings.json — backup is untouched"
    fi
  fi
  [ -f "$HOOK_DST" ] && rm -f "$HOOK_DST" && ok "hook script deleted"
  echo
  echo "Your databases in $RM_HOME were left alone. Nothing else touches them."
  exit 0
fi

# ── 2 · databases ───────────────────────────────────────────────────────────
echo "databases  ($RM_HOME)"
if [ "$MODE" = "install" ]; then
  mkdir -p "$RM_HOME/logs" || die "cannot create $RM_HOME"
fi
for db in memories conversations; do
  f="$RM_HOME/$db.db"
  if [ -f "$f" ]; then
    rows=$(sqlite3 "$f" "SELECT COUNT(*) FROM $( [ "$db" = memories ] && echo memories || echo conversations );" 2>/dev/null || echo "?")
    ok "$db.db exists — $rows rows, left alone"
  elif [ "$MODE" = "check" ]; then
    bad "$db.db missing"; continue
  else
    ok "$db.db created"
  fi
  [ "$MODE" = "install" ] && { sqlite3 "$f" < "$SRC/schema/schema.sql" || die "could not apply schema to $f"; }
done
if [ "$MODE" = "install" ]; then
  for db in memories conversations; do
    for t in memories conversations memory_links; do
      sqlite3 "$RM_HOME/$db.db" "SELECT 1 FROM $t LIMIT 1;" >/dev/null 2>&1 \
        || die "table $t missing from $db.db after applying the schema"
    done
  done
  ok "all three tables present in both"
fi
echo

# ── 3 · hook script ─────────────────────────────────────────────────────────
echo "hook script"
if [ "$MODE" = "check" ]; then
  [ -x "$HOOK_DST" ] && ok "installed at $HOOK_DST" || bad "not installed"
else
  mkdir -p "$CLAUDE_DIR/hooks" || die "cannot create $CLAUDE_DIR/hooks"
  cp "$SRC/hooks/save-conversation.sh" "$HOOK_DST" || die "could not copy the hook"
  chmod +x "$HOOK_DST"
  bash -n "$HOOK_DST" || die "the installed hook has a syntax error"
  ok "installed at $HOOK_DST"
fi
echo

# ── 4 · settings.json ───────────────────────────────────────────────────────
echo "settings.json"
wired=no
if [ -f "$SETTINGS" ] && jq -e --arg c "$CMD" '[.. | .command? // empty] | index($c)' "$SETTINGS" >/dev/null 2>&1; then
  wired=yes
fi
if [ "$MODE" = "check" ]; then
  [ "$wired" = yes ] && ok "Stop hook is wired" || bad "Stop hook is NOT wired"
elif [ "$wired" = yes ]; then
  ok "already wired — left as it is"
else
  [ -f "$SETTINGS" ] || { mkdir -p "$CLAUDE_DIR"; echo '{}' > "$SETTINGS"; }
  jq -e . "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON — fix it first, nothing was changed"
  backup="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$backup" || die "could not write a backup"
  tmp=$(mktemp)
  if jq --arg c "$CMD" '.hooks.Stop = ((.hooks.Stop // []) + [{"hooks":[{"type":"command","command":$c}]}])' \
        "$SETTINGS" > "$tmp" && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$SETTINGS"; ok "Stop hook added (backup: $backup)"
  else
    rm -f "$tmp"; cp "$backup" "$SETTINGS"
    die "merge produced invalid JSON — restored from backup"
  fi
fi
echo

# ── 5 · end-to-end test ─────────────────────────────────────────────────────
# The hook cannot be tested from inside a live session, so drive it with a
# transcript of our own. Counts must move by exactly 1 / 2 / 2.
if [ "$MODE" = "install" ]; then
  echo "test"
  TDIR="$CLAUDE_DIR/projects/_rmtest"; mkdir -p "$TDIR"
  cat > "$TDIR/rmtest.jsonl" <<'JS'
{"type":"user","message":{"role":"user","content":"install test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"output"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"install test reply"}]}}
JS
  m0=$(sqlite3 "$RM_HOME/memories.db"      'SELECT COUNT(*) FROM memories;')
  c0=$(sqlite3 "$RM_HOME/conversations.db" 'SELECT COUNT(*) FROM conversations;')
  l0=$(sqlite3 "$RM_HOME/memories.db"      'SELECT COUNT(*) FROM memory_links;')

  echo '{"session_id":"rmtest"}' | RM_HOME="$RM_HOME" bash "$HOOK_DST"

  m1=$(sqlite3 "$RM_HOME/memories.db"      'SELECT COUNT(*) FROM memories;')
  c1=$(sqlite3 "$RM_HOME/conversations.db" 'SELECT COUNT(*) FROM conversations;')
  l1=$(sqlite3 "$RM_HOME/memories.db"      'SELECT COUNT(*) FROM memory_links;')
  saved=$(sqlite3 "$RM_HOME/memories.db" "SELECT content FROM memories WHERE content LIKE '%install test%' ORDER BY id DESC LIMIT 1;")

  fail=0
  [ "$((m1 - m0))" -eq 1 ] && ok "memories +1"      || { bad "memories +$((m1-m0)), expected +1"; fail=1; }
  [ "$((c1 - c0))" -eq 2 ] && ok "conversations +2" || { bad "conversations +$((c1-c0)), expected +2"; fail=1; }
  [ "$((l1 - l0))" -eq 2 ] && ok "memory_links +2"  || { bad "memory_links +$((l1-l0)), expected +2"; fail=1; }

  # the pairing must survive a tool_result sitting between question and answer
  case "$saved" in
    *"install test"*"install test reply"*) ok "question and answer paired correctly" ;;
    *) bad "the saved pair is wrong: $saved"; fail=1 ;;
  esac

  # clean up — links FIRST, or two dangling links are left behind
  sqlite3 "$RM_HOME/memories.db"      "DELETE FROM memory_links WHERE session_id='rmtest';"
  sqlite3 "$RM_HOME/memories.db"      "DELETE FROM memories      WHERE content LIKE '%install test%';"
  sqlite3 "$RM_HOME/conversations.db" "DELETE FROM conversations WHERE content LIKE '%install test%';"
  rm -rf "$TDIR"

  m2=$(sqlite3 "$RM_HOME/memories.db" 'SELECT COUNT(*) FROM memories;')
  l2=$(sqlite3 "$RM_HOME/memories.db" 'SELECT COUNT(*) FROM memory_links;')
  { [ "$m2" -eq "$m0" ] && [ "$l2" -eq "$l0" ]; } && ok "test data removed cleanly" \
    || { bad "cleanup left rows behind (memories $m0→$m2, links $l0→$l2)"; fail=1; }

  if [ -s "$RM_HOME/logs/hook-failures.log" ]; then
    bad "failures were logged:"; tail -3 "$RM_HOME/logs/hook-failures.log" | sed 's/^/      /'; fail=1
  else
    ok "no failures logged"
  fi
  echo
  [ "$fail" -eq 0 ] || die "the test did not pass — do not assume this is working"
fi

# ── done ────────────────────────────────────────────────────────────────────
if [ "$MODE" = "check" ]; then
  echo "Run ./install.sh to install, or ~/.rangers-memories/rm-health.sh for an integrity report."
  exit 0
fi
cat <<EOF
Installed.

  databases   $RM_HOME/{memories,conversations}.db
  hook        $HOOK_DST
  failures    $RM_HOME/logs/hook-failures.log   (silence here means healthy)

It takes effect on your NEXT session, not this one.

Before searching, read docs/retrieval-playbook.md. The rule that costs the most
time: never ORDER BY importance when hunting for an auto-save — they all sit at
importance 6, so sorting by importance buries them. Order by timestamp.
EOF
