//! Config loader with nested comments and raw strings.

/* Outer block comment
   /* nested block comment: Rust allows nesting */
   still inside the outer comment: fn fake() -> i32 { 42 }
*/

use std::collections::HashMap;
use std::fmt;

/// A documented constant. `code` in docs is still a comment.
pub const DEFAULT_CONFIG: &str = r#"
[server]
name = "primary"   # TOML comment inside a Rust raw string
path = "C:\temp\no\escapes"
"#;

pub const HASHES: &str = r##"a raw string containing "# that does not end it"##;
pub const MULTILINE: &str = "first line
second line with \"escaped quotes\" and // no comment
third line";
pub const BYTES: &[u8] = b"bytes \x7f /* not a comment */";
pub const RAW_BYTES: &[u8] = br"raw\bytes";
pub const QUOTE: char = '"';
pub const APOSTROPHE: char = '\'';

#[derive(Debug, Clone, PartialEq)]
pub struct Config<'a> {
    pub name: &'a str,
    pub retries: u32,
    pub labels: HashMap<String, String>,
}

impl<'a> Config<'a> {
    pub fn new(name: &'a str) -> Self {
        Self { name, retries: 3, labels: HashMap::new() }
    }

    /* A block comment /* with a nested one */ between methods. */
    pub fn ratio(&self, total: f64) -> f64 {
        total / self.retries as f64 / 2.0
    }

    pub fn label<'b>(&'b self, key: &str) -> Option<&'b String> {
        self.labels.get(key)
    }
}

impl fmt::Display for Config<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Config({}, retries={}, \"{}\")", self.name, self.retries, self.labels.len())
    }
}

fn parse(input: &str) -> Result<Config<'_>, String> {
    let name = input
        .lines()
        .find(|l| l.starts_with("name"))
        .and_then(|l| l.split('"').nth(1))
        .ok_or_else(|| format!("missing name in {:?}", input))?;
    Ok(Config::new(name))
}

fn main() {
    let cfg = parse(DEFAULT_CONFIG).expect("valid config");
    let lifetime_vs_char = ('a', 'b');
    println!("{cfg} {} {:?} {}", cfg.ratio(12.0), lifetime_vs_char, HASHES);
    println!("{}{}{:?}{:?}{}", MULTILINE, QUOTE, BYTES, RAW_BYTES, APOSTROPHE);
}
