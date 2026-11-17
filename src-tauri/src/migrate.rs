//! The rename from the working name Encore to Spotless changed the bundle id from
//! `app.encore.desktop` to `app.spotless.desktop`, and every per-app folder macOS and Tauri hand
//! out is named after the bundle id. So at launch, before anything opens a file in them, each
//! folder that exists under the old id and not yet under the new one is moved over:
//!
//! - `~/Library/Application Support/<id>`: the SQLite library, downloads, covers, logs, caches;
//! - `~/Library/Caches/<id>` and `~/Library/Logs/<id>`;
//! - `~/Library/WebKit/<id>` and `~/Library/HTTPStorages/<id>`: the page's localStorage
//!   (preferences, layout, recent searches) and the web caches.
//!
//! A move is a rename on the same volume: nothing is copied and nothing is deleted. A folder that
//! already exists under the new id is never touched, and neither is its old counterpart, so the
//! move happens at most once and a failed one leaves the old data where it was.
//!
//! The database keeps a few absolute paths into the data folder (Made for you cover files), so
//! after the data folder moves, those strings are pointed at the new folder too.

use std::path::{Path, PathBuf};

pub const OLD_ID: &str = "app.encore.desktop";

/// One folder moved from the old id to the new one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Moved {
    pub from: PathBuf,
    pub to: PathBuf,
}

/// What [`migrate`] did, logged once logging is up (it runs before the log file exists).
#[derive(Debug, Default)]
pub struct Report {
    pub moved: Vec<Moved>,
    pub failed: Vec<(PathBuf, String)>,
}

/// The old-id twin of `dir` when `dir` is named after the bundle id `new_id`.
fn old_twin(dir: &Path, new_id: &str, old_id: &str) -> Option<PathBuf> {
    (dir.file_name()? == new_id).then(|| dir.with_file_name(old_id))
}

/// Move each `dirs` entry's old-id twin into place when only the old one exists.
pub fn migrate(dirs: &[PathBuf], new_id: &str, old_id: &str) -> Report {
    let mut report = Report::default();
    let mut seen = Vec::new();
    for to in dirs {
        if seen.contains(to) {
            continue;
        }
        seen.push(to.clone());
        let Some(from) = old_twin(to, new_id, old_id) else { continue };
        // `symlink_metadata`: a dangling link at the new path still counts as "there".
        if to.symlink_metadata().is_ok() || !from.is_dir() {
            continue;
        }
        if let Some(parent) = to.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::rename(&from, to) {
            Ok(()) => report.moved.push(Moved { from, to: to.clone() }),
            Err(e) => report.failed.push((from, e.to_string())),
        }
    }
    report
}

/// Whether any of `dirs` still has to move (its old twin exists, it doesn't).
pub fn pending(dirs: &[PathBuf], new_id: &str, old_id: &str) -> bool {
    dirs.iter().any(|to| {
        to.symlink_metadata().is_err()
            && old_twin(to, new_id, old_id).is_some_and(|from| from.is_dir())
    })
}

/// Whether the app is still running under its old name (`Encore.app`). Moving its folders from
/// under it would split the library between two places, so the move waits until it has quit.
/// `ENCORE_MIGRATE_ANYWAY=1` skips the check (tests that move a copy under another `HOME`).
pub fn old_app_running() -> bool {
    if !cfg!(target_os = "macos") || std::env::var_os("ENCORE_MIGRATE_ANYWAY").is_some() {
        return false;
    }
    std::process::Command::new("/bin/ps")
        .args(["-axo", "comm="])
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .any(|l| l.contains("/Encore.app/Contents/MacOS/"))
        })
        .unwrap_or(false)
}

