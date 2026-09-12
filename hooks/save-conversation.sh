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
# Tool results are written to the transcript as type:"user" entries too, so the
# LAST user entry is usually a tool_result carrying no text. Taking it blindly
# loses every exchange that ended in tool use. Select the last user entry that
# actually has text, then the last assistant text that appears AFTER it — that
# pair belongs to the same exchange.
#
# The assistant's closing message may not be flushed to the transcript at the
# instant Stop fires, so wait briefly for it. If it never arrives we save the
# user half alone and log it: an incomplete memory is recoverable, a memory
# pairing a question with the previous answer is quietly wrong forever.

user_text_lines() {
  jq -r 'input_line_number as $n | select(.type=="user")
    | ((.message.content) as $c
       | if ($c|type) == "string" then $c
         else ([$c[]? | select(.type=="text") | .text] | join("")) end) as $t
    | select(($t|length) > 0) | $n' "$jsonl" 2>/dev/null
}

asst_text_lines() {
  jq -r 'input_line_number as $n | select(.type=="assistant")
    | ([.message.content[]? | select(.type=="text") | .text] | join("")) as $t
    | select(($t|length) > 0) | $n' "$jsonl" 2>/dev/null
}

u_line=$(user_text_lines | tail -1)

a_line=""
if [ -z "$u_line" ]; then
  # nothing awaiting an answer — take any trailing assistant text, do not wait
  a_line=$(asst_text_lines | tail -1)
else
  tries=0
  while [ "$tries" -lt 10 ]; do
    a_line=$(asst_text_lines | awk -v u="$u_line" '$1 > u' | tail -1)
    [ -n "$a_line" ] && break
    tries=$((tries + 1))
    sleep 0.2 2>/dev/null || sleep 1
  done
fi

[ -z "$a_line" ] && [ -n "$u_line" ] && logfail "no assistant text after user line $u_line in $jsonl — saved user half only"

last_user=""
last_asst=""
[ -n "$u_line" ] && last_user=$(sed -n "${u_line}p" "$jsonl" | jq -r '
  if .message.content | type == "string" then .message.content
  else (.message.content // [] | map(select(.type=="text") | .text) | join("")) end // ""
' 2>/dev/null | cut -c1-4000)
[ -n "$a_line" ] && last_asst=$(sed -n "${a_line}p" "$jsonl" | jq -r '
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
