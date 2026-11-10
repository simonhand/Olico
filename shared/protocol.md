# Olico Core Protocol v1

Platform shells call the Rust core through four C functions. Every request and
response is a UTF-8 JSON string.

## C ABI

```c
typedef struct OlicoHandle OlicoHandle;

OlicoHandle *olico_core_new(const char *data_dir);
void olico_core_free(OlicoHandle *handle);
char *olico_dispatch(OlicoHandle *handle, const char *request_json);
void olico_string_free(char *ptr);
```

- `olico_core_new` returns `NULL` when `data_dir` is invalid or the store cannot
  be opened. `data_dir` is the application data directory
  (`~/Library/Application Support/Olico/` on macOS).
- `olico_dispatch` returns a heap string owned by the caller. Release it with
  `olico_string_free`; never free it with `free()`.
- All entry points catch panics and return error JSON instead of unwinding
  across the boundary.
- Calls may come from any thread; the handle serializes access internally.

## Envelope

Request:

```json
{"v": 1, "op": "clipboard_list", "payload": {"text": "api", "limit": 50}}
```

Success:

```json
{"v": 1, "ok": true, "data": []}
```

Failure:

```json
{"v": 1, "ok": false, "error": {"code": "invalid_payload", "message": "..."}}
```

Error codes: `invalid_payload`, `invalid_handle`, `not_found`, `config_error`,
`io_error`, `db_error`, `unknown_op`, `internal_error`.

## Operations

| op | payload | data |
|---|---|---|
| `clipboard_add` | `kind`, `text?`, `file_paths?`, `image_path?`, `thumb_path?`, `source_bundle?`, `source_name?`, `byte_size?` | final item |
| `clipboard_list` | `text?`, `board_id?`, `kind?`, `limit?`, `offset?` | item array |
| `clipboard_delete` | `id` | `{}` |
| `clipboard_pin` | `id`, `pinned` | `{}` |
| `clipboard_clear` | `{}` | `{}` |
| `maintenance_prune` | `{}` | `{}` |
| `pinboard_create` | `name`, `color?` | pinboard |
| `pinboard_rename` | `id`, `name` | `{}` |
| `pinboard_delete` | `id` | `{}` |
| `pinboard_list` | `{}` | pinboard array |
| `pinboard_add_item` | `board_id`, `item_id` | `{}` |
| `pinboard_remove_item` | `board_id`, `item_id` | `{}` |
| `config_get` | `{}` | full config |
| `config_set` | `config` | `{}` |

`clipboard_clear` removes every record, including pinned ones. Board deletion
keeps the clipboard items themselves.

## Types

`kind` is one of `text`, `image`, `file`.

Clipboard item:

```json
{
  "id": "uuid",
  "kind": "text",
  "text": "hello",
  "file_paths": [],
  "image_path": null,
  "thumb_path": null,
  "hash": "sha256-hex",
  "source_bundle": "com.apple.Safari",
  "source_name": "Safari",
  "byte_size": 5,
  "created_at": 1762732800000,
  "pinned": false
}
```

Pinboard:

```json
{"id": "uuid", "name": "Work", "color": "#0A84FF", "sort_order": 1, "created_at": 1762732800000, "item_count": 3}
```

`__pinned` is a reserved virtual board ID: `clipboard_list` with
`board_id: "__pinned"` returns pinned items only. It is not stored as a real
pinboard.

## Config v2

```json
{
  "version": 2,
  "hotkeys": {
    "screenshot": {"key_code": 1, "modifiers": ["opt", "shift"]},
    "clipboard": {"key_code": 9, "modifiers": ["cmd", "shift"]},
    "color_picker": {"key_code": 8, "modifiers": ["opt", "shift"]},
    "toggle_pins": {"key_code": 4, "modifiers": ["opt", "shift"]}
  },
  "shortcuts": [
    {"target": "com.google.Chrome", "path": "/Applications/Google Chrome.app",
     "key_code": 1, "modifiers": ["opt", "shift"], "enabled": true}
  ],
  "clipboard": {
    "enabled": true,
    "max_items": 500,
    "retention_days": 30,
    "max_image_mb": 50,
    "max_text_kb": 512,
    "excluded_apps": ["com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess"]
  },
  "screenshot": {"save_dir": "~/Pictures/Olico", "color_format": "hex", "restore_pins": true},
  "residency": {"launch_at_login": true}
}
```

`modifiers` order does not matter; duplicate hotkeys are rejected after
canonicalization. A config newer than version 2 is rejected and never
overwritten. Version 1 configs are migrated in place.
