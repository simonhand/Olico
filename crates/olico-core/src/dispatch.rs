use serde::Deserialize;
use serde_json::{json, Value};

use crate::clipboard::Service;
use crate::config::Config;
use crate::error::{CoreError, Result};
use crate::model::{ClipboardQuery, NewClipboardItem};

#[derive(Deserialize)]
struct Request {
    #[serde(default = "protocol_version")]
    v: u32,
    op: String,
    #[serde(default)]
    payload: Value,
}

fn protocol_version() -> u32 {
    1
}

#[derive(Deserialize)]
struct IdPayload {
    id: String,
}

#[derive(Deserialize)]
struct PinPayload {
    id: String,
    pinned: bool,
}

#[derive(Deserialize)]
struct BoardItemPayload {
    board_id: String,
    item_id: String,
}

#[derive(Deserialize)]
struct RenamePayload {
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct CreatePayload {
    name: String,
    #[serde(default)]
    color: String,
}

#[derive(Deserialize)]
struct ConfigPayload {
    config: Config,
}

fn object_or_empty(payload: Value) -> Value {
    if payload.is_null() {
        Value::Object(Default::default())
    } else {
        payload
    }
}

pub fn dispatch(service: &mut Service, raw: &str) -> String {
    match handle(service, raw) {
        Ok(data) => json!({"v": 1, "ok": true, "data": data}).to_string(),
        Err(err) => json!({
            "v": 1,
            "ok": false,
            "error": {"code": err.code(), "message": err.to_string()}
        })
        .to_string(),
    }
}

fn handle(service: &mut Service, raw: &str) -> Result<Value> {
    let request: Request = serde_json::from_str(raw)?;
    if request.v != 1 {
        return Err(CoreError::InvalidPayload(format!(
            "unsupported protocol version {}",
            request.v
        )));
    }
    let payload = object_or_empty(request.payload);
    match request.op.as_str() {
        "clipboard_add" => {
            let input: NewClipboardItem = serde_json::from_value(payload)?;
            Ok(serde_json::to_value(
                service.clipboard_add(input, Service::now_ms())?,
            )?)
        }
        "clipboard_list" => {
            let query: ClipboardQuery = serde_json::from_value(payload)?;
            Ok(serde_json::to_value(service.clipboard_list(query)?)?)
        }
        "clipboard_delete" => {
            let payload: IdPayload = serde_json::from_value(payload)?;
            service.clipboard_delete(&payload.id)?;
            Ok(json!({}))
        }
        "clipboard_pin" => {
            let payload: PinPayload = serde_json::from_value(payload)?;
            service.clipboard_pin(&payload.id, payload.pinned)?;
            Ok(json!({}))
        }
        "clipboard_clear" => {
            service.clipboard_clear()?;
            Ok(json!({}))
        }
        "maintenance_prune" => {
            service.prune()?;
            Ok(json!({}))
        }
        "pinboard_create" => {
            let payload: CreatePayload = serde_json::from_value(payload)?;
            Ok(serde_json::to_value(
                service.pinboard_create(&payload.name, &payload.color)?,
            )?)
        }
        "pinboard_rename" => {
            let payload: RenamePayload = serde_json::from_value(payload)?;
            service.pinboard_rename(&payload.id, &payload.name)?;
            Ok(json!({}))
        }
        "pinboard_delete" => {
            let payload: IdPayload = serde_json::from_value(payload)?;
            service.pinboard_delete(&payload.id)?;
            Ok(json!({}))
        }
        "pinboard_list" => Ok(serde_json::to_value(service.pinboard_list()?)?),
        "pinboard_add_item" => {
            let payload: BoardItemPayload = serde_json::from_value(payload)?;
            service.pinboard_add_item(&payload.board_id, &payload.item_id)?;
            Ok(json!({}))
        }
        "pinboard_remove_item" => {
            let payload: BoardItemPayload = serde_json::from_value(payload)?;
            service.pinboard_remove_item(&payload.board_id, &payload.item_id)?;
            Ok(json!({}))
        }
        "config_get" => Ok(serde_json::to_value(service.config())?),
        "config_set" => {
            let payload: ConfigPayload = serde_json::from_value(payload)?;
            service.set_config(payload.config)?;
            Ok(json!({}))
        }
        other => Err(CoreError::UnknownOp(other.to_string())),
    }
}
