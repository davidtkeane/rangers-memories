#!/bin/bash
# ============================================================================
#  save-conversation.sh — a Claude Code Stop hook that gives you a memory
# ----------------------------------------------------------------------------
#  Fires when a session ends. Reads the session transcript, takes the last
#  user message and the last assistant message, and writes them to two
#  databases plus a link joining them.
#
#      TRUNK   memories.db       one searchable row per exchange
#      BRANCH  conversations.db  the two roles, kept apart
#      JOIN    memory_links      what makes it one system
#
#  INSTALL — add to ~/.claude/settings.json:
#
#      { "hooks": { "Stop": [ { "hooks": [
#            { "type": "command",
#              "command": "bash ~/.claude/hooks/save-conversation.sh" } ] } ] } }
#
#  CONFIGURE — optional, these are the defaults:
#      export RM_HOME=~/.rangers-memories
#      export RM_AGENT_ID=claude
#
#  REQUIRES: sqlite3, jq
# ============================================================================
set -uo pipefail

RM_HOME="${RM_HOME:-$HOME/.rangers-memories}"
RM_AGENT_ID="${RM_AGENT_ID:-claude}"
DB_MEM="$RM_HOME/memories.db"
DB_CONV="$RM_HOME/conversations.db"
LOG="$RM_HOME/logs/hook-failures.log"

# ── which machine is writing this? ──────────────────────────────────────────
# 🔴 Always record it. The moment two machines' databases are merged, a row
#    without source_machine is unattributable forever.
MACHINE="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo UNKNOWN)"

logfail() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '[%s] %s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" "$MACHINE" "$1" >> "$LOG" 2>/dev/null
}

# ── read the Stop hook payload ──────────────────────────────────────────────
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

# ── locate the session transcript ───────────────────────────────────────────
jsonl=""
[ -n "$session_id" ] && jsonl=$(find "$HOME/.claude/projects" -name "${session_id}.jsonl" 2>/dev/null | head -1)
[ -z "$jsonl" ] && jsonl=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
[ -f "${jsonl:-}" ] || exit 0

# ── last user + last assistant TEXT ─────────────────────────────────────────
# NOTE: if the final entries are tool calls with no text block these come back
# empty and the hook exits. That is correct — and it is why you cannot test
# this mid-session. Test with a small fake .jsonl containing real text.
last_user=$(grep '"type":"user"' "$jsonl" 2>/dev/null | tail -1 | jq -r '
  if .message.content | type == "string" then .message.content
  else (.message.content // [] | map(select(.type=="text") | .text) | join("")) end // ""
' 2>/dev/null | cut -c1-4000)

last_asst=$(grep '"type":"assistant"' "$jsonl" 2>/dev/null | tail -1 | jq -r '
  [.message.content[]? | select(.type=="text") | .text] | join("") // ""
' 2>/dev/null | cut -c1-6000)

[ -z "$last_user" ] && [ -z "$last_asst" ] && exit 0

mkdir -p "$RM_HOME"
ts=$(date -u +%Y-%m-%dT%H:%M:%S)
u=$(printf '%s' "$last_user" | sed "s/'/''/g")
a=$(printf '%s' "$last_asst" | sed "s/'/''/g")
sid="${session_id:-unknown}"

# ── TRUNK ───────────────────────────────────────────────────────────────────
out=$(sqlite3 "$DB_MEM" "
  INSERT INTO memories (timestamp, memory_type, content, importance, agent_id, keywords, source_machine)
  VALUES ('$ts','conversation','User: $u

Assistant: $a', 6, '$RM_AGENT_ID', 'conversation,auto-saved', '$MACHINE');
  SELECT last_insert_rowid();" 2>&1)

if printf '%s' "$out" | grep -qiE '^Error|no such table|locked|readonly|disk I/O'; then
  logfail "TRUNK memories.db: $out"; mem_id=""
else
  mem_id="$out"
fi

# ── BRANCH ──────────────────────────────────────────────────────────────────
uid=$(sqlite3 "$DB_CONV" "INSERT INTO conversations (session_id,timestamp,agent_id,role,content)
      VALUES ('$sid','$ts','$RM_AGENT_ID','user','$u'); SELECT last_insert_rowid();" 2>/dev/null)
aid=$(sqlite3 "$DB_CONV" "INSERT INTO conversations (session_id,timestamp,agent_id,role,content)
      VALUES ('$sid','$ts','$RM_AGENT_ID','assistant','$a'); SELECT last_insert_rowid();" 2>/dev/null)

if [ -z "$uid" ] || [ -z "$aid" ]; then
  logfail "BRANCH conversations.db: no rowid returned (table missing, or DB locked?)"
fi

# ── JOIN ────────────────────────────────────────────────────────────────────
# Writing the same link again strengthens it rather than duplicating it.
if [ -n "$mem_id" ] && [ -n "$uid" ] && [ -n "$aid" ]; then
  for t in "$uid" "$aid"; do
    ex=$(sqlite3 "$DB_MEM" "SELECT id FROM memory_links
         WHERE source_id=$mem_id AND target_db='conversations' AND target_id=$t;" 2>/dev/null)
    if [ -n "$ex" ]; then
      sqlite3 "$DB_MEM" "UPDATE memory_links SET strength=MIN(strength+0.1,10.0) WHERE id=$ex;" 2>/dev/null
    else
      sqlite3 "$DB_MEM" "INSERT INTO memory_links
        (timestamp,source_db,source_id,target_db,target_id,target_table,link_type,session_id,strength)
        VALUES ('$ts','memories',$mem_id,'conversations',$t,'conversations','conversation','$sid',1.0);" 2>/dev/null
    fi
  done
fi

exit 0
