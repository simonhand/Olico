use std::path::Path;

use crate::error::Result;

pub fn hash_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

pub fn normalize_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn hash_text(text: &str) -> String {
    hash_bytes(normalize_text(text).as_bytes())
}

pub fn hash_file(path: &Path) -> Result<(String, i64)> {
    let bytes = std::fs::read(path)?;
    Ok((hash_bytes(&bytes), bytes.len() as i64))
}

pub fn hash_files(paths: &[String]) -> Result<String> {
    let mut sorted = paths.to_vec();
    sorted.sort();
    sorted.dedup();
    Ok(hash_bytes(&serde_json::to_vec(&sorted)?))
}