/// The folders to migrate on this machine, given Tauri's resolved ones (all named after the new
/// bundle id). On macOS WebKit keeps the page's storage in two more, under `~/Library`.
pub fn app_dirs(resolved: &[Option<PathBuf>], home: Option<&Path>, new_id: &str) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = resolved.iter().flatten().cloned().collect();
    if cfg!(target_os = "macos") {
        if let Some(home) = home {
            for sub in ["WebKit", "HTTPStorages"] {
                dirs.push(home.join("Library").join(sub).join(new_id));
            }
        }
    }
    dirs
}

/// Point absolute paths stored in the database at the moved data folder: every TEXT value that
/// contains `old_dir/` gets it replaced by `new_dir/`. Returns how many values changed.
pub fn rewrite_paths(db: &encore_core::db::Db, old_dir: &Path, new_dir: &Path) -> usize {
    let (Some(old), Some(new)) = (old_dir.to_str(), new_dir.to_str()) else { return 0 };
    let old = format!("{}/", old.trim_end_matches('/'));
    let new = format!("{}/", new.trim_end_matches('/'));
    db.with_conn(|c| {
        let tables: Vec<String> = c
            .prepare(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            )
            .and_then(|mut s| s.query_map([], |r| r.get(0))?.collect())
            .unwrap_or_default();
        let mut changed = 0;
        for t in tables {
            let cols: Vec<(String, String)> = c
                .prepare(&format!("PRAGMA table_info(\"{t}\")"))
                .and_then(|mut s| {
                    s.query_map([], |r| Ok((r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?
                        .collect()
                })
                .unwrap_or_default();
            for (col, ty) in cols {
                // Declared TEXT, or untyped (SQLite stores whatever was written).
                let ty = ty.to_ascii_uppercase();
                if !(ty.is_empty() || ty.contains("TEXT") || ty.contains("CHAR")) {
                    continue;
                }
                let sql = format!(
                    "UPDATE \"{t}\" SET \"{col}\" = replace(\"{col}\", ?1, ?2) \
                     WHERE typeof(\"{col}\") = 'text' AND instr(\"{col}\", ?1) > 0"
                );
                changed += c.execute(&sql, [&old, &new]).unwrap_or(0);
            }
        }
        changed
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const NEW: &str = "app.spotless.desktop";

    fn scratch(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("spotless-migrate-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn write(p: &Path, text: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }

    #[test]
    fn old_folders_move_to_the_new_id_with_everything_in_them() {
        let lib = scratch("move");
        let support = lib.join("Application Support");
        write(&support.join(OLD_ID).join("encore.sqlite"), "db");
        write(&support.join(OLD_ID).join("Downloads/a.m4a"), "song");
        write(&support.join(OLD_ID).join("encore.log"), "log");
        write(&lib.join("Caches").join(OLD_ID).join("Cache.db"), "c");
        write(&lib.join("WebKit").join(OLD_ID).join("WebsiteData/LocalStorage/x"), "prefs");

        let dirs = vec![
            support.join(NEW),
            lib.join("Caches").join(NEW),
            lib.join("Logs").join(NEW), // no old one: skipped
            lib.join("WebKit").join(NEW),
            support.join(NEW), // listed twice (data and local data are the same on macOS)
        ];
        let r = migrate(&dirs, NEW, OLD_ID);
        assert_eq!(r.moved.len(), 3, "{r:?}");
        assert!(r.failed.is_empty());
        let read = |p: PathBuf| std::fs::read_to_string(p).unwrap();
        assert_eq!(read(support.join(NEW).join("encore.sqlite")), "db");
        assert_eq!(read(support.join(NEW).join("Downloads/a.m4a")), "song");
        assert_eq!(read(lib.join("Caches").join(NEW).join("Cache.db")), "c");
        assert_eq!(read(lib.join("WebKit").join(NEW).join("WebsiteData/LocalStorage/x")), "prefs");
        assert!(!support.join(OLD_ID).exists() && !lib.join("Logs").join(NEW).exists());

        // A second launch: nothing left to do.
        let again = migrate(&dirs, NEW, OLD_ID);
        assert!(again.moved.is_empty() && again.failed.is_empty());
        std::fs::remove_dir_all(&lib).ok();
    }

    #[test]
    fn an_existing_new_folder_wins_and_the_old_one_is_left_alone() {
        let lib = scratch("keep");
        write(&lib.join(OLD_ID).join("encore.sqlite"), "old");
        write(&lib.join(NEW).join("encore.sqlite"), "new");
        let r = migrate(&[lib.join(NEW)], NEW, OLD_ID);
        assert!(r.moved.is_empty());
        assert_eq!(std::fs::read_to_string(lib.join(NEW).join("encore.sqlite")).unwrap(), "new");
        assert_eq!(std::fs::read_to_string(lib.join(OLD_ID).join("encore.sqlite")).unwrap(), "old");
        std::fs::remove_dir_all(&lib).ok();
    }

    #[test]
    fn pending_until_moved() {
        let lib = scratch("pending");
        write(&lib.join(OLD_ID).join("encore.sqlite"), "db");
        let dirs = [lib.join(NEW)];
        assert!(pending(&dirs, NEW, OLD_ID));
        migrate(&dirs, NEW, OLD_ID);
        assert!(!pending(&dirs, NEW, OLD_ID));
        std::fs::remove_dir_all(&lib).ok();
    }

    #[test]
    fn nothing_to_move_on_a_fresh_install() {
        let lib = scratch("fresh");
        let r = migrate(&[lib.join(NEW), lib.join("unrelated")], NEW, OLD_ID);
        assert!(r.moved.is_empty() && r.failed.is_empty());
        assert!(!lib.join(NEW).exists());
        std::fs::remove_dir_all(&lib).ok();
    }

    #[test]
    fn macos_adds_the_webkit_folders() {
        let home = Path::new("/Users/x");
        let dirs = app_dirs(&[Some(PathBuf::from("/a").join(NEW)), None], Some(home), NEW);
        assert_eq!(dirs[0], PathBuf::from("/a").join(NEW));
        if cfg!(target_os = "macos") {
            assert!(dirs.contains(&home.join("Library/WebKit").join(NEW)));
            assert!(dirs.contains(&home.join("Library/HTTPStorages").join(NEW)));
        }
    }

    #[test]
    fn stored_paths_follow_the_moved_folder() {
        let db = encore_core::db::Db::open(Path::new(":memory:")).unwrap();
        let old = PathBuf::from("/Users/x/Library/Application Support").join(OLD_ID);
        let new = PathBuf::from("/Users/x/Library/Application Support").join(NEW);
        let cover = format!(
            r#"{{"id":"MFY_DAILY_1","cover":"{}/covers/mfy/MFY_DAILY_1.svg"}}"#,
            old.display()
        );
        db.with_conn(|c| {
            c.execute(
                "CREATE TABLE IF NOT EXISTS smart_mfy (id TEXT PRIMARY KEY, json TEXT NOT NULL, \
                 generated_at INTEGER NOT NULL)",
                [],
            )
            .unwrap();
            c.execute(
                "INSERT INTO smart_mfy(id, json, generated_at) VALUES('MFY_DAILY_1', ?1, 1)",
                [&cover],
            )
            .unwrap();
        });
        db.set_setting("unrelated", "/Users/x/Music/app.encore.desktop.txt");
        assert_eq!(rewrite_paths(&db, &old, &new), 1);
        let json: String =
            db.with_conn(|c| c.query_row("SELECT json FROM smart_mfy", [], |r| r.get(0)).unwrap());
        assert!(json.contains(&format!("{}/covers/mfy/MFY_DAILY_1.svg", new.display())), "{json}");
        assert!(!json.contains(OLD_ID));
        assert_eq!(
            db.get_setting("unrelated").as_deref(),
            Some("/Users/x/Music/app.encore.desktop.txt")
        );
        assert_eq!(rewrite_paths(&db, &old, &new), 0, "idempotent");
    }
}
