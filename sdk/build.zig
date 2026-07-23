//! Plugin-facing Fizzy package. Plugins depend on this directory (not the repo root) so
//! app-only deps like Velopack never enter their zon graph — see CLAUDE.md.
const std = @import("std");

pub const plugin = @import("plugin_sdk.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Accepted for compatibility with `b.dependency("fizzy", .{ .plugin_sdk = true })`.
    // This package always exports plugin modules; it never builds the app.
    _ = b.option(
        bool,
        "plugin_sdk",
        "Export core/sdk modules for plugin builds (always on in this package)",
    );

    try plugin.exportModules(b, target, optimize);
}
