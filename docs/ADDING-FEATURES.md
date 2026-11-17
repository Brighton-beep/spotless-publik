# Adding a feature

The Mac and iPhone apps are one product: shared logic, two UIs.

1. **Core first.** Put the logic in `crates/core`, with Rust tests. This covers rules, sorting, grouping and logic-driven wording. Layout, animation, gestures and platform APIs stay in the UI.
2. **Both bridges.** Register a `#[tauri::command]` in `src-tauri/src/lib.rs` and add an arm in `crates/ffi/src/invoke.rs`, using the same name and the same `camelCase` args.
3. **Both UIs in the same change:** `ui/` and `ios/Encore`. Neither UI keeps its own copy of a rule.
4. **Keep the parity test green:** `cargo test -p encore-ffi --lib`. A command on one side only needs a line, with its reason, in `crates/ffi/parity_allowlist.txt`.
