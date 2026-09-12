# 🔍 Memory Retrieval Playbook

**Written 11 Sep 2026, after it took four attempts to find a diagnosis that was sitting right there.**

> **The principle:**
> *"It is our problem to find the data, it's not the data's fault, so we need to learn how to
> find the data."*
>
> The memory works like human memory — on words and what happened, not on tags. A phrase like
> *"kali boot problems"* brings the conversation back. That is **reconstructive recall**, and it is
> the same thing the user documented as his seventh novel finding: *"The database is not the memory.
> The conversation IS the memory."*

---

## The trap that costs the most time

**Auto-saved conversation turns are stored at importance 6** with a `the user asked:` prefix. Curated
entries sit at 9–20.

So **any search ordered by importance buries every auto-save** under unrelated high-value entries.
On 11 Sep a search for the ASUS Kali fault returned Colab training fixes, base-model selection and
ISACA membership — all importance 18, none relevant. The answer was four rows down in a different
ordering.

**→ Never order by importance when hunting for something that might be an auto-save.**

---

## The order that works

### 1 · Keyword, ordered by DATE, not importance

```sql
SELECT id||' | '||date(timestamp)||' | '||substr(content,1,300) FROM memories
WHERE content LIKE '%asus%' COLLATE NOCASE
ORDER BY timestamp DESC LIMIT 8;
```

`COLLATE NOCASE` matters. So does `substr` — full rows flood the screen and hide the hit.

### 2 · Narrow by date range once you know roughly when

The single most effective move. If you can place it within a week, this almost always lands it:

```sql
WHERE date(timestamp) BETWEEN '2026-08-30' AND '2026-09-01'
  AND (content LIKE '%kali%' COLLATE NOCASE OR content LIKE '%apt%' COLLATE NOCASE)
```

### 3 · Follow the breadcrumbs

**Roll-up memories are an index that formed by accident.** Session summaries list other memory IDs
with one-line descriptions:

```
| 18392 | 11 | ASUS SSH + the Windows administrators_authorized_keys gotcha |
```

That line is how the ASUS thread was found. When a search returns a roll-up, **read its ID list** —
it is a table of contents someone already wrote.

```sql
SELECT content FROM memories WHERE id=18392;
```

### 4 · Search the phrasing, not the topic

The memory holds **what was said**, so search the way it would have been written at the time.
Not `desktop environment failure` — try `gdm`, `gnome`, `apt`, `tty`, `grub`, `recovery`.
Error strings and command names are the strongest keys there are.

### 5 · Widen with OR, then narrow

```sql
WHERE (content LIKE '%gnome%' COLLATE NOCASE OR content LIKE '%gdm%' COLLATE NOCASE
    OR content LIKE '%dpkg%' COLLATE NOCASE OR content LIKE '%tty%' COLLATE NOCASE)
```

---

## The one thing worth doing at write time

Capture is automatic and that is the win — **you cannot retrieve what was never saved.**

But when something is diagnosed, decided or learned, **write a curated entry as well.** Not tags — a
proper account, in the words that will be used to look for it later, at an importance that reflects
what it is.

The ASUS fault lived for eleven days as two conversation turns. It survived, which is the point. But
it cost four searches to recover. Rewritten as one curated entry at importance 11, it now comes back
on the first query.

**Auto-save catches what you did not know was important. Curation makes it findable when you need
it. Both, and the second one takes deliberate effort.**

---

## Quick commands

```bash
DB=~/.rangers-memories/memories.db

# recent, any topic
sqlite3 "$DB" "SELECT id,date(timestamp),substr(content,1,90) FROM memories ORDER BY timestamp DESC LIMIT 15;"

# keyword by date
sqlite3 "$DB" "SELECT id,date(timestamp),substr(content,1,200) FROM memories
               WHERE content LIKE '%KEYWORD%' COLLATE NOCASE ORDER BY timestamp DESC LIMIT 10;"

# a specific entry in full
sqlite3 "$DB" "SELECT content FROM memories WHERE id=NNNNN;"

# what the other machines have been doing
sqlite3 "$DB" "SELECT source_machine, COUNT(*), max(date(timestamp))
               FROM memories GROUP BY source_machine ORDER BY COUNT(*) DESC;"

# integrity check across both databases
~/.rangers-memories/rm-health.sh
```
