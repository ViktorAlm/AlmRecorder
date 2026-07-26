import GRDB

/// Owns the MCP lexical indexes so migration backfill and synchronization tests exercise the
/// exact same SQL. The FTS rows intentionally contain only visible utterances.
enum MCPFTSIndex {
    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS utterance_fts USING fts5(
                text,
                tokenize = 'unicode61 remove_diacritics 2'
            )
        """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS recording_title_fts USING fts5(
                title,
                tokenize = 'unicode61 remove_diacritics 2'
            )
        """)

        try db.execute(sql: "DELETE FROM utterance_fts")
        try db.execute(sql: """
            INSERT INTO utterance_fts(rowid, text)
            SELECT id, text FROM utterances WHERE is_hidden = 0
        """)
        try db.execute(sql: "DELETE FROM recording_title_fts")
        try db.execute(sql: """
            INSERT INTO recording_title_fts(rowid, title)
            SELECT id, title FROM recordings
        """)

        for trigger in [
            "mcp_utterance_fts_insert",
            "mcp_utterance_fts_update",
            "mcp_utterance_fts_delete",
            "mcp_recording_title_fts_insert",
            "mcp_recording_title_fts_update",
            "mcp_recording_title_fts_delete"
        ] {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
        }

        try db.execute(sql: """
            CREATE TRIGGER mcp_utterance_fts_insert
            AFTER INSERT ON utterances
            WHEN NEW.is_hidden = 0
            BEGIN
                INSERT INTO utterance_fts(rowid, text) VALUES (NEW.id, NEW.text);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER mcp_utterance_fts_update
            AFTER UPDATE OF text, is_hidden ON utterances
            BEGIN
                DELETE FROM utterance_fts WHERE rowid = OLD.id;
                INSERT INTO utterance_fts(rowid, text)
                SELECT NEW.id, NEW.text WHERE NEW.is_hidden = 0;
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER mcp_utterance_fts_delete
            AFTER DELETE ON utterances
            BEGIN
                DELETE FROM utterance_fts WHERE rowid = OLD.id;
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER mcp_recording_title_fts_insert
            AFTER INSERT ON recordings
            BEGIN
                INSERT INTO recording_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER mcp_recording_title_fts_update
            AFTER UPDATE OF title ON recordings
            BEGIN
                DELETE FROM recording_title_fts WHERE rowid = OLD.id;
                INSERT INTO recording_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER mcp_recording_title_fts_delete
            AFTER DELETE ON recordings
            BEGIN
                DELETE FROM recording_title_fts WHERE rowid = OLD.id;
            END
        """)
    }
}
