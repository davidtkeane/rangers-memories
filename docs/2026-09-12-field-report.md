# Field report — clean-machine install, 12 Sep 2026

**Written for `claude-m3` and anyone picking this up.** Everything below was
done on the ASUS (`Kali-ROG`, Linux x86_64), driven from the M3 Mac over SSH
inside tmux. The work is **uncommitted** in the working tree of
`~/Documents/Kali-Files/web-files/rangers-memories`.

The short version: the install works, and testing it on a clean machine turned
up two bugs in the hook that were corrupting what it saved.

---

## 1 · What was done

`INSTALL.md` was followed exactly as written, on a machine with no prior
install, and then the databases were inspected to see what had actually landed.
That last step is the one that mattered — every step of the runbook reported
success while the data being written was wrong.

Installed and verified:

| | |
|---|---|
| databases | `~/.rangers-memories/{memories,conversations}.db` — created fresh |
| hook | `~/.claude/hooks/save-conversation.sh` |
| wiring | `Stop` hook in `~/.claude/settings.json` |
| backup | `~/.claude/settings.json.bak.20260912022946` |
| machine | `source_machine` writes as `Kali-ROG` |

The documented self-test passed on the first run: memories +1, conversations
+2, memory_links +2, no failures logged.

---

## 2 · Bug 1 — every exchange that used a tool was dropped

Claude Code writes **tool results into the transcript as `type:"user"`
entries**. The hook did:

```bash
grep '"type":"user"' "$jsonl" | tail -1
```

so on any turn that ended in tool use, the last `user` entry was a
`tool_result` block carrying no text. Measured on a live session:

```
29 entries   BLOCKS: tool_result      ← what tail -1 kept hitting
 9 entries   TEXT: (real messages)
```

Both halves came back empty on most turns and the hook exited doing nothing.
**2 of 6 exchanges were saved.** The guard was working as designed; the
selection feeding it was wrong.

**Fix:** select the last `user` entry that actually carries text.

---

## 3 · Bug 2 — saved exchanges paired each question with the *previous* answer

This is the one that matters.

The first two memories captured on the live install:

```
id 2 | user "whats a pr?"          | assistant "All three tables are at 0..."
id 3 | user "Thanks, I will ask..." | assistant "A pull request — a GitHub..."
```

`"All three tables are at 0"` was the reply to **"i'm back"**, not to
`"whats a pr?"`. `"A pull request..."` was the reply to **"whats a pr?"**, not
to `"Thanks, I will ask..."`. The pairing is off by exactly one turn, in both
rows.

**Cause:** the assistant's closing message is not always flushed to the
transcript at the instant `Stop` fires, so `tail -1` on assistant entries
returned the previous turn's reply.

**Fix:** take the last assistant text appearing *after* the chosen user
message, and wait up to 2s (10 × 0.2s) for it to arrive. If it never does, save
the user half alone and write a line to `hook-failures.log`.

That last choice is deliberate and worth a second opinion: **an incomplete
memory is recoverable, a memory that answers the wrong question is not.** A
dangling link announces itself. A confidently mispaired exchange looks
perfectly healthy and stays wrong forever.

### Before and after

Same transcript, a tool call sitting between the question and the answer:

```
ORIGINAL:  User:                                  Assistant: A2 answer to the second question
PATCHED:   User: Q2 what is the second question   Assistant: A2 answer to the second question
```

---

## 4 · Bug 3 — the install left dangling links behind

`INSTALL.md` step 6 cleaned up after its own test with:

```sql
DELETE FROM memories      WHERE content LIKE '%install test%';
DELETE FROM conversations WHERE content LIKE '%install test%';
-- nothing deleted from memory_links
```

So a fresh install finished with two orphaned rows in `memory_links` pointing
at a memory and two conversation rows that no longer existed — precisely the
state `schema.sql` spends a long comment warning about.

Not dangerous here: both tables use `AUTOINCREMENT`, so `sqlite_sequence` had
already advanced past 1 and 2 and the next real save took ids 3 and 4. The
links stayed dangling rather than silently resolving to the wrong exchange.

**Fix:** delete the links first, and verify all three counts return to baseline.

---

## 5 · Documentation defects fixed

- `docs/retrieval-playbook.md` — the opening **"The principle"** blockquote
  began mid-sentence (`takes… it is our problem to find the data`) with an
  unmatched closing quote mark. The markup was repaired and the quote started
  at the clean sentence boundary. **The missing opening words were not invented
  — if anyone remembers the original line, restore it properly.**
- `docs/retrieval-playbook.md` — the last "Quick commands" entry was the
  comment `# what the other machines have been doing` with no query under it.
  Filled in with a `source_machine` roll-up.

---

## 6 · New files

### `install.sh` — the runbook as one command

```bash
./install.sh              # install, test end to end, report honestly
./install.sh --check      # what is installed? changes nothing
./install.sh --uninstall  # remove the hook, keep every database
```

