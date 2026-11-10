use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardKind {
    Text,
    Image,
    File,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: String,
    pub kind: ClipboardKind,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub file_paths: Vec<String>,
    #[serde(default)]
    pub image_path: Option<String>,
    #[serde(default)]
    pub thumb_path: Option<String>,
    pub hash: String,
    #[serde(default)]
    pub source_bundle: Option<String>,
    #[serde(default)]
    pub source_name: Option<String>,
    #[serde(default)]
    pub byte_size: i64,
    pub created_at: i64,
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewClipboardItem {
    pub kind: ClipboardKind,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub file_paths: Vec<String>,
    #[serde(default)]
    pub image_path: Option<String>,
    #[serde(default)]
    pub thumb_path: Option<String>,
    #[serde(default)]
    pub source_bundle: Option<String>,
    #[serde(default)]
    pub source_name: Option<String>,
    #[serde(default)]
    pub byte_size: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ClipboardQuery {
    pub text: String,
    pub board_id: Option<String>,
    pub kind: Option<ClipboardKind>,
    pub limit: u32,
    pub offset: u32,
}

impl Default for ClipboardQuery {
    fn default() -> Self {
        Self {
            text: String::new(),
            board_id: None,
            kind: None,
            limit: 100,
            offset: 0,
        }
    }
}

impl ClipboardQuery {
    pub fn normalized(self) -> Self {
        Self {
            limit: self.limit.clamp(1, 500),
            ..self
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Pinboard {
    pub id: String,
    pub name: String,
    pub color: String,
    pub sort_order: i32,
    pub created_at: i64,
    pub item_count: u32,
}
