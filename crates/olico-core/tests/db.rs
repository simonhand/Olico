use olico_core::db::Store;
use tempfile::tempdir;

#[test]
fn open_creates_database_and_migrates() {
    let dir = tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(store.schema_version().unwrap(), 1);
    assert!(dir.path().join("olico.db").exists());
}

#[test]
fn open_is_idempotent() {
    let dir = tempdir().unwrap();
    {
        let store = Store::open(dir.path()).unwrap();
        assert_eq!(store.schema_version().unwrap(), 1);
    }
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(store.schema_version().unwrap(), 1);
}

#[test]
fn journal_mode_is_wal() {
    let dir = tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(store.journal_mode().unwrap().to_lowercase(), "wal");
}

#[test]
fn foreign_keys_are_enabled() {
    let dir = tempdir().unwrap();
    let mut store = Store::open(dir.path()).unwrap();
    let err = store
        .execute_for_test(
            "INSERT INTO pinboard_items (board_id, item_id, added_at) VALUES ('missing', 'missing', 1)",
        )
        .unwrap_err();
    assert_eq!(err.code(), "db_error");
}