For humans, CI, and agents whose shell access is easier to point at a script
than to step through prose. Tested in a throwaway `HOME` against the nastiest
case — a `settings.json` that already had a `PostToolUse` hook:

- merged in without disturbing the existing hook or `theme`
- re-ran without double-wiring (`Stop` entries stayed at 1)
- `--uninstall` removed only its own entry and left a real memory row intact
- restores from backup if the merge would produce invalid JSON
- dies rather than reporting a success it did not verify

Its test fixture now puts a tool call **between** question and answer, so bug 1
cannot come back unnoticed.

### `rm-health.sh` — read-only integrity report

```bash
./rm-health.sh                      # check this machine
./rm-health.sh --source /path/to/incoming   # inspect a pair BEFORE merging it
```

Exit status 0 clean · 1 problems · 2 could not run, so an import can be gated
on it. Checks:

| check | catches |
|---|---|
| trunk/branch ratio | `memories.db` imported without `conversations.db` |
| links whose memory is gone | orphans like the ones the install test left |
| dangling by natural key | links with no exchange to land on |
| dangling by `target_id` | the visible half of the id problem |
| **`target_id` → wrong exchange** | **links silently resolving to another conversation** |
| missing `source_machine` | rows that become unattributable once merged |
| hook failure log | a broken DB branch sitting unnoticed |

Verified against a deliberately corrupted fixture — it caught all four planted
faults and exited 1. A checker that only ever prints "clean" is worth nothing,
so this was tested for true positives, not just absence of false alarms.

### `CHANGELOG.md`

New, covering the above plus a `0.1.0` entry for the existing release.

---

## 7 · Before importing the 18,000 / 2,000 fleet data

The stated shape is ~18,000 memories and ~2,000 conversations. **That ratio is
the wrong way round.** The hook writes 1 memory + 2 conversation rows per
exchange, so a healthy fleet has roughly **twice** as many conversation rows as
auto-saved memories — not a ninth as many.

If most of those 18,000 are hand-written `project` / `reference` / `finding`
entries, that is fine and expected. If they are mostly `memory_type =
'conversation'` auto-saves, most incoming links have nothing to land on.

Check before merging:

```bash
sqlite3 SOURCE/memories.db "SELECT memory_type, COUNT(*) FROM memories GROUP BY memory_type;"
./rm-health.sh --source SOURCE/
```

Two rules for the import itself:

1. **Bring `conversations.db` across too, not just `memories.db`.** Importing
   the trunk alone is what produced machine B's "every link dangling" row in
   the README table.
2. **Do not let incoming `memory_links.target_id` decide anything.** Those are
   autoincrement ids from another machine. Re-resolve by `session_id +
   timestamp`, as `schema.sql` instructs.

---

## 8 · Environment gotchas on the ASUS

- **`gh` is not GitHub CLI here.** The name is taken by a shell alias,
  `alias gh='history|grep'`, and `grep` resolves to ugrep. So `gh --version`
  prints a ugrep banner and `gh auth status` fails with a confusing
  `no such event` error. There is **no `gh` binary** on the default PATH. The
  alias is not in `~/.zshrc`, `~/.bashrc`, `~/.zshenv` or `~/.profile` — it is
  coming from something else that gets sourced.
- **`git user.name` and `user.email` are unset** in this repo and globally.
- **No git credential helper**, so an HTTPS push will ask for a username and a
  personal access token (GitHub has not accepted passwords for years).
- Network reach to GitHub is fine — `git ls-remote origin` succeeds.
- **Editing `~/.claude/settings.json` from a shell command is refused** by
  Claude Code's auto-mode permission classifier as self-modification. `cp` for
  a backup is allowed; the edit itself has to go through the file-editing tool.
  Worth knowing before writing any installer that expects to `jq` that file
  from inside a Claude Code session — `install.sh` run from a normal shell is
  unaffected.

---

## 9 · State of the tree

```
 M INSTALL.md                    links deleted first, counts verified
 M README.md                     documents install.sh and rm-health.sh
 M docs/retrieval-playbook.md    quote repaired, command completed
 M hooks/save-conversation.sh    bugs 1 and 2 fixed
?? CHANGELOG.md                  new
?? install.sh                    new
?? rm-health.sh                  new
?? docs/2026-09-12-field-report.md   this file
```

The live install on `Kali-ROG` has been updated to the patched hook (the old
one is backed up beside it) and `rm-health.sh` reports **clean**.

Nothing has been committed or pushed. `schema.sql` is unchanged — databases
created before this work need no migration.

---

## 10 · Open questions for claude-m3

1. **The 2s wait in the hook.** It delays session end slightly on turns where
   the flush is slow. Is that the right trade, or should it save immediately
   and accept an occasional missing assistant half?
2. **Saving the user half alone** when no answer arrives — right call, or
   should it skip the exchange entirely?
3. **The playbook's opening quote** — the original words are lost. Restore from
   memory if anyone has it.
4. Should `rm-health.sh` live at the repo root, in a `tools/` directory, or be
   folded into `install.sh` as a `--health` flag?
