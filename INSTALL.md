# INSTALL — hand this file to your AI

> **To the human:** open whichever coding assistant you use in this repo —
> Claude Code, Cursor, Codex, Gemini CLI, Aider, anything with shell access —
> and say *"read INSTALL.md and install it"*.
>
> Then stop reading. The rest is written for the agent.

> **Note on what installs what.** The hook itself is **Claude Code specific** —
> it uses Claude Code's `Stop` event and reads its session transcripts. But any
> agent can perform the installation. You do not need Claude Code to set it up,
> only to use it.

---

## Instructions for the agent

You are installing `rangers-memories` — a `Stop` hook that writes each exchange
into two SQLite databases, so Claude Code sessions stop being amnesiac.

These steps use only `bash`, `sqlite3` and `jq`. Nothing here is specific to
which assistant you are. If you cannot run shell commands, say so and stop.

Work through these steps **in order**. Verify each before moving on. If a step
fails, stop and report rather than continuing — a half-installed hook is worse
than none, because it fails silently.

**Do not** run any step that would overwrite user data. Two places need real
care: their existing `~/.claude/settings.json`, and any database that already
exists. Both are handled below.

---

### 1 · Check prerequisites

```bash
command -v sqlite3 && command -v jq
```

Both are required. If either is missing, stop and tell the user to install it
(`brew install sqlite jq` on macOS, `apt install sqlite3 jq` on Debian/Ubuntu).

---

### 2 · Choose the location and create it

Default is `~/.rangers-memories`. If `RM_HOME` is already set in their shell,
use that instead and say so.

```bash
RM_HOME="${RM_HOME:-$HOME/.rangers-memories}"
mkdir -p "$RM_HOME/logs"
```

---

### 3 · Create the databases — never overwrite

The schema uses `CREATE TABLE IF NOT EXISTS` throughout, so this is safe to run
against existing files. **Check first anyway** and report what you find:

```bash
for db in memories conversations; do
  if [ -f "$RM_HOME/$db.db" ]; then
    echo "$db.db exists — $(sqlite3 "$RM_HOME/$db.db" 'SELECT COUNT(*) FROM sqlite_master WHERE type="table";') tables, leaving data alone"
  fi
  sqlite3 "$RM_HOME/$db.db" < schema/schema.sql
done
```

Verify both have the expected tables before continuing:

```bash
sqlite3 "$RM_HOME/memories.db"      ".tables"
sqlite3 "$RM_HOME/conversations.db" ".tables"
```

You want `memories`, `conversations` and `memory_links` present.

---

### 4 · Install the hook script

```bash
mkdir -p ~/.claude/hooks
cp hooks/save-conversation.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/save-conversation.sh
bash -n ~/.claude/hooks/save-conversation.sh && echo "syntax OK"
```

---

### 5 · 🔴 Wire it into settings.json — the careful step

The user may already have hooks. **Do not write the file wholesale.** Back it
up, then merge with `jq`, and skip if it is already there.

```bash
S=~/.claude/settings.json
[ -f "$S" ] || echo '{}' > "$S"
cp "$S" "$S.bak.$(date +%Y%m%d%H%M%S)"

CMD='bash ~/.claude/hooks/save-conversation.sh'

if jq -e --arg c "$CMD" '[.. | .command? // empty] | index($c)' "$S" >/dev/null 2>&1; then
  echo "already wired — nothing to do"
else
  jq --arg c "$CMD" '.hooks.Stop = ((.hooks.Stop // []) +
      [{"hooks":[{"type":"command","command":$c}]}])' "$S" > "$S.tmp" \
    && mv "$S.tmp" "$S" && echo "hook added"
fi

jq . "$S" >/dev/null && echo "settings.json still valid JSON"
```

**If the final validation fails, restore the backup immediately** and report.
A malformed `settings.json` stops Claude Code starting.

---

### 6 · Test it properly

⚠️ **You cannot test this mid-session.** The hook reads the *last* user and
assistant messages from the transcript; during a live session those are tool
calls with no text block, both come back empty, and the hook correctly exits
doing nothing. That is not a failure — it is the guard working.

Test with a small fake transcript instead:

```bash
mkdir -p ~/.claude/projects/_rmtest
J=~/.claude/projects/_rmtest/rmtest.jsonl
cat > "$J" <<'JS'
{"type":"user","message":{"role":"user","content":"install test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"install test reply"}]}}
JS
before=$(sqlite3 "$RM_HOME/memories.db" 'SELECT COUNT(*) FROM memories;')
echo '{"session_id":"rmtest"}' | bash ~/.claude/hooks/save-conversation.sh
after=$(sqlite3 "$RM_HOME/memories.db" 'SELECT COUNT(*) FROM memories;')
echo "memories: $before → $after"
sqlite3 "$RM_HOME/conversations.db" 'SELECT COUNT(*) FROM conversations;'
sqlite3 "$RM_HOME/memories.db"      'SELECT COUNT(*) FROM memory_links;'
cat "$RM_HOME/logs/hook-failures.log" 2>/dev/null || echo "no failures logged"
```

**Expect:** memories +1, conversations +2, memory_links +2, and no failure log.

Then clean up the test rows and the fake transcript:

```bash
sqlite3 "$RM_HOME/memories.db"      "DELETE FROM memories WHERE content LIKE '%install test%';"
sqlite3 "$RM_HOME/conversations.db" "DELETE FROM conversations WHERE content LIKE '%install test%';"
rm -rf ~/.claude/projects/_rmtest
```

---

### 7 · Report back

Tell the user plainly:

- where the databases are, and whether they were created or already existed
- that the hook is wired, and where the `settings.json` backup is
- the test result — the three row counts
- **that it takes effect on the next session**, not this one
- that `docs/retrieval-playbook.md` is the file to read before searching, and
  the one rule that matters: **never order by importance when hunting for an
  auto-save** — they sit at importance 6 and sorting by importance buries them

Do **not** claim it is working if the test did not produce the expected counts.
Say what happened.

---

## If something breaks later

```bash
cat ~/.rangers-memories/logs/hook-failures.log
```

Silence there means the hook is healthy. The log exists because a broken
database branch is otherwise indistinguishable from one that simply was not
triggered — which is how a fault can sit unnoticed for weeks.

**To uninstall:** remove the `Stop` entry from `settings.json`, delete
`~/.claude/hooks/save-conversation.sh`. The databases are yours; nothing else
touches them.
