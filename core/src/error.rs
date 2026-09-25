use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnagError {
    ConfigUnreadable(String),
    NotASession(String),
    NoSuchItem(i64),
    BadName(String),
    /// The person said no (for example to deleting something for good).
    Cancelled,
    /// The folder's drive has no Trash (a network share, some removable drives).
    NoTrash,
    Io(String),
}

impl fmt::Display for SnagError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SnagError::ConfigUnreadable(s) => write!(f, "The settings file could not be read, so it was not overwritten: {s}"),
            SnagError::NotASession(s) => write!(f, "{s} is not a Snagbook session (no session.json)."),
            SnagError::NoSuchItem(id) => write!(f, "Item {id} does not exist."),
            SnagError::BadName(s) => write!(f, "“{s}” cannot be used as a name."),
            SnagError::Cancelled => write!(f, "Cancelled."),
            SnagError::NoTrash => write!(f, "This drive has no Trash."),
            SnagError::Io(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for SnagError {}

impl From<std::io::Error> for SnagError {
    fn from(e: std::io::Error) -> Self {
        SnagError::Io(e.to_string())
    }
}

impl From<serde_json::Error> for SnagError {
    fn from(e: serde_json::Error) -> Self {
        SnagError::Io(e.to_string())
    }
}
