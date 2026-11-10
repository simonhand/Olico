use olico_core::model::{ClipboardItem, ClipboardKind};
use olico_core::search::rank;

fn item(id: &str, text: &str, files: &[&str], source: &str, created_at: i64) -> ClipboardItem {
    ClipboardItem {
        id: id.into(),
        kind: ClipboardKind::Text,
        text: Some(text.into()),
        file_paths: files.iter().map(|s| s.to_string()).collect(),
        image_path: None,
        thumb_path: None,
        hash: id.into(),
        source_bundle: None,
        source_name: Some(source.into()),
        byte_size: 0,
        created_at,
        pinned: false,
    }
}

#[test]
fn text_match_outranks_source_match() {
    let items = vec![
        item("text", "quarterly report", &[], "Safari", 1),
        item("source", "hello", &[], "Reportly", 2),
    ];
    let ranked = rank(items, "report");
    assert_eq!(ranked[0].id, "text");
    assert_eq!(ranked.len(), 2);
}

#[test]
fn file_path_is_searchable() {
    let items = vec![
        item("file", "", &["/Users/me/Documents/report.pdf"], "Finder", 1),
        item("other", "notes", &[], "Editor", 2),
    ];
    let ranked = rank(items, "report");
    assert_eq!(ranked.len(), 1);
    assert_eq!(ranked[0].id, "file");
}

#[test]
fn chinese_query_matches() {
    let items = vec![
        item("cn", "季度报告 2026", &[], "Pages", 1),
        item("en", "quarterly report", &[], "Pages", 2),
    ];
    let ranked = rank(items, "报告");
    assert_eq!(ranked.len(), 1);
    assert_eq!(ranked[0].id, "cn");
}

#[test]
fn no_match_returns_empty() {
    let items = vec![item("a", "hello", &[], "Safari", 1)];
    assert!(rank(items, "zzzzz").is_empty());
}

#[test]
fn ties_follow_created_at_desc() {
    let items = vec![
        item("old", "needle", &[], "Safari", 1),
        item("new", "needle", &[], "Safari", 2),
    ];
    let ranked = rank(items, "needle");
    assert_eq!(ranked[0].id, "new");
}

#[test]
fn case_insensitive_match() {
    let items = vec![item("a", "Hello World", &[], "Safari", 1)];
    assert_eq!(rank(items, "hello").len(), 1);
}
