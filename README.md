# rangers-memories

**Give Claude Code a memory that survives the session.**

```
Open Claude Code in this repo and say:  read INSTALL.md and install it
```

Claude Code forgets everything when a session ends. This is a small, boring,
dependency-free fix: a `Stop` hook that writes every exchange into SQLite, and a
retrieval method for getting it back out months later.

No framework. No vector database. No embeddings. Two SQLite files, a shell
script, and a discipline.

---

## The shape of it

```
        TRUNK                    BRANCH                   JOIN
   memories.db              conversations.db          memory_links
   one searchable row       user + assistant          what makes them
   per exchange             kept apart                one system
```

The join is the part that matters. A conversation log alone is unsearchable; a
summary alone loses the detail. Keeping both, linked, means you can search the
summary and then read the exact exchange it came from.

`memory_links.strength` rises by 0.1 each time the same link is written again.
Repetition reinforces. It is not a metaphor for anything; it is just a number
that goes up when something keeps coming back.

---

## Install — give it to Claude

Open **Claude Code** in this repo and say:

> **read INSTALL.md and install it**

That is the whole installation. [`INSTALL.md`](INSTALL.md) is a runbook written
for an agent to execute rather than a human to follow. It checks prerequisites,
creates the databases **without touching any that already exist**, merges into
your `settings.json` with `jq` instead of overwriting it, backs it up first,
tests end to end, cleans up after itself, and is told in plain terms not to
report success unless the test actually passed.

Takes about thirty seconds. It takes effect on your **next** session, not the
current one.

### Using a different assistant?

Any agent with shell access can do the install — **Cursor, Codex, Gemini CLI,
Aider**, whatever you have. Same instruction, same file. The runbook uses only
`bash`, `sqlite3` and `jq` and is not specific to any one assistant.

One thing to be clear about: **the hook itself is Claude Code specific.** It
uses Claude Code's `Stop` event and reads its session transcripts. So you do not
need Claude Code to *install* it — only to *use* it.

### Or run the installer

```bash
./install.sh              # install, test end to end, report honestly
./install.sh --check      # what is installed? changes nothing
./install.sh --uninstall  # remove the hook, keep every database
```

Same steps as the runbook, one command. Safe to re-run — it never overwrites a
database and never replaces `settings.json`. Once installed, `rm-health.sh`
reports on the state of your databases, and is worth running against another
machine's pair **before** merging it in:

```bash
~/.rangers-memories/rm-health.sh --source /path/to/incoming
```

### Or do it by hand

```bash
mkdir -p ~/.rangers-memories
sqlite3 ~/.rangers-memories/memories.db      < schema/schema.sql
sqlite3 ~/.rangers-memories/conversations.db < schema/schema.sql
mkdir -p ~/.claude/hooks
cp hooks/save-conversation.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/save-conversation.sh
```

Then add to `~/.claude/settings.json` — **merge this in, do not replace the file
if you already have hooks**:

```json
{ "hooks": { "Stop": [ { "hooks": [
  { "type": "command", "command": "bash ~/.claude/hooks/save-conversation.sh" }
] } ] } }
```

Requires `sqlite3` and `jq`. Set `RM_HOME` and `RM_AGENT_ID` if you want them
elsewhere.

---

## Two kinds of memory, and you need both

**Auto-saved** exchanges land at **importance 6**. They catch what you did not
know was important. Cheap, automatic, and the reason nothing is ever truly lost.

**Curated** entries are written deliberately — a decision, a diagnosis, a thing
learned — at importance 9 and above, in the words you will later search for.

The difference matters more than it sounds. A fault diagnosed in one project
lived for eleven days only as two auto-saved exchanges. It survived, which was
the point — but recovering it took four failed searches. Rewritten as one
curated entry, it came back on the first query.

> **Auto-save catches what you did not know was important.
> Curation makes it findable when you need it.**

---

## Reading it back

The retrieval method is in [`docs/retrieval-playbook.md`](docs/retrieval-playbook.md)
and is the single most useful file here. The headline:

> 🔴 **Never order by importance when hunting for something that might be an
> auto-save.** They sit at 6; curated entries sit at 9–20. Sorting by importance
> buries every auto-save under unrelated high-value rows.

Order by **date**. Narrow by **date range**. Search the **phrasing**, not the
topic — error strings and command names are the strongest keys there are.

---

## Why it works without embeddings

It searches words, and recall is associative rather than indexed. A phrase like
*"that boot problem"* pulls a fragment; the fragment names a session summary;
the summary lists IDs; one of those is the whole answer.

Session roll-ups turn out to be an index that forms by accident — nobody designs
it, it appears because summaries list what they summarise.

---

## 🔴 If you sync across machines, read this

`memory_links.target_id` is an autoincrement id from **one** machine's
`conversations.db`. Sync `memories.db` between machines without syncing
`conversations.db` and a link written on machine A arrives on machine B
pointing at B's row with the same number — **a different exchange.** It does
not error. It resolves to the wrong conversation, silently.

Measured on a real three-machine fleet:

| machine | links | conversation rows | |
|---|---:|---:|---|
| A | 7,986 | 8,130 | healthy |
| B | 1,844 | **0** | every link dangling |
| C | 2,522 | 1,378 | 1,144+ wrong or dangling |

**Resolve by natural key instead** — `session_id + timestamp`. Both are written
by the same hook in the same instant, both are globally unique, neither is
machine-local:

```sql
SELECT v.role, v.content
FROM memory_links l
JOIN conversations v
  ON v.session_id = l.session_id
 AND v.timestamp  = l.timestamp
WHERE l.source_id = :memory_id;
```

It returns the **user + assistant pair**, which is correct: a memory *is* an
exchange. On a single machine `target_id` works fine — this only bites the
moment you add a second one.

---

## What is not here

Sync between machines, importance-scale tuning, and branching to extra databases
by keyword are all straightforward extensions. The `memory_links` table already
takes an arbitrary `target_db`, so adding your own branch is a few lines in the
hook.

Every row carries `source_machine`. **Set it.** The moment two machines'
databases are merged, a row without it is unattributable forever.

---

## Licence

MIT. It is two hundred lines of shell and some SQL — take it.
