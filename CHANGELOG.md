# Changelog

All notable changes to `rangers-memories`.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Dates are ISO-8601.

---

## [Unreleased] — 2026-09-12

Found while installing the project from a clean machine (`Kali-ROG`) by
following `INSTALL.md` exactly as written, then checking what actually landed
in the databases.

### Fixed

- **The hook dropped every exchange that ended in tool use.** Tool results are
  written to the Claude Code transcript as `type:"user"` entries, so
  `grep '"type":"user"' | tail -1` returned a `tool_result` block carrying no
  text rather than the user's message. Measured on a live session: 29 of 38
  `user` entries were tool results, and only 2 of 6 exchanges were saved.
  The hook now selects the last user entry that actually contains text.

- **Saved exchanges paired each question with the *previous* answer.** The
  assistant's closing message is not always flushed to the transcript at the
  instant `Stop` fires, so the last assistant text belonged to the turn before.
  Both memories captured on the first live run were mispaired this way. The
  hook now takes the last assistant text appearing *after* the chosen user
  message, and waits up to two seconds for it to arrive.

  This one mattered most: a dangling link announces itself, but a memory that
  answers the wrong question looks perfectly healthy and is wrong forever.

- **The hook now logs when it saves a user message with no answer** rather than
  silently pairing it with unrelated text. An incomplete memory is recoverable;
  a confidently wrong one is not.

- **`INSTALL.md` step 6 left two dangling links behind.** The cleanup deleted
  the test rows from `memories` and `conversations` but never from
  `memory_links`, so a fresh install finished with exactly the orphaned-link
  state `schema.sql` spends a long comment warning about. Links are now deleted
  first, and the step verifies all three counts return to where they started.

- **`docs/retrieval-playbook.md`**: repaired the opening "The principle" quote,
  which began mid-sentence with an unmatched closing quote mark, and completed
  the final "Quick commands" entry, which was a comment with no query under it.

### Added

- **`install.sh`** — the runbook as one command, for people and for agents
  whose shell access is easier to point at a script than to step through prose.
  `--check` reports without changing anything; `--uninstall` removes the hook
  and leaves every database untouched. Safe to re-run: it never overwrites a
  database, never replaces `settings.json`, backs that file up before touching
  it, and restores the backup if the merge would produce invalid JSON. It fails
  loudly rather than reporting a success it did not verify.

- **`rm-health.sh`** — a read-only integrity report for the databases. Counts
  rows, breaks down `memory_type` and `source_machine`, checks the trunk/branch
  ratio, and reports four classes of link fault. The one worth having is
  **`target_id` → wrong exchange**: links that resolve silently to a different
  conversation, which no row count reveals. Run it with `--source DIR` against
  another machine's pair *before* merging it in. Exit status 0 clean, 1
  problems, 2 could not run, so an import can be gated on it.

### Notes

- The install test fixture in `install.sh` now includes a tool call between the
  question and the answer, so the pairing bug above cannot reappear unnoticed.
- Nothing in the schema changed. Databases created before this release are
  unaffected and need no migration.

---

## [0.1.0] — 2026-09-11

First public release.

- `Stop` hook writing each exchange to two SQLite databases joined by
  `memory_links`.
- `schema.sql`: `memories` (trunk), `conversations` (branch), `memory_links`
  (join), with the cross-machine `target_id` hazard documented from a measured
  three-machine fleet.
- `INSTALL.md`, a runbook written for an AI agent to execute.
- `docs/retrieval-playbook.md`, the retrieval method — written after a
  diagnosis took four attempts to find in a database that already held it.
