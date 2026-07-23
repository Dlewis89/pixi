//! Historical aggregator for `zig build test` — no longer used as a test root.
//!
//! Zig only registers `test` blocks from an artifact's **root module**. The old
//! pattern of `addAnonymousImport` + `_ = @import("fizzy-…")` analyzed those
//! files but never collected their tests, so `fizzy-unit-tests` ran zero of them.
//!
//! Pure-logic coverage is now one `b.addTest` per file in `build/app.zig`
//! (same pattern as `fizzy-fuzzy-tests`). SDK tests that need dvui/proxy_bridge
//! (`src/sdk/dylib.zig` and siblings) live under `zig build test-integration`
//! via a root module at `src/sdk/sdk.zig`.
