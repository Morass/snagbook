//! Sessions, items, notes and settings: everything Snagbook does that is not a window.
//!
//! A session is a plain folder that any program can read:
//!
//! ```text
//! a1b2c3d4_24-09-2026/
//!   README.md          header + every item's note, for whoever reads it next
//!   session.json       order, titles, ids
//!   01-main-menu/
//!     notes.md         the note, Markdown with a small front matter
//!     media/           shot-001.png, clip-001.mp4, …
//! ```

pub mod capture_math;
mod config;
mod error;
mod frontmatter;
mod header;
mod naming;
mod paths;
mod session;

pub use config::{CaptureSettings, Config, ConfigStore, HandoffStyle, Shortcuts, Template};
pub use error::SnagError;
pub use frontmatter::FrontMatter;
pub use header::render_header;
pub use naming::Naming;
pub use paths::Paths;
pub use session::{ItemRecord, Manifest, MediaCount, Session, Summary};

pub type Result<T> = std::result::Result<T, SnagError>;
