use olico_core::clipboard::Service;
use olico_core::model::{ClipboardItem, ClipboardKind, ClipboardQuery, NewClipboardItem};
use tempfile::tempdir;

fn text_item(text: &str) -> NewClipboardItem {
    NewClipboardItem {
        kind: ClipboardKind::Text,
        text: Some(text.into()),
        file_paths: vec![],
        image_path: None,
        thumb_path: None,
        source_bundle: Some("com.example.editor".into()),
        source_name: Some("Editor".into()),
        byte_size: 0,
    }
}

fn add_text(service: &mut Service, text: &str, now: i64) -> ClipboardItem {
    service.clipboard_add(text_item(text), now).unwrap()
}

#[test]
fn text_is_stored_with_computed_hash_and_size() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let item = add_text(&mut service, "hello", 1_000);
    assert_eq!(item.kind, ClipboardKind::Text);
    assert_eq!(item.hash.len(), 64);
    assert_eq!(item.byte_size, 5);
    assert_eq!(item.created_at, 1_000);
    assert!(!item.pinned);
}

#[test]
fn identical_text_is_deduped_and_moves_to_top() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let first = add_text(&mut service, "same", 1_000);
    let second = add_text(&mut service, "same", 2_000);
    assert_eq!(first.id, second.id);
    assert_eq!(second.created_at, 2_000);
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].created_at, 2_000);
}

#[test]
fn dedupe_preserves_pin() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let item = add_text(&mut service, "pinned", 1_000);
    service.clipboard_pin(&item.id, true).unwrap();
    let again = add_text(&mut service, "pinned", 2_000);
    assert!(again.pinned);
}

#[test]
fn list_orders_pinned_first_then_newest() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let a = add_text(&mut service, "a", 1_000);
    add_text(&mut service, "b", 2_000);
    add_text(&mut service, "c", 3_000);
    service.clipboard_pin(&a.id, true).unwrap();
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    let texts: Vec<_> = items.iter().map(|i| i.text.clone().unwrap()).collect();
    assert_eq!(texts, vec!["a", "c", "b"]);
}

#[test]
fn file_kind_hashes_sorted_paths() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let mut input = text_item("");
    input.kind = ClipboardKind::File;
    input.text = None;
    input.file_paths = vec!["/tmp/b".into(), "/tmp/a".into()];
    let first = service.clipboard_add(input.clone(), 1_000).unwrap();
    input.file_paths = vec!["/tmp/a".into(), "/tmp/b".into()];
    let second = service.clipboard_add(input, 2_000).unwrap();
    assert_eq!(first.hash, second.hash);
    assert_eq!(first.id, second.id);
}

#[test]
fn image_hash_uses_file_bytes() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("images")).unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let image = dir.path().join("images/pic.png");
    std::fs::write(&image, b"PNGDATA").unwrap();
    let input = NewClipboardItem {
        kind: ClipboardKind::Image,
        text: None,
        file_paths: vec![],
        image_path: Some(image.to_string_lossy().to_string()),
        thumb_path: None,
        source_bundle: None,
        source_name: None,
        byte_size: 0,
    };
    let item = service.clipboard_add(input, 1_000).unwrap();
    assert_eq!(item.byte_size, 7);
    assert_eq!(item.hash.len(), 64);
}

#[test]
fn delete_removes_item_and_files() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("images")).unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let image = dir.path().join("images/pic.png");
    std::fs::write(&image, b"PNGDATA").unwrap();
    let input = NewClipboardItem {
        kind: ClipboardKind::Image,
        text: None,
        file_paths: vec![],
        image_path: Some(image.to_string_lossy().to_string()),
        thumb_path: None,
        source_bundle: None,
        source_name: None,
        byte_size: 0,
    };
    let item = service.clipboard_add(input, 1_000).unwrap();
    service.clipboard_delete(&item.id).unwrap();
    assert!(!image.exists());
    assert!(service
        .clipboard_list(ClipboardQuery::default())
        .unwrap()
        .is_empty());
}

