use olico_core::clipboard::Service;
use olico_core::model::{ClipboardKind, ClipboardQuery, NewClipboardItem};
use tempfile::tempdir;

fn add(service: &mut Service, text: &str, now: i64) -> String {
    service
        .clipboard_add(
            NewClipboardItem {
                kind: ClipboardKind::Text,
                text: Some(text.into()),
                file_paths: vec![],
                image_path: None,
                thumb_path: None,
                source_bundle: None,
                source_name: None,
                byte_size: 0,
            },
            now,
        )
        .unwrap()
        .id
}

#[test]
fn create_list_and_count() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create(" 工作 ", "").unwrap();
    assert_eq!(board.name, "工作");
    assert_eq!(board.color, "#0A84FF");
    let item = add(&mut service, "x", 1);
    service.pinboard_add_item(&board.id, &item).unwrap();
    let boards = service.pinboard_list().unwrap();
    assert_eq!(boards.len(), 1);
    assert_eq!(boards[0].item_count, 1);
}

#[test]
fn add_and_remove_item() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    let item = add(&mut service, "x", 1);
    service.pinboard_add_item(&board.id, &item).unwrap();
    let filtered = service
        .clipboard_list(ClipboardQuery {
            board_id: Some(board.id.clone()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(filtered.len(), 1);
    service.pinboard_remove_item(&board.id, &item).unwrap();
    let filtered = service
        .clipboard_list(ClipboardQuery {
            board_id: Some(board.id.clone()),
            ..Default::default()
        })
        .unwrap();
    assert!(filtered.is_empty());
}

#[test]
fn deleting_board_keeps_items() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    let item = add(&mut service, "x", 1);
    service.pinboard_add_item(&board.id, &item).unwrap();
    service.pinboard_delete(&board.id).unwrap();
    assert!(service.pinboard_list().unwrap().is_empty());
    assert_eq!(
        service
            .clipboard_list(ClipboardQuery::default())
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn rename_rejects_empty() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    assert_eq!(
        service
            .pinboard_rename(&board.id, "   ")
            .unwrap_err()
            .code(),
        "invalid_payload"
    );
}

#[test]
fn missing_item_or_board_is_not_found() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    assert_eq!(
        service
            .pinboard_add_item(&board.id, "missing")
            .unwrap_err()
            .code(),
        "not_found"
    );
    assert_eq!(
        service
            .pinboard_add_item("missing", "missing")
            .unwrap_err()
            .code(),
        "not_found"
    );
}

#[test]
fn pinned_virtual_board_returns_only_pinned() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let a = add(&mut service, "a", 1);
    add(&mut service, "b", 2);
    service.clipboard_pin(&a, true).unwrap();
    let items = service
        .clipboard_list(ClipboardQuery {
            board_id: Some("__pinned".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].text.as_deref(), Some("a"));
}
