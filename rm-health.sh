#!/bin/bash
# ============================================================================
#  rm-health.sh — integrity check for rangers-memories databases
# ----------------------------------------------------------------------------
#  Answers the question schema.sql cares about most: do the links still point
#  at the RIGHT exchanges? A dangling link is visible. A link that resolves to
#  the wrong conversation is not — and that is the one that matters.
#
#  Check the installed databases:
#      ./rm-health.sh
#
#  Inspect another machine's pair BEFORE merging it in:
#      ./rm-health.sh --source /path/to/incoming
#
#  Exit status: 0 clean · 1 problems found · 2 could not run
#
#  REQUIRES: sqlite3
# ============================================================================
set -uo pipefail

DIR="${RM_HOME:-$HOME/.rangers-memories}"
LABEL="installed"

while [ $# -gt 0 ]; do
  case "$1" in
    --source) DIR="${2:-}"; LABEL="source"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

command -v sqlite3 >/dev/null || { echo "sqlite3 not found" >&2; exit 2; }
[ -n "$DIR" ] || { echo "--source needs a directory" >&2; exit 2; }

DB_MEM="$DIR/memories.db"
DB_CONV="$DIR/conversations.db"

for f in "$DB_MEM" "$DB_CONV"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

# sqlite3 string literals escape a single quote by doubling it
esc_conv=$(printf '%s' "$DB_CONV" | sed "s/'/''/g")

problems=0
flag() { problems=$((problems + 1)); }

# one query against memories.db with conversations.db attached as c
q() { sqlite3 "$DB_MEM" "ATTACH '$esc_conv' AS c; $1" 2>/dev/null; }
num() { local v; v=$(q "$1"); printf '%s' "${v:-0}"; }

echo "rangers-memories health — $LABEL"
echo "  $DIR"
echo

# ── inventory ───────────────────────────────────────────────────────────────
mem=$(num   "SELECT COUNT(*) FROM memories;")
auto=$(num  "SELECT COUNT(*) FROM memories WHERE memory_type='conversation';")
conv=$(num  "SELECT COUNT(*) FROM c.conversations;")
links=$(num "SELECT COUNT(*) FROM memory_links;")

echo "── inventory ──"
printf '  %-24s %s\n' "memories"        "$mem"
printf '  %-24s %s\n' "  of which auto" "$auto"
printf '  %-24s %s\n' "conversations"   "$conv"
printf '  %-24s %s\n' "memory_links"    "$links"
echo

if [ "$mem" -gt 0 ]; then
  echo "── memory_type breakdown ──"
  q "SELECT '  ' || printf('%-22s', COALESCE(memory_type,'(null)')) || COUNT(*)
     FROM memories GROUP BY memory_type ORDER BY COUNT(*) DESC;"
  echo
fi

# ── trunk / branch ratio ────────────────────────────────────────────────────
# The hook writes 1 memory + 2 conversation rows per exchange, so a healthy
# fleet has roughly twice as many conversation rows as auto-saved memories.
if [ "$auto" -gt 0 ]; then
  echo "── trunk / branch ratio ──"
  printf '  %-24s %s\n' "expected conversations" "~$((auto * 2))"
  printf '  %-24s %s\n' "actual"                 "$conv"
  if [ "$conv" -lt "$auto" ]; then
    echo "  ✗ fewer conversation rows than auto-saved memories — the branch is"
    echo "    missing data. Importing memories.db without conversations.db does"
    echo "    exactly this."
    flag
  elif [ "$conv" -lt $((auto * 2)) ]; then
    echo "  ! below the expected pair count — some exchanges lost a role row"
  else
    echo "  ✓ consistent with one user+assistant pair per auto-save"
  fi
  echo
fi

# ── link integrity ──────────────────────────────────────────────────────────
echo "── link integrity ──"

orphan=$(num "SELECT COUNT(*) FROM memory_links l
              LEFT JOIN memories m ON m.id = l.source_id
              WHERE m.id IS NULL;")
printf '  %-34s %s\n' "links whose memory is gone" "$orphan"
[ "$orphan" -gt 0 ] && flag

dang_nat=$(num "SELECT COUNT(*) FROM memory_links l
                LEFT JOIN c.conversations v
                  ON v.session_id = l.session_id AND v.timestamp = l.timestamp
                WHERE l.target_db = 'conversations' AND v.id IS NULL;")
printf '  %-34s %s\n' "dangling by natural key" "$dang_nat"
[ "$dang_nat" -gt 0 ] && flag

dang_id=$(num "SELECT COUNT(*) FROM memory_links l
               LEFT JOIN c.conversations v ON v.id = l.target_id
               WHERE l.target_db = 'conversations' AND v.id IS NULL;")
printf '  %-34s %s\n' "dangling by target_id" "$dang_id"

# The silent one: target_id resolves to a row, but NOT the row the natural key
# names. This is a link quietly pointing at somebody else's exchange.
wrong=$(num "SELECT COUNT(*) FROM memory_links l
             JOIN c.conversations v ON v.id = l.target_id
             WHERE l.target_db = 'conversations'
               AND (v.session_id <> l.session_id OR v.timestamp <> l.timestamp);")
printf '  %-34s %s\n' "target_id → WRONG exchange" "$wrong"
if [ "$wrong" -gt 0 ]; then
  echo "    ✗ these resolve silently to the wrong conversation. Resolve by"
  echo "      session_id + timestamp instead — never by target_id."
  flag
fi
echo

# ── attribution ─────────────────────────────────────────────────────────────
echo "── attribution ──"
unattr=$(num "SELECT COUNT(*) FROM memories
              WHERE source_machine IS NULL OR TRIM(source_machine) = '';")
printf '  %-34s %s\n' "memories without source_machine" "$unattr"
if [ "$unattr" -gt 0 ]; then
  echo "    ✗ unattributable once databases are merged. Set it before importing."
  flag
fi
if [ "$mem" -gt 0 ]; then
  q "SELECT '  ' || printf('%-32s', COALESCE(NULLIF(TRIM(source_machine),''),'(unset)')) || COUNT(*)
     FROM memories GROUP BY source_machine ORDER BY COUNT(*) DESC;"
fi
echo

# ── retrieval reminder ──────────────────────────────────────────────────────
if [ "$auto" -gt 0 ]; then
  echo "── retrieval ──"
  printf '  %s auto-saves sit at importance 6.\n' "$auto"
  echo "  Never ORDER BY importance when hunting for one — order by timestamp."
  echo
fi

# ── hook failures ───────────────────────────────────────────────────────────
LOG="$DIR/logs/hook-failures.log"
echo "── hook failures ──"
if [ -s "$LOG" ]; then
  echo "  $(wc -l < "$LOG") logged — most recent:"
  tail -3 "$LOG" | sed 's/^/    /'
  flag
else
  echo "  ✓ none (silence here means the hook is healthy)"
fi
echo

# ── verdict ─────────────────────────────────────────────────────────────────
if [ "$problems" -eq 0 ]; then
  echo "✓ clean"
  exit 0
fi
echo "✗ $problems problem area(s) above"
exit 1
