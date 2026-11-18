#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sets the app's version where Spotless keeps it.

    python3 -I publik/set-version.py <from> <to>

Used by release.sh (a publik-only version such as 1.0.4-rc.5.1 on
fjenn/spotless's 1.0.4-rc.5) and by sync.sh (back to fjenn/spotless's version
before merging a new release of it). Run from the repository root.
"""
import sys


def swap(path: str, before: str, after: str, every: bool = False) -> None:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if before not in text:
        sys.exit(f"set-version: {path} has no {before!r}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(before, after) if every else text.replace(before, after, 1))


def main() -> None:
    old, new = sys.argv[1], sys.argv[2]
    swap("Cargo.toml", f'version = "{old}"', f'version = "{new}"')
    swap("src-tauri/tauri.conf.json", f'"version": "{old}"', f'"version": "{new}"')
    # The workspace crates in the lock file all carry the workspace version.
    swap("Cargo.lock", f'version = "{old}"', f'version = "{new}"', every=True)


if __name__ == "__main__":
    main()
