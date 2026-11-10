use olico_core::clipboard::Service;
use olico_core::dispatch::dispatch;
use serde_json::Value;
use tempfile::tempdir;

fn call(service: &mut Service, body: &str) -> Value {
    serde_json::from_str(&dispatch(service, body)).unwrap()
}

#[test]
fn config_get_returns_defaults() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, r#"{"v":1,"op":"config_get","payload":{}}"#);
    assert_eq!(res["ok"], true);
    assert_eq!(res["data"]["version"], 2);
    assert_eq!(res["data"]["hotkeys"]["clipboard"]["key_code"], 9);
}

#[test]
fn clipboard_add_then_list() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let add = call(
        &mut service,
        r#"{"v":1,"op":"clipboard_add","payload":{"kind":"text","text":"hello"}}"#,
    );
    assert_eq!(add["ok"], true);
    let list = call(
        &mut service,
        r#"{"v":1,"op":"clipboard_list","payload":{}}"#,
    );
    assert_eq!(list["data"][0]["text"], "hello");
}

#[test]
fn unknown_op_returns_error() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, r#"{"v":1,"op":"nope","payload":{}}"#);
    assert_eq!(res["ok"], false);
    assert_eq!(res["error"]["code"], "unknown_op");
}

#[test]
fn invalid_json_returns_error() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, "not json");
    assert_eq!(res["error"]["code"], "invalid_payload");
}

#[test]
fn unsupported_protocol_version_is_rejected() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, r#"{"v":2,"op":"config_get","payload":{}}"#);
    assert_eq!(res["error"]["code"], "invalid_payload");
}

#[test]
fn config_set_persists() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let mut config: Value =
        call(&mut service, r#"{"v":1,"op":"config_get","payload":{}}"#)["data"].clone();
    config["clipboard"]["max_items"] = 11.into();
    let body = serde_json::json!({"v":1,"op":"config_set","payload":{"config":config}}).to_string();
    let res = call(&mut service, &body);
    assert_eq!(res["ok"], true);
    let raw = std::fs::read_to_string(dir.path().join("config.json")).unwrap();
    assert!(raw.contains("\"max_items\": 11"));
}

#[test]
fn pinboard_ops_roundtrip() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let created = call(
        &mut service,
        r##"{"v":1,"op":"pinboard_create","payload":{"name":"Work","color":"#FF0000"}}"##,
    );
    let board_id = created["data"]["id"].as_str().unwrap().to_string();
    let list = call(&mut service, r#"{"v":1,"op":"pinboard_list","payload":{}}"#);
    assert_eq!(list["data"][0]["name"], "Work");
    let renamed = call(
        &mut service,
        &serde_json::json!({"v":1,"op":"pinboard_rename","payload":{"id":board_id,"name":"Job"}})
            .to_string(),
    );
    assert_eq!(renamed["ok"], true);
}
