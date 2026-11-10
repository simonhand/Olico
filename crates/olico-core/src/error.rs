#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("invalid payload: {0}")]
    InvalidPayload(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("config: {0}")]
    Config(String),
    #[error("unknown op: {0}")]
    UnknownOp(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("db: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, CoreError>;

impl CoreError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidPayload(_) => "invalid_payload",
            Self::NotFound(_) => "not_found",
            Self::Config(_) => "config_error",
            Self::UnknownOp(_) => "unknown_op",
            Self::Io(_) => "io_error",
            Self::Db(_) => "db_error",
            Self::Json(_) => "invalid_payload",
        }
    }
}