#[test]
fn list_filters_by_kind_and_offset() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    add_text(&mut service, "a", 1_000);
    add_text(&mut service, "b", 2_000);
    let mut file_input = text_item("");
    file_input.kind = ClipboardKind::File;
    file_input.text = None;
    file_input.file_paths = vec!["/tmp/x".into()];
    service.clipboard_add(file_input, 3_000).unwrap();

    let files = service
        .clipboard_list(ClipboardQuery {
            kind: Some(ClipboardKind::File),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(files.len(), 1);

    let paged = service
        .clipboard_list(ClipboardQuery {
            offset: 1,
            limit: 1,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(paged.len(), 1);
    assert_eq!(paged[0].text.as_deref(), Some("b"));
}

#[test]
fn max_items_keeps_newest_and_removes_files() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("images")).unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    service.config_mut_for_test().clipboard.max_items = 3;
    let mut paths = Vec::new();
    for (i, text) in ["a", "b", "c", "d", "e"].iter().enumerate() {
        let image = dir.path().join(format!("images/{i}.png"));
        std::fs::write(&image, format!("img{i}")).unwrap();
        paths.push(image);
        let input = NewClipboardItem {
            kind: ClipboardKind::Image,
            text: Some(text.to_string()),
            file_paths: vec![],
            image_path: Some(paths[i].to_string_lossy().to_string()),
            thumb_path: None,
            source_bundle: None,
            source_name: None,
            byte_size: 0,
        };
        service.clipboard_add(input, 1_000 + i as i64).unwrap();
    }
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0].text.as_deref(), Some("e"));
    assert!(!paths[0].exists());
    assert!(!paths[1].exists());
    assert!(paths[4].exists());
}

#[test]
fn retention_days_removes_old_items() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    add_text(&mut service, "old", 1_000);
    add_text(&mut service, "new", 1_000 + 31 * 86_400_000);
    service.prune_at_for_test(1_000 + 31 * 86_400_000).unwrap();
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].text.as_deref(), Some("new"));
}

#[test]
fn pinned_and_boarded_items_survive_max_items() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    service.config_mut_for_test().clipboard.max_items = 1;
    let pinned = add_text(&mut service, "pinned", 1_000);
    service.clipboard_pin(&pinned.id, true).unwrap();
    let boarded = add_text(&mut service, "boarded", 2_000);
    let board = service.pinboard_create("Keep", "#0A84FF").unwrap();
    service.pinboard_add_item(&board.id, &boarded.id).unwrap();
    add_text(&mut service, "newest", 3_000);
    add_text(&mut service, "newer", 4_000);
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    let texts: Vec<_> = items.iter().map(|i| i.text.clone().unwrap()).collect();
    assert!(texts.contains(&"pinned".to_string()));
    assert!(texts.contains(&"boarded".to_string()));
    assert!(texts.contains(&"newer".to_string()));
    assert!(!texts.contains(&"newest".to_string()));
}

#[test]
fn orphan_files_are_cleaned_on_open() {
    let dir = tempdir().unwrap();
    {
        let mut service = Service::open(dir.path()).unwrap();
        std::fs::create_dir_all(dir.path().join("images")).unwrap();
        std::fs::create_dir_all(dir.path().join("thumbnails")).unwrap();
        let image = dir.path().join("images/keep.png");
        std::fs::write(&image, b"keep").unwrap();
        let input = NewClipboardItem {
            kind: ClipboardKind::Image,
            text: None,
            file_paths: vec![],
            image_path: Some(image.to_string_lossy().to_string()),
            thumb_path: None,
            source_bundle: None,
            source_name: None,
            byte_size: 0,
        };
        service.clipboard_add(input, Service::now_ms()).unwrap();
        std::fs::write(dir.path().join("images/orphan.png"), b"orphan").unwrap();
        std::fs::write(dir.path().join("thumbnails/orphan.png"), b"orphan").unwrap();
    }
    let _service = Service::open(dir.path()).unwrap();
    assert!(dir.path().join("images/keep.png").exists());
    assert!(!dir.path().join("images/orphan.png").exists());
    assert!(!dir.path().join("thumbnails/orphan.png").exists());
}
