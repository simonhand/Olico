use std::path::Path;

use rusqlite::types::Value as SqlValue;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};

use crate::config::ClipboardConfig;
use crate::error::{CoreError, Result};
use crate::model::{ClipboardItem, ClipboardKind, Pinboard};

const SCHEMA_V1: &str = r#"
CREATE TABLE IF NOT EXISTS clipboard_items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  text TEXT,
  file_paths_json TEXT,
  image_path TEXT,
  thumb_path TEXT,
  hash TEXT NOT NULL UNIQUE,
  source_bundle TEXT,
  source_name TEXT,
  byte_size INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_items_created ON clipboard_items(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_items_pinned ON clipboard_items(pinned, created_at DESC);

CREATE TABLE IF NOT EXISTS pinboards (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pinboard_items (
  board_id TEXT NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
  item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (board_id, item_id)
);
"#;

const SCHEMA_VERSION: u32 = 1;

const ITEM_COLUMNS: &str = "id, kind, text, file_paths_json, image_path, thumb_path, hash, \
                            source_bundle, source_name, byte_size, created_at, pinned";

fn kind_str(kind: ClipboardKind) -> &'static str {
    match kind {
        ClipboardKind::Text => "text",
        ClipboardKind::Image => "image",
        ClipboardKind::File => "file",
    }
}

fn row_to_item(row: &Row<'_>) -> rusqlite::Result<ClipboardItem> {
    let raw_kind: String = row.get("kind")?;
    let kind: ClipboardKind =
        serde_json::from_value(serde_json::Value::String(raw_kind)).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e))
        })?;
    let raw_paths: Option<String> = row.get("file_paths_json")?;
    let file_paths = match raw_paths {
        Some(raw) if !raw.trim().is_empty() => serde_json::from_str(&raw).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e))
        })?,
        _ => Vec::new(),
    };
    let pinned: i64 = row.get("pinned")?;
    Ok(ClipboardItem {
        id: row.get("id")?,
        kind,
        text: row.get("text")?,
        file_paths,
        image_path: row.get("image_path")?,
        thumb_path: row.get("thumb_path")?,
        hash: row.get("hash")?,
        source_bundle: row.get("source_bundle")?,
        source_name: row.get("source_name")?,
        byte_size: row.get("byte_size")?,
        created_at: row.get("created_at")?,
        pinned: pinned != 0,
    })
}

