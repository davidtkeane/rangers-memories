-- ============================================================================
--  rangers-memories — database schema
-- ----------------------------------------------------------------------------
--  Two databases, joined by a third table. That join is the whole idea:
--
--    memories.db        the TRUNK  — one searchable row per exchange
--    conversations.db   the BRANCH — user and assistant kept as separate rows
--    memory_links       the JOIN   — what makes them one system, not two files
--
--  Create with:
--    sqlite3 memories.db      < schema.sql   # creates memories + memory_links
--    sqlite3 conversations.db < schema.sql   # creates conversations
--  (each file simply ignores the tables it already has)
-- ============================================================================

-- ── TRUNK ───────────────────────────────────────────────────────────────────
-- One row per exchange. This is what you search.
CREATE TABLE IF NOT EXISTS memories (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp      TEXT,      -- ISO-8601 UTC
    memory_type    TEXT,      -- 'conversation' (auto) | 'project' | 'reference' | 'finding' | ...
    content        TEXT,      -- the text. Write it the way you will SEARCH for it later
    importance     INTEGER,   -- see docs/importance-scale.md. Auto-saves land at 6
    keywords       TEXT,      -- comma-separated
    category       TEXT,
    emotion        TEXT,
    agent_id       TEXT,      -- which assistant wrote it
    source_machine TEXT       -- 🔴 ALWAYS set this. Without it a merged row is
                              --    unattributable forever
);

CREATE INDEX IF NOT EXISTS idx_mem_time    ON memories(timestamp);
CREATE INDEX IF NOT EXISTS idx_mem_type    ON memories(memory_type);
CREATE INDEX IF NOT EXISTS idx_mem_machine ON memories(source_machine);

-- ── BRANCH ──────────────────────────────────────────────────────────────────
-- The raw exchange, roles kept apart so it can be replayed.
CREATE TABLE IF NOT EXISTS conversations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL,
    timestamp       TEXT NOT NULL,
    terminal        TEXT,
    agent_id        TEXT,
    role            TEXT,     -- 'user' | 'assistant'
    content         TEXT,
    context_percent REAL,
    tokens_used     INTEGER
);

CREATE INDEX IF NOT EXISTS idx_conv_session ON conversations(session_id);
CREATE INDEX IF NOT EXISTS idx_conv_time    ON conversations(timestamp);

-- ── JOIN ────────────────────────────────────────────────────────────────────
-- Lives in memories.db. Points at rows in any other database.
-- strength rises when the same link is written again — repetition reinforces.
CREATE TABLE IF NOT EXISTS memory_links (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp    TEXT,
    source_db    TEXT,              -- always 'memories'
    source_id    INTEGER,           -- memories.id
    target_db    TEXT,              -- 'conversations' | your own extra DBs
    target_id    INTEGER,
    target_table TEXT,
    link_type    TEXT,              -- 'conversation' | whatever you branch on
    session_id   TEXT,              -- groups every link from one session
    strength     REAL DEFAULT 1.0
);

CREATE INDEX IF NOT EXISTS idx_links_source  ON memory_links(source_id);
CREATE INDEX IF NOT EXISTS idx_links_session ON memory_links(session_id);
CREATE INDEX IF NOT EXISTS idx_links_target  ON memory_links(target_db, target_id);
