use olico_core::model::{ClipboardItem, ClipboardKind, ClipboardQuery};

#[test]
fn kind_serializes_snake_case() {
    assert_eq!(
        serde_json::to_string(&ClipboardKind::Text).unwrap(),
        "\"text\""
    );
    assert_eq!(
        serde_json::to_string(&ClipboardKind::Image).unwrap(),
        "\"image\""
    );
    assert_eq!(
        serde_json::to_string(&ClipboardKind::File).unwrap(),
        "\"file\""
    );
}

#[test]
fn query_defaults_to_100_and_zero_offset() {
    let q: ClipboardQuery = serde_json::from_str("{}").unwrap();
    assert_eq!(q.limit, 100);
    assert_eq!(q.offset, 0);
    assert!(q.text.is_empty());
}

#[test]
fn query_limit_is_clamped() {
    let high = ClipboardQuery {
        limit: 9999,
        ..Default::default()
    }
    .normalized();
    let zero = ClipboardQuery {
        limit: 0,
        ..Default::default()
    }
    .normalized();
    assert_eq!(high.limit, 500);
    assert_eq!(zero.limit, 1);
}

#[test]
fn item_roundtrips_with_optional_fields_absent() {
    let json = r#"{
        "id":"a","kind":"text","hash":"h","created_at":1
    }"#;
    let item: ClipboardItem = serde_json::from_str(json).unwrap();
    assert!(item.file_paths.is_empty());
    assert!(item.text.is_none());
    assert!(!item.pinned);
}