#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardFiles {
    pub image_path: Option<String>,
    pub thumb_path: Option<String>,
}

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let conn = Connection::open(dir.join("olico.db"))?;
        conn.busy_timeout(std::time::Duration::from_secs(2))?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        let version: u32 = self
            .conn
            .pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version < SCHEMA_VERSION {
            self.conn.execute_batch(SCHEMA_V1)?;
            self.conn
                .pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        Ok(())
    }

    pub fn schema_version(&self) -> Result<u32> {
        Ok(self
            .conn
            .pragma_query_value(None, "user_version", |row| row.get(0))?)
    }

    pub fn journal_mode(&self) -> Result<String> {
        Ok(self
            .conn
            .pragma_query_value(None, "journal_mode", |row| row.get(0))?)
    }

    pub fn execute_for_test(&mut self, sql: &str) -> Result<()> {
        self.conn.execute_batch(sql)?;
        Ok(())
    }

    pub fn insert_clipboard(&mut self, item: &ClipboardItem) -> Result<()> {
        let paths = serde_json::to_string(&item.file_paths)?;
        self.conn.execute(
            "INSERT INTO clipboard_items
             (id, kind, text, file_paths_json, image_path, thumb_path, hash,
              source_bundle, source_name, byte_size, created_at, pinned)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                item.id,
                kind_str(item.kind),
                item.text,
                paths,
                item.image_path,
                item.thumb_path,
                item.hash,
                item.source_bundle,
                item.source_name,
                item.byte_size,
                item.created_at,
                item.pinned as i64,
            ],
        )?;
        Ok(())
    }

    pub fn find_clipboard_by_hash(&self, hash: &str) -> Result<Option<ClipboardItem>> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {ITEM_COLUMNS} FROM clipboard_items WHERE hash = ?1"
        ))?;
        let item = stmt.query_row([hash], row_to_item).optional()?;
        Ok(item)
    }

    pub fn get_clipboard(&self, id: &str) -> Result<Option<ClipboardItem>> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {ITEM_COLUMNS} FROM clipboard_items WHERE id = ?1"
        ))?;
        let item = stmt.query_row([id], row_to_item).optional()?;
        Ok(item)
    }

    pub fn touch_clipboard(&mut self, id: &str, created_at: i64) -> Result<()> {
        let changed = self.conn.execute(
            "UPDATE clipboard_items SET created_at = ?2 WHERE id = ?1",
            params![id, created_at],
        )?;
        if changed == 0 {
            return Err(CoreError::NotFound(format!("clipboard item {id}")));
        }
        Ok(())
    }

    pub fn list_clipboard_candidates(
        &self,
        board_id: Option<&str>,
        kind: Option<ClipboardKind>,
    ) -> Result<Vec<ClipboardItem>> {
        let mut sql = format!("SELECT {ITEM_COLUMNS} FROM clipboard_items WHERE 1 = 1");
        let mut args: Vec<SqlValue> = Vec::new();
        match board_id {
            Some("__pinned") => sql.push_str(" AND pinned = 1"),
            Some(id) => {
                sql.push_str(
                    " AND EXISTS (SELECT 1 FROM pinboard_items pi \
                     WHERE pi.item_id = clipboard_items.id AND pi.board_id = ?)",
                );
                args.push(SqlValue::Text(id.to_string()));
            }
            None => {}
        }
        if let Some(kind) = kind {
            sql.push_str(" AND kind = ?");
            args.push(SqlValue::Text(kind_str(kind).to_string()));
        }
        sql.push_str(" ORDER BY created_at DESC");
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn delete_clipboard(&mut self, id: &str) -> Result<Option<ClipboardItem>> {
        let item = self.get_clipboard(id)?;
        if item.is_some() {
            self.conn
                .execute("DELETE FROM clipboard_items WHERE id = ?1", [id])?;
        }
        Ok(item)
    }

    pub fn set_pinned(&mut self, id: &str, pinned: bool) -> Result<()> {
        let changed = self.conn.execute(
            "UPDATE clipboard_items SET pinned = ?2 WHERE id = ?1",
            params![id, pinned as i64],
        )?;
        if changed == 0 {
            return Err(CoreError::NotFound(format!("clipboard item {id}")));
        }
        Ok(())
    }

    pub fn create_pinboard(
        &mut self,
        id: &str,
        name: &str,
        color: &str,
        created_at: i64,
    ) -> Result<Pinboard> {
        let sort_order: i32 = self.conn.query_row(
            "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM pinboards",
            [],
            |row| row.get(0),
        )?;
        self.conn.execute(
            "INSERT INTO pinboards (id, name, color, sort_order, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, name, color, sort_order, created_at],
        )?;
        Ok(Pinboard {
            id: id.to_string(),
            name: name.to_string(),
            color: color.to_string(),
            sort_order,
            created_at,
            item_count: 0,
        })
    }

    pub fn rename_pinboard(&mut self, id: &str, name: &str) -> Result<()> {
        let changed = self.conn.execute(
            "UPDATE pinboards SET name = ?2 WHERE id = ?1",
            params![id, name],
        )?;
        if changed == 0 {
            return Err(CoreError::NotFound(format!("pinboard {id}")));
        }
        Ok(())
    }

    pub fn delete_pinboard(&mut self, id: &str) -> Result<()> {
        let changed = self
            .conn
            .execute("DELETE FROM pinboards WHERE id = ?1", [id])?;
        if changed == 0 {
            return Err(CoreError::NotFound(format!("pinboard {id}")));
        }
        Ok(())
    }

    pub fn list_pinboards(&self) -> Result<Vec<Pinboard>> {
        let mut stmt = self.conn.prepare(
            "SELECT b.id, b.name, b.color, b.sort_order, b.created_at, COUNT(pi.item_id)
             FROM pinboards b
             LEFT JOIN pinboard_items pi ON pi.board_id = b.id
             GROUP BY b.id
             ORDER BY b.sort_order, b.created_at",
        )?;
        let rows = stmt.query_map([], |row| {
            let item_count: i64 = row.get(5)?;
            Ok(Pinboard {
                id: row.get(0)?,
                name: row.get(1)?,
                color: row.get(2)?,
                sort_order: row.get(3)?,
                created_at: row.get(4)?,
                item_count: item_count as u32,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn board_exists(&self, id: &str) -> Result<bool> {
        let exists: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM pinboards WHERE id = ?1)",
            [id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    pub fn item_exists(&self, id: &str) -> Result<bool> {
        let exists: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM clipboard_items WHERE id = ?1)",
            [id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    pub fn add_pinboard_item(
        &mut self,
        board_id: &str,
        item_id: &str,
        added_at: i64,
    ) -> Result<()> {
        if !self.board_exists(board_id)? {
            return Err(CoreError::NotFound(format!("pinboard {board_id}")));
        }
        if !self.item_exists(item_id)? {
            return Err(CoreError::NotFound(format!("clipboard item {item_id}")));
        }
        self.conn.execute(
            "INSERT OR IGNORE INTO pinboard_items (board_id, item_id, added_at)
             VALUES (?1, ?2, ?3)",
            params![board_id, item_id, added_at],
        )?;
        Ok(())
    }

    pub fn remove_pinboard_item(&mut self, board_id: &str, item_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM pinboard_items WHERE board_id = ?1 AND item_id = ?2",
            params![board_id, item_id],
        )?;
        Ok(())
    }

    pub fn prune(&mut self, config: &ClipboardConfig, now: i64) -> Result<Vec<ClipboardFiles>> {
        let cutoff = now - (config.retention_days as i64) * 86_400_000;
        let tx = self.conn.transaction()?;
        let mut ids: Vec<String> = Vec::new();
        {
            let mut stmt = tx.prepare(
                "SELECT id FROM clipboard_items
                 WHERE created_at < ?1 AND pinned = 0
                   AND id NOT IN (SELECT item_id FROM pinboard_items)",
            )?;
            let rows = stmt.query_map([cutoff], |row| row.get::<_, String>(0))?;
            for row in rows {
                ids.push(row?);
            }
        }
        {
            let mut stmt = tx.prepare(
                "SELECT id FROM clipboard_items
                 WHERE pinned = 0
                   AND id NOT IN (SELECT item_id FROM pinboard_items)
                 ORDER BY created_at DESC",
            )?;
            let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
            for (index, row) in rows.enumerate() {
                let id = row?;
                if index >= config.max_items as usize {
                    ids.push(id);
                }
            }
        }
        ids.sort();
        ids.dedup();
        let mut files = Vec::new();
        for id in &ids {
            let row = tx
                .query_row(
                    "SELECT image_path, thumb_path FROM clipboard_items WHERE id = ?1",
                    [id],
                    |row| {
                        Ok(ClipboardFiles {
                            image_path: row.get(0)?,
                            thumb_path: row.get(1)?,
                        })
                    },
                )
                .optional()?;
            if let Some(row) = row {
                files.push(row);
            }
        }
        for id in &ids {
            tx.execute("DELETE FROM clipboard_items WHERE id = ?1", [id])?;
        }
        tx.commit()?;
        Ok(files)
    }

    pub fn referenced_files(&self) -> Result<Vec<ClipboardFiles>> {
        let mut stmt = self.conn.prepare(
            "SELECT image_path, thumb_path FROM clipboard_items
             WHERE image_path IS NOT NULL OR thumb_path IS NOT NULL",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(ClipboardFiles {
                image_path: row.get(0)?,
                thumb_path: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn clear_clipboard(&mut self) -> Result<Vec<ClipboardItem>> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {ITEM_COLUMNS} FROM clipboard_items"))?;
        let items = stmt
            .query_map([], row_to_item)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        self.conn.execute("DELETE FROM clipboard_items", [])?;
        Ok(items)
    }
}
