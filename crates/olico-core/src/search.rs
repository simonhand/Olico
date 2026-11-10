use nucleo_matcher::{Config, Matcher, Utf32Str};

use crate::model::ClipboardItem;

pub fn rank(items: Vec<ClipboardItem>, query: &str) -> Vec<ClipboardItem> {
    let mut matcher = Matcher::new(Config::DEFAULT);
    let needle_lower = query.to_lowercase();
    let mut needle_buf = Vec::new();
    let needle = Utf32Str::new(&needle_lower, &mut needle_buf);

    let mut scored: Vec<(f64, i64, usize, ClipboardItem)> = Vec::new();
    for (index, item) in items.into_iter().enumerate() {
        let mut score = 0.0f64;
        if let Some(text) = &item.text {
            let text = text.to_lowercase();
            let mut buf = Vec::new();
            if !text.is_empty() {
                if let Some(found) = matcher.fuzzy_match(Utf32Str::new(&text, &mut buf), needle) {
                    score += found as f64;
                }
            }
        }
        let files = item.file_paths.join("\n").to_lowercase();
        if !files.is_empty() {
            let mut buf = Vec::new();
            if let Some(found) = matcher.fuzzy_match(Utf32Str::new(&files, &mut buf), needle) {
                score += found as f64 * 0.8;
            }
        }
        if let Some(source) = &item.source_name {
            let source = source.to_lowercase();
            let mut buf = Vec::new();
            if let Some(found) = matcher.fuzzy_match(Utf32Str::new(&source, &mut buf), needle) {
                score += found as f64 * 0.4;
            }
        }
        if score > 0.0 {
            scored.push((score, item.created_at, index, item));
        }
    }

    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.1.cmp(&a.1))
            .then_with(|| a.2.cmp(&b.2))
    });
    scored.into_iter().map(|(_, _, _, item)| item).collect()
}
