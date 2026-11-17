//! The Mac and iPhone apps are one product on one core: every command the desktop registers
//! (`src-tauri/src/lib.rs`, `generate_handler!`) must have an iOS bridge (`invoke.rs` and
//! `account.rs` arms, `video.rs` methods), and the other way round, unless
//! `crates/ffi/parity_allowlist.txt` says why not. A stale allowlist entry fails too.

use std::collections::{BTreeSet, HashMap};

const DESKTOP: &str = include_str!("../../../src-tauri/src/lib.rs");
const INVOKE: &str = include_str!("invoke.rs");
const ACCOUNT: &str = include_str!("account.rs");
const VIDEO: &str = include_str!("video.rs");
const ALLOW: &str = include_str!("../parity_allowlist.txt");

fn desktop() -> BTreeSet<String> {
    let start = DESKTOP.find("generate_handler![").expect("generate_handler! list");
    let list = &DESKTOP[start..start + DESKTOP[start..].find("]))").expect("end of the list")];
    list.lines()
        .skip(1)
        .map(|l| l.split("//").next().unwrap().trim().trim_end_matches(','))
        .filter(|l| !l.is_empty())
        .map(|l| l.rsplit("::").next().unwrap().to_owned())
        .collect()
}

fn ios() -> BTreeSet<String> {
    let arms = [INVOKE, ACCOUNT].into_iter().flat_map(str::lines).filter_map(|l| {
        let (name, rest) = l.trim().strip_prefix('"')?.split_once('"')?;
        rest.trim_start().starts_with("=>").then(|| name.to_owned())
    });
    let methods = VIDEO.lines().filter_map(|l| {
        let l = l.trim().strip_prefix("pub ")?;
        let l = l.strip_prefix("async ").unwrap_or(l).strip_prefix("fn ")?;
        Some(l[..l.find('(')?].to_owned())
    });
    arms.chain(methods).collect()
}

/// command → side (`desktop-only` / `ios-only`).
fn allowlist() -> HashMap<String, String> {
    let mut out = HashMap::new();
    for l in ALLOW.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let (side, rest) = l.split_once(':').expect("`<side>: <reason>: <commands>`");
        let cmds = rest.rsplit_once(':').expect("a reason before the commands").1;
        assert!(side == "desktop-only" || side == "ios-only", "unknown side `{side}`");
        for c in cmds.split_whitespace() {
            assert!(out.insert(c.to_owned(), side.to_owned()).is_none(), "`{c}` is listed twice");
        }
    }
    out
}

#[test]
fn both_bridges_register_the_same_commands() {
    let (d, i, allow) = (desktop(), ios(), allowlist());
    assert!(d.len() > 100 && i.len() > 100, "parsing broke: {} desktop, {} iOS", d.len(), i.len());
    let mut problems = Vec::new();
    for c in d.difference(&i) {
        if allow.get(c).map(String::as_str) != Some("desktop-only") {
            problems.push(format!("`{c}` is desktop-only: add it to crates/ffi/src/invoke.rs, or allowlist it with a reason"));
        }
    }
    for c in i.difference(&d) {
        if allow.get(c).map(String::as_str) != Some("ios-only") {
            problems.push(format!("`{c}` is iOS-only: register it in src-tauri/src/lib.rs, or allowlist it with a reason"));
        }
    }
    for (c, side) in &allow {
        let one_sided = if side == "desktop-only" { d.contains(c) && !i.contains(c) } else { i.contains(c) && !d.contains(c) };
        if !one_sided {
            problems.push(format!("`{c}` is allowlisted as {side} but isn't: drop it from parity_allowlist.txt"));
        }
    }
    assert!(problems.is_empty(), "Mac and iPhone bridges drifted (docs/ADDING-FEATURES.md):\n{}", problems.join("\n"));
}
