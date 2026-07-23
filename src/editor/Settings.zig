const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const std = @import("std");
const dvui = @import("dvui");
const SettingsMigration = @import("SettingsMigration.zig");

const Settings = @This();

pub const default_theme = "Fizzy Dark";

/// Duration after the last edit before autosave runs (during normal operation).
pub const autosave_timeout_ns: i128 = 500 * 1_000_000;

/// The zon-parsed on-disk value backing the most recent successful `load`, kept alive
/// for the process lifetime (freed in `deinit`). `theme` is independently heap-owned
/// (duped in `load`), so it survives even though this is freed at shutdown rather than
/// right after load.
var loaded: ?Settings = null;

pub const FlipbookView = enum { sequential, grid };
pub const Compatibility = enum { none, ldtk };

/// Canvas zoom/pan control preference. `auto` follows `dvui.mouseType()` after scroll events
/// (macOS defaults to trackpad when still unknown).
pub const InputScheme = enum { auto, mouse, trackpad };

/// Resolved zoom/pan style after applying `input_scheme`.
pub const ResolvedPanZoomScheme = enum { mouse, trackpad };

/// Touch or long-press duration (ms) before a context menu opens instead of a normal click.
/// A real user (accessibility/touch) preference, unlike the dev-only knobs in `Constants.zig`.
hold_menu_duration_ms: u32 = 500,

/// Last selected UI theme (`dvui.Theme.name`). Always allocator-owned after `load`; see `setThemeName` / `deinit`.
theme: []const u8 = default_theme,

/// Logical font sizes applied to body / title / heading / mono slots for every theme (families unchanged).
font_body_size: f32 = 9,
font_title_size: f32 = 9,
font_heading_size: f32 = 8,
font_mono_size: f32 = 8,

/// Opacity of the background window
/// CURRENTLY ONLY SUPPORTED ON MACOS and Windows
window_opacity_dark: f32 = 0.7,
window_opacity_light: f32 = 0.3,

/// Opacity of the content area (also drives plugin panes that match the shell chrome).
content_opacity: f32 = 0.7,

/// Canvas zoom/pan control scheme shared by the image viewer, pixi, and any other
/// `CanvasWidget` consumer. `auto` picks mouse vs trackpad from `dvui.mouseType()`.
input_scheme: InputScheme = .auto,

fn default(allocator: std.mem.Allocator) !Settings {
    return .{
        .theme = try allocator.dupe(u8, default_theme),
    };
}

pub fn resolvedPanZoomScheme(settings: *const Settings, is_macos: bool) ResolvedPanZoomScheme {
    return switch (settings.input_scheme) {
        .auto => switch (dvui.mouseType()) {
            .unknown => if (is_macos) .trackpad else .mouse,
            .mouse => .mouse,
            .trackpad => .trackpad,
        },
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}

pub fn setThemeName(settings: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, settings.theme, name)) return;
    const copy = try allocator.dupe(u8, name);
    allocator.free(settings.theme);
    settings.theme = copy;
}

/// Loads settings (`theme` is always heap-owned after successful return — see `setThemeName` / `deinit`).
/// One-shot migrates any pre-R10 `<plugins_dir>/<id>.settings.zon` files into this file's
/// `.plugins.<id>` field first (see `SettingsMigration.mergeLegacyPerPluginFiles`), then any
/// pre-R12 flat plugin blocks + top-level `disabled_plugins` into nested
/// `.{ .enabled, .settings }` (see `SettingsMigration.migrateToPerPluginEnabled`). Unknown
/// fields (including `.plugins`, which this struct doesn't itself model — see
/// `serialize`'s doc comment) are ignored, both for forward-compat with newer on-disk shapes and
/// because `.plugins` is read separately, per-plugin, via `Host.loadPluginSettings`.
pub fn load(allocator: std.mem.Allocator, path: []const u8, plugins_dir: ?[]const u8) !Settings {
    // Wasm: no on-disk config; `fizzy.fs` uses `Io.Dir.cwd()` (posix.AT).
    if (comptime builtin.target.cpu.arch == .wasm32) return default(allocator);

    SettingsMigration.mergeLegacyPerPluginFiles(allocator, path, plugins_dir);
    SettingsMigration.migrateToPerPluginEnabled(allocator, path, plugins_dir);

    const data = fizzy.fs.readZ(allocator, dvui.io, path) catch return default(allocator);
    defer allocator.free(data);

    const parsed = parseOnly(allocator, data) catch |err| {
        dvui.log.warn("Could not parse settings.zon ({s}); using defaults.", .{@errorName(err)});
        return default(allocator);
    };

    if (loaded) |old| std.zon.parse.free(allocator, old);
    loaded = parsed;

    var result = parsed;
    // Own theme independently of `loaded` (freed in `deinit`, long after this returns).
    result.theme = try allocator.dupe(u8, parsed.theme);
    return result;
}

/// Parses `data` (already-read `settings.zon` bytes) into a `Settings` value, ignoring unknown
/// fields (forward-compat + `.plugins` is handled separately — see `load`'s doc comment above).
/// Unlike `load`, this returns the raw parse error on failure instead of falling back to
/// defaults — defaulting is only correct when there's no existing live state to fall back *to*
/// (startup); `Editor.reconcileExternalSettingsChange` (external hand-edit reconciliation, R11)
/// has existing state and must not let a transient torn-write read reset every shell field and
/// every plugin's settings. Caller frees the result with `std.zon.parse.free` (not
/// `Settings.deinit`, which manages this module's own `loaded` snapshot — bypassed here on
/// purpose for a lightweight one-off parse).
pub fn parseOnly(allocator: std.mem.Allocator, data: [:0]const u8) !Settings {
    @setEvalBranchQuota(10_000);
    return std.zon.parse.fromSliceAlloc(Settings, allocator, data, null, .{ .ignore_unknown_fields = true });
}

/// Serialize the shell's own fields as `.{ ...shell fields... }`. This is *not* the whole
/// `settings.zon` file — plugin settings are a separate `.plugins = .{ .<id> = .{...}, ... }`
/// field spliced on afterward by `Editor.composeSettingsText`/`SettingsPluginsZon.composeMergedText`
/// (see `docs/PLUGIN_MANIFEST_PLAN.md` R10). `Editor.writeMergedSettings` is the only writer of
/// `settings.zon` — there is no standalone shell-only save path anymore, since writing this half
/// alone would silently drop the `.plugins` half.
pub fn serialize(settings: *const Settings, allocator: std.mem.Allocator) ![]u8 {
    @setEvalBranchQuota(10_000);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(settings.*, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

pub fn deinit(settings: *Settings, allocator: std.mem.Allocator) void {
    allocator.free(settings.theme);
    if (loaded) |d| {
        std.zon.parse.free(allocator, d);
        loaded = null;
    }
}
