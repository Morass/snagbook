/// Flat YAML front matter: `key: "value"` lines between two `---` lines. Only what the app
/// writes is understood; anything else in the block is carried along untouched.
pub struct FrontMatter;

pub struct Split {
    pub fields: Vec<(String, String)>,
    pub raw: String,
    pub body: String,
}

fn trim_blank(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
}

impl FrontMatter {
    pub fn split(text: &str) -> Split {
        let t = text.replace("\r\n", "\n");
        let none = |t: String| Split { fields: vec![], raw: String::new(), body: t };
        let Some(rest) = t.strip_prefix("---\n") else { return none(t) };
        let (block, after) = if let Some(i) = rest.find("\n---\n") {
            (&rest[..i], &rest[i + 5..])
        } else if rest.ends_with("\n---") {
            let i = rest.len() - 4;
            (&rest[..i], "")
        } else {
            return none(t.clone());
        };
        let body = after.strip_prefix('\n').unwrap_or(after).to_string();
        let mut fields = vec![];
        for line in block.split('\n') {
            if line.starts_with(' ') || line.starts_with('#') {
                continue;
            }
            let Some(colon) = line.find(':') else { continue };
            let key = trim_blank(&line[..colon]).to_string();
            let value = trim_blank(&line[colon + 1..]);
            fields.push((key, Self::unquote(value)));
        }
        Split { fields, raw: block.to_string(), body }
    }

    /// Replace (or add) `updates` in the front matter block, keeping every other line.
    pub fn join(raw: &str, updates: &[(&str, &str)], body: &str) -> String {
        let mut lines: Vec<String> = if raw.is_empty() { vec![] } else { raw.split('\n').map(String::from).collect() };
        for (key, value) in updates {
            let line = format!("{key}: {}", Self::quote(value));
            let prefix = format!("{key}:");
            match lines.iter().position(|l| l.starts_with(&prefix)) {
                Some(i) => lines[i] = line,
                None => lines.push(line),
            }
        }
        format!("---\n{}\n---\n\n{}", lines.join("\n"), body)
    }

    pub fn quote(s: &str) -> String {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', " "))
    }

    pub fn unquote(s: &str) -> String {
        let n = s.chars().count();
        if n >= 2 && s.starts_with('"') && s.ends_with('"') {
            let inner = &s[1..s.len() - 1];
            let mut out = String::new();
            let mut esc = false;
            for c in inner.chars() {
                if esc {
                    out.push(if c == 'n' { '\n' } else { c });
                    esc = false;
                } else if c == '\\' {
                    esc = true;
                } else {
                    out.push(c);
                }
            }
            return out;
        }
        if n >= 2 && s.starts_with('\'') && s.ends_with('\'') {
            return s[1..s.len() - 1].replace("''", "'");
        }
        s.to_string()
    }
}
