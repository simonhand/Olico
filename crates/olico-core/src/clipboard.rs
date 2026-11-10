use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use uuid::Uuid;

use crate::config::Config;
use crate::db::{ClipboardFiles, Store};
use crate::error::{CoreError, Result};
use crate::hash;
use crate::model::{ClipboardItem, ClipboardKind, ClipboardQuery, NewClipboardItem, Pinboard};
use crate::search;

pub struct Service {
    data_dir: PathBuf,
    config: Config,
    store: Store,
}

impl Service {
    pub fn open(dir: &Path) -> Result<Self> {
        let store = Store::open(dir)?;
        let config = Config::load(dir)?;
        let mut service = Self {
            data_dir: dir.to_path_buf(),
            config,
            store,
        };
        service.cleanup_orphans()?;
        service.prune_at(Self::now_ms())?;
        Ok(service)
    }

    pub fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as i64)
            .unwrap_or(0)
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn set_config(&mut self, config: Config) -> Result<()> {
        config.validate()?;
        config.save(&self.data_dir)?;
        self.config = config;
        Ok(())
    }

    pub fn clipboard_add(&mut self, input: NewClipboardItem, now: i64) -> Result<ClipboardItem> {
        let mut file_paths = input.file_paths.clone();
        let (hash, byte_size) = match input.kind {
            ClipboardKind::Text => {
                let text = input.text.as_deref().unwrap_or_default();
                (hash::hash_text(text), text.len() as i64)
            }
            ClipboardKind::Image => {
                let path = input.image_path.as_deref().ok_or_else(|| {
                    CoreError::InvalidPayload("image_path is required for image items".into())
                })?;
                hash::hash_file(Path::new(path))?
            }
            ClipboardKind::File => {
                file_paths.sort();
                file_paths.dedup();
                if file_paths.is_empty() {
                    return Err(CoreError::InvalidPayload(
                        "file_paths is required for file items".into(),
                    ));
                }
                (hash::hash_files(&file_paths)?, input.byte_size)
            }
        };

        if let Some(mut existing) = self.store.find_clipboard_by_hash(&hash)? {
            self.store.touch_clipboard(&existing.id, now)?;
            existing.created_at = now;
            self.prune_at(now)?;
            return Ok(existing);
        }

        let item = ClipboardItem {
            id: Uuid::new_v4().to_string(),
            kind: input.kind,
            text: input.text,
            file_paths,
            image_path: input.image_path,
            thumb_path: input.thumb_path,
            hash,
            source_bundle: input.source_bundle,
            source_name: input.source_name,
            byte_size,
            created_at: now,
            pinned: false,
        };
        self.store.insert_clipboard(&item)?;
        self.prune_at(now)?;
        Ok(item)
    }

    pub fn clipboard_list(&self, query: ClipboardQuery) -> Result<Vec<ClipboardItem>> {
        let query = query.normalized();
        let items = self
            .store
            .list_clipboard_candidates(query.board_id.as_deref(), query.kind)?;
        let ordered = if query.text.trim().is_empty() {
            let mut items = items;
            items.sort_by(|a, b| {
                b.pinned
                    .cmp(&a.pinned)
                    .then_with(|| b.created_at.cmp(&a.created_at))
            });
            items
        } else {
            search::rank(items, query.text.trim())
        };
        Ok(ordered
            .into_iter()
            .skip(query.offset as usize)
            .take(query.limit as usize)
            .collect())
    }

    pub fn clipboard_delete(&mut self, id: &str) -> Result<()> {
        let removed = self
            .store
            .delete_clipboard(id)?
            .ok_or_else(|| CoreError::NotFound(format!("clipboard item {id}")))?;
        self.remove_files_for(&removed);
        Ok(())
    }

    pub fn clipboard_pin(&mut self, id: &str, pinned: bool) -> Result<()> {
        self.store.set_pinned(id, pinned)
    }

    pub fn clipboard_clear(&mut self) -> Result<()> {
        let items = self.store.clear_clipboard()?;
        for item in &items {
            self.remove_files_for(item);
        }
        Ok(())
    }

    pub fn pinboard_create(&mut self, name: &str, color: &str) -> Result<Pinboard> {
        let name = name.trim();
        if name.is_empty() {
            return Err(CoreError::InvalidPayload(
                "pinboard name must not be empty".into(),
            ));
        }
        let color = match color.trim() {
            "" => "#0A84FF",
            color => color,
        };
        let id = Uuid::new_v4().to_string();
        self.store.create_pinboard(&id, name, color, Self::now_ms())
    }

    pub fn pinboard_rename(&mut self, id: &str, name: &str) -> Result<()> {
        let name = name.trim();
        if name.is_empty() {
            return Err(CoreError::InvalidPayload(
                "pinboard name must not be empty".into(),
            ));
        }
        self.store.rename_pinboard(id, name)
    }

    pub fn pinboard_delete(&mut self, id: &str) -> Result<()> {
        self.store.delete_pinboard(id)
    }

    pub fn pinboard_list(&self) -> Result<Vec<Pinboard>> {
        self.store.list_pinboards()
    }

    pub fn pinboard_add_item(&mut self, board_id: &str, item_id: &str) -> Result<()> {
        self.store
            .add_pinboard_item(board_id, item_id, Self::now_ms())
    }

    pub fn pinboard_remove_item(&mut self, board_id: &str, item_id: &str) -> Result<()> {
        self.store.remove_pinboard_item(board_id, item_id)
    }

    fn remove_files_for(&self, item: &ClipboardItem) {
        for path in [&item.image_path, &item.thumb_path].into_iter().flatten() {
            let path = PathBuf::from(path);
            if path.starts_with(&self.data_dir) {
                let _ = std::fs::remove_file(path);
            }
        }
    }

    fn remove_files(&self, files: &[ClipboardFiles]) {
        for file in files {
            for path in [&file.image_path, &file.thumb_path].into_iter().flatten() {
                let path = PathBuf::from(path);
                if path.starts_with(&self.data_dir) {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }

    pub fn prune(&mut self) -> Result<()> {
        self.prune_at(Self::now_ms())
    }

    fn prune_at(&mut self, now: i64) -> Result<()> {
        let files = self.store.prune(&self.config.clipboard, now)?;
        self.remove_files(&files);
        Ok(())
    }

    fn cleanup_orphans(&mut self) -> Result<()> {
        let referenced: std::collections::HashSet<PathBuf> = self
            .store
            .referenced_files()?
            .into_iter()
            .flat_map(|file| [file.image_path, file.thumb_path])
            .flatten()
            .map(PathBuf::from)
            .collect();
        for subdir in ["images", "thumbnails"] {
            let dir = self.data_dir.join(subdir);
            if !dir.exists() {
                continue;
            }
            for entry in std::fs::read_dir(&dir)? {
                let path = entry?.path();
                if path.is_file() && !referenced.contains(&path) {
                    let _ = std::fs::remove_file(&path);
                }
            }
        }
        Ok(())
    }

    pub fn config_mut_for_test(&mut self) -> &mut Config {
        &mut self.config
    }

    pub fn prune_at_for_test(&mut self, now: i64) -> Result<()> {
        self.prune_at(now)
    }
}
