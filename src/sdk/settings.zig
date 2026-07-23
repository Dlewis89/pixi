//! Comptime settings API for plugins — Zig build-options-style declaration.
//!
//!   const MySettings = sdk.settings.Schema(struct {
//!       insert_spaces_on_tab: bool = true,
//!       tab_size: u8 = 4,
//!       format_on_save: bool = false,
//!   });
//!   MySettings.load(host, plugin.id, &values);
//!   try MySettings.register(host, &plugin, .{ .title = "Text", .value = &values });
//!
//! Plugins register a typed value + field metadata only. The **shell** draws a shared
//! settings UI from `SettingsSchema.fields` (see `PluginSettingsPane`) — plugins do not
//! supply a `draw` callback.
//!
//! Loaded-only: a `SettingsSchema` exists in the Host registry only while the plugin is
//! registered.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const runtime = @import("runtime.zig");

pub const TypeTag = enum { bool, int, float, string, enumeration, color };

pub const IntKind = struct {
    min: i64,
    max: i64,
    /// A small discrete set (e.g. tab widths 2/4/8); empty = free slider/entry.
    choices: []const i64 = &.{},
};

pub const FloatKind = struct {
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 0.01,
};

pub const EnumKind = struct {
    /// Tag names in declaration order.
    choices: []const []const u8,
};

/// Per-type metadata for a `Setting` — only the variant matching `Setting.kind`'s active tag
/// is populated, so (say) a `bool` setting no longer carries meaningless `int`/`float` bounds.
pub const Kind = union(TypeTag) {
    bool: void,
    int: IntKind,
    float: FloatKind,
    string: void,
    enumeration: EnumKind,
    color: void,
};

pub const Setting = struct {
    key: []const u8,
    label: []const u8,
    kind: Kind,
};

/// Type-erased read/write of a `Schema(T).Value` for the shell's generic settings UI.
pub const Access = struct {
    getBool: *const fn (value: *anyopaque, field_index: usize) bool,
    setBool: *const fn (value: *anyopaque, field_index: usize, v: bool) void,
    getInt: *const fn (value: *anyopaque, field_index: usize) i64,
    setInt: *const fn (value: *anyopaque, field_index: usize, v: i64) void,
    getFloat: *const fn (value: *anyopaque, field_index: usize) f64,
    setFloat: *const fn (value: *anyopaque, field_index: usize, v: f64) void,
    getEnumIndex: *const fn (value: *anyopaque, field_index: usize) usize,
    setEnumIndex: *const fn (value: *anyopaque, field_index: usize, choice_index: usize) void,
    getString: *const fn (value: *anyopaque, field_index: usize) []const u8,
    setString: *const fn (value: *anyopaque, field_index: usize, v: []const u8) void,
    /// Persist `value` via `host.storePluginSettings(owner.id, zon)` and notify `owner`.
    persist: *const fn (value: *anyopaque, owner: *Plugin) void,
    /// Parse `blob` into `value` and notify `owner.settingsChanged(blob)` — the reconciliation-
    /// path counterpart to `persist` (which goes the other direction: live value → disk). Used
    /// only by external-change reconciliation (see R11 in docs/PLUGIN_MANIFEST_PLAN.md), never
    /// by an in-app edit through the settings pane.
    applyBlob: *const fn (value: *anyopaque, owner: *Plugin, blob: []const u8) void,
};

pub const SettingsSchema = struct {
    owner: *Plugin,
    title: []const u8,
    fields: []const Setting,
    /// Pointer to the plugin's `Schema(T).Value` (stable for the loaded lifetime).
    value: *anyopaque,
    access: *const Access,
    /// Hash of the last `.settings` blob text actually applied to `value` (seeded at `register()`
    /// time from whatever `loadPluginSettings` returned, if anything). Lets external-change
    /// reconciliation skip re-parsing/re-notifying a plugin whose own `.plugins.<id>.settings`
    /// hasn't changed, even when *some other* part of settings.zon has (see R11) — without this,
    /// any change anywhere in the file would spuriously renotify every loaded plugin, not just
    /// the one that changed.
    last_applied_hash: u64 = 0,
};

fn typeTagFor(comptime T: type) TypeTag {
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .@"enum" => .enumeration,
        .pointer => |p| if (p.size == .slice and p.child == u8)
            .string
        else
            @compileError("sdk.settings.Schema: unsupported field type " ++ @typeName(T)),
        else => @compileError("sdk.settings.Schema: unsupported field type " ++ @typeName(T)),
    };
}

fn intBounds(comptime IntT: type) struct { min: i64, max: i64 } {
    const info = @typeInfo(IntT).int;
    if (info.signedness == .signed) {
        return .{ .min = std.math.minInt(IntT), .max = std.math.maxInt(IntT) };
    }
    const max_u64: u64 = std.math.maxInt(IntT);
    const max: i64 = if (max_u64 > @as(u64, std.math.maxInt(i64))) std.math.maxInt(i64) else @intCast(max_u64);
    return .{ .min = 0, .max = max };
}

fn enumChoices(comptime EnumT: type) []const []const u8 {
    const enum_fields = std.meta.fields(EnumT);
    comptime var names: [enum_fields.len][]const u8 = undefined;
    inline for (enum_fields, 0..) |f, i| names[i] = f.name;
    const frozen = names;
    return &frozen;
}

/// Derive a field's `Kind` from its Zig type. `int`/`enumeration` get bounds/choices for free
/// from the type itself (bit-width, tag names); `float` has no such source (a bare `f32` carries
/// no notion of range), so it falls back to `FloatKind`'s defaults (0..1, step 0.01).
fn kindFor(comptime T: type) Kind {
    return switch (typeTagFor(T)) {
        .bool => .{ .bool = {} },
        .int => .{ .int = .{ .min = intBounds(T).min, .max = intBounds(T).max } },
        .float => .{ .float = .{} },
        .string => .{ .string = {} },
        .enumeration => .{ .enumeration = .{ .choices = enumChoices(T) } },
        .color => .{ .color = {} },
    };
}

fn buildSettings(comptime T: type) [std.meta.fields(T).len]Setting {
    const struct_fields = std.meta.fields(T);
    var out: [struct_fields.len]Setting = undefined;
    inline for (struct_fields, 0..) |f, i| {
        out[i] = .{
            .key = f.name,
            .label = f.name,
            .kind = kindFor(f.type),
        };
    }
    return out;
}

/// Build a settings namespace for plain struct `T`. Every field of `T` must declare a default
/// value — required to compute `default_value` below, which the non-default-only persistence
/// (see `diffSerialize`, R12 in docs/PLUGIN_MANIFEST_PLAN.md) diffs every value against.
pub fn Schema(comptime T: type) type {
    const struct_fields = std.meta.fields(T);
    const built_settings = buildSettings(T);

    const default_value: T = blk: {
        inline for (struct_fields) |f| {
            _ = f.defaultValue() orelse @compileError(
                "sdk.settings.Schema: field '" ++ f.name ++ "' of " ++ @typeName(T) ++
                    " needs a default value (required so settings.zon only has to record what " ++
                    "differs from it)",
            );
        }
        break :blk .{};
    };

    return struct {
        pub const Value = T;
        pub const settings: []const Setting = &built_settings;

        pub fn load(host: anytype, id: []const u8, out: *T) void {
            const blob = host.loadPluginSettings(id) orelse return;
            defer host.allocator.free(blob);
            applyZon(out, blob);
        }

        /// Serializes the *whole* current value — used only to notify `settingsChanged`, which
        /// documents `blob` as "the whole, freshly-serialized zon text." What's actually
        /// persisted to disk is `diffSerialize`'s smaller, non-default-only blob instead; the two
        /// don't need to match byte-for-byte, and a plugin's own `applyZon`-based re-parse can't
        /// tell the difference either way (missing fields fill from `T`'s own defaults).
        fn fullSerialize(gpa: std.mem.Allocator, value: T) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try std.zon.stringify.serialize(value, .{}, &aw.writer);
            return aw.toOwnedSlice();
        }

        fn fieldEqual(comptime FT: type, a: FT, b: FT) bool {
            return switch (@typeInfo(FT)) {
                .bool, .int, .float, .@"enum" => a == b,
                .pointer => |p| if (p.size == .slice and p.child == u8) std.mem.eql(u8, a, b) else false,
                else => false,
            };
        }

        fn isAllDefault(value: T) bool {
            inline for (struct_fields) |f| {
                if (!fieldEqual(f.type, @field(value, f.name), @field(default_value, f.name))) return false;
            }
            return true;
        }

        /// Serializes only the fields of `value` that differ from `T`'s own declared defaults —
        /// e.g. `.{ .tab_size = 8 }` instead of every field. Returns `null` when `value` is
        /// entirely default, signaling "nothing to persist" (the caller removes any existing
        /// on-disk entry for this id entirely, rather than writing an empty/default blob).
        fn diffSerialize(gpa: std.mem.Allocator, value: T) !?[]u8 {
            if (isAllDefault(value)) return null;
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try aw.writer.writeAll(".{\n");
            inline for (struct_fields) |f| {
                if (!fieldEqual(f.type, @field(value, f.name), @field(default_value, f.name))) {
                    try aw.writer.print("    .{f} = ", .{std.zig.fmtId(f.name)});
                    try std.zon.stringify.serialize(@field(value, f.name), .{}, &aw.writer);
                    try aw.writer.writeAll(",\n");
                }
            }
            try aw.writer.writeAll("}");
            return try aw.toOwnedSlice();
        }

        pub fn store(host: anytype, id: []const u8, value: T) void {
            const gpa = host.allocator;
            const blob = diffSerialize(gpa, value) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}': {s}", .{ id, @errorName(err) });
                return;
            };
            if (blob) |b| {
                defer gpa.free(b);
                host.storePluginSettings(id, b) catch |err| {
                    dvui.log.warn("sdk.settings: failed to store '{s}': {s}", .{ id, @errorName(err) });
                };
            } else {
                host.removePluginSettings(id) catch |err| {
                    dvui.log.warn("sdk.settings: failed to remove '{s}': {s}", .{ id, @errorName(err) });
                };
            }
        }

        pub fn applyZon(out: *T, blob: []const u8) void {
            const gpa = runtime.allocator();
            const blob_z = gpa.dupeZ(u8, blob) catch |err| {
                dvui.log.warn("sdk.settings: out of memory parsing settings: {s}", .{@errorName(err)});
                return;
            };
            defer gpa.free(blob_z);

            const parsed = std.zon.parse.fromSliceAlloc(T, gpa, blob_z, null, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                dvui.log.warn("sdk.settings: failed to parse settings: {s}", .{@errorName(err)});
                return;
            };
            std.zon.parse.free(gpa, out.*);
            out.* = parsed;
        }

        fn asValue(ptr: *anyopaque) *T {
            return @ptrCast(@alignCast(ptr));
        }

        fn getBool(ptr: *anyopaque, field_index: usize) bool {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .bool) return false;
                    return @field(v.*, f.name);
                }
            }
            return false;
        }

        fn setBool(ptr: *anyopaque, field_index: usize, b: bool) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .bool) @field(v.*, f.name) = b;
                    return;
                }
            }
        }

        fn getInt(ptr: *anyopaque, field_index: usize) i64 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .int) return 0;
                    return @intCast(@field(v.*, f.name));
                }
            }
            return 0;
        }

        fn setInt(ptr: *anyopaque, field_index: usize, n: i64) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .int) {
                        @field(v.*, f.name) = std.math.cast(f.type, n) orelse @field(v.*, f.name);
                    }
                    return;
                }
            }
        }

        fn getFloat(ptr: *anyopaque, field_index: usize) f64 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .float) return 0;
                    return @floatCast(@field(v.*, f.name));
                }
            }
            return 0;
        }

        fn setFloat(ptr: *anyopaque, field_index: usize, n: f64) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .float) @field(v.*, f.name) = @floatCast(n);
                    return;
                }
            }
        }

        fn getEnumIndex(ptr: *anyopaque, field_index: usize) usize {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .@"enum") return 0;
                    // Declaration-order position, matching `enumChoices`' `choices` list and
                    // `setEnumIndex`'s `std.meta.tags(f.type)[choice_index]` — not the enum's
                    // raw backing integer, which for an explicit-value enum like `TabSize`
                    // (`@"2" = 2, @"4" = 4, @"8" = 8`) is out of range for `choices.len`.
                    const current = @field(v.*, f.name);
                    const tags = std.meta.tags(f.type);
                    inline for (tags, 0..) |t, ti| {
                        if (t == current) return ti;
                    }
                    return 0;
                }
            }
            return 0;
        }

        fn setEnumIndex(ptr: *anyopaque, field_index: usize, choice_index: usize) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .@"enum") {
                        const tags = std.meta.tags(f.type);
                        if (choice_index < tags.len) @field(v.*, f.name) = tags[choice_index];
                    }
                    return;
                }
            }
        }

        fn getString(ptr: *anyopaque, field_index: usize) []const u8 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (comptime typeTagFor(f.type) == .string) return @field(v.*, f.name);
                    return "";
                }
            }
            return "";
        }

        fn setString(ptr: *anyopaque, field_index: usize, s: []const u8) void {
            _ = ptr;
            _ = field_index;
            _ = s;
            // String fields that own memory need a plugin-specific allocator policy;
            // not used by built-ins yet. Shell UI skips editable strings until then.
        }

        const access_vtable: Access = .{
            .getBool = getBool,
            .setBool = setBool,
            .getInt = getInt,
            .setInt = setInt,
            .getFloat = getFloat,
            .setFloat = setFloat,
            .getEnumIndex = getEnumIndex,
            .setEnumIndex = setEnumIndex,
            .getString = getString,
            .setString = setString,
            .persist = persistValue,
            .applyBlob = applyBlobValue,
        };

        /// Queues `value`'s **non-default fields only** for the next merged settings.zon write, or
        /// queues the whole entry's removal when nothing differs from `T`'s declared defaults.
        /// Returns false (already logged) if it couldn't queue anything.
        ///
        /// Shared by both writers — the in-app edit path (`persistValue`) and the external
        /// hand-edit reconciliation path (`applyBlobValue`) — so settings.zon lands in the same
        /// normalized, non-default-only shape (R12) no matter which one got there. Routing the
        /// external path through here too is what prunes a field the user hand-edited back to its
        /// default, including when *other* fields in the same block are still non-default.
        ///
        /// Cost of normalizing on the external path: this re-emits the plugin's `.settings` block
        /// canonically, so comments/formatting the user wrote *inside that block* don't survive
        /// (R10's verbatim-span preservation still protects every other part of the file, and any
        /// plugin block that wasn't touched this cycle).
        fn queueNormalizedPersist(owner_id: []const u8, value: T) bool {
            const host = runtime.host();
            const gpa = host.allocator;

            const diff_blob = diffSerialize(gpa, value) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}': {s}", .{ owner_id, @errorName(err) });
                return false;
            };
            if (diff_blob) |b| {
                defer gpa.free(b);
                host.storePluginSettings(owner_id, b) catch |err| {
                    dvui.log.warn("sdk.settings: failed to store '{s}': {s}", .{ owner_id, @errorName(err) });
                    return false;
                };
            } else {
                host.removePluginSettings(owner_id) catch |err| {
                    dvui.log.warn("sdk.settings: failed to remove '{s}': {s}", .{ owner_id, @errorName(err) });
                    return false;
                };
            }
            return true;
        }

        fn persistValue(ptr: *anyopaque, owner: *Plugin) void {
            const value = asValue(ptr).*;
            if (!queueNormalizedPersist(owner.id, value)) return;

            const gpa = runtime.host().allocator;
            const notify_blob = fullSerialize(gpa, value) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}' for notification: {s}", .{ owner.id, @errorName(err) });
                return;
            };
            defer gpa.free(notify_blob);
            owner.settingsChanged(notify_blob);
        }

        /// The reconciliation-path counterpart to `persistValue` — parses a freshly-read blob
        /// (from external-change reconciliation, see R11) into the live value, re-queues it in
        /// normalized form, and notifies the plugin, same as an in-app edit would. Caller
        /// (`Editor.reconcileExternalSettingsChange`) is responsible for only calling this when
        /// `blob`'s hash actually differs from `SettingsSchema.last_applied_hash` — this function
        /// itself doesn't check.
        ///
        /// The re-queue is what keeps a hand-edited file converging on R12's non-default-only
        /// shape: any field the user spelled back out at its default drops out on the next write,
        /// whether or not its siblings are still non-default. See `queueNormalizedPersist` for
        /// what that costs.
        fn applyBlobValue(ptr: *anyopaque, owner: *Plugin, blob: []const u8) void {
            const value = asValue(ptr);
            applyZon(value, blob);
            _ = queueNormalizedPersist(owner.id, value.*);
            owner.settingsChanged(blob);
        }

        /// Register schema + value pointer. The shell draws controls from `fields` via `access`.
        pub fn register(host: anytype, plugin: *Plugin, opts: struct {
            title: []const u8,
            value: *T,
        }) !void {
            // Seed `last_applied_hash` from whatever's on disk right now (the same blob `load()`
            // was just called with, immediately before this, per this module's documented
            // calling convention) so the *first* reconciliation after startup doesn't spuriously
            // renotify a plugin whose settings haven't actually changed since load.
            const seed_hash: u64 = blk: {
                const blob = host.loadPluginSettings(plugin.id) orelse break :blk 0;
                defer host.allocator.free(blob);
                break :blk std.hash.Wyhash.hash(0, blob);
            };
            try host.registerSettingsSchema(.{
                .owner = plugin,
                .title = opts.title,
                .fields = settings,
                .value = opts.value,
                .access = &access_vtable,
                .last_applied_hash = seed_hash,
            });
        }
    };
}

const testing = std.testing;

test "Schema() derives field metadata from a plain struct" {
    const S = Schema(struct {
        insert_spaces_on_tab: bool = true,
        tab_size: u8 = 4,
        ratio: f32 = 1.0,
        mode: enum { fast, slow } = .fast,
    });

    try testing.expectEqual(@as(usize, 4), S.settings.len);
    try testing.expectEqual(TypeTag.bool, std.meta.activeTag(S.settings[0].kind));
    try testing.expectEqual(TypeTag.int, std.meta.activeTag(S.settings[1].kind));
    try testing.expectEqual(@as(i64, 0), S.settings[1].kind.int.min);
    try testing.expectEqual(@as(i64, 255), S.settings[1].kind.int.max);
    try testing.expectEqual(TypeTag.float, std.meta.activeTag(S.settings[2].kind));
    try testing.expectEqual(TypeTag.enumeration, std.meta.activeTag(S.settings[3].kind));
    try testing.expectEqualStrings("fast", S.settings[3].kind.enumeration.choices[0]);
}

test "getEnumIndex/setEnumIndex use declaration-order position, not the enum's backing value" {
    // Regression: an explicit-value enum (like text's `TabSize`) has backing values that don't
    // match declaration-order position. `getEnumIndex` previously returned `@intFromEnum`
    // directly, which was out of range for `choices.len` whenever the backing values weren't
    // 0/1/2/... — the settings pane's dropdown preview showed "?" for every value.
    const TabSize = enum(u8) { @"2" = 2, @"4" = 4, @"8" = 8 };
    const S = Schema(struct {
        tab_size: TabSize = .@"4",
    });
    var value: S.Value = .{ .tab_size = .@"4" };

    // Declaration-order position (1), not the backing value (4).
    try testing.expectEqual(@as(usize, 1), S.access_vtable.getEnumIndex(&value, 0));

    S.access_vtable.setEnumIndex(&value, 0, 2);
    try testing.expectEqual(TabSize.@"8", value.tab_size);
    try testing.expectEqual(@as(usize, 2), S.access_vtable.getEnumIndex(&value, 0));
}

test "applyZon parses a zon blob into the value type" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        tab_size: u8 = 4,
        format_on_save: bool = false,
    });

    var value: S.Value = .{};
    S.applyZon(&value, ".{ .tab_size = 8, .format_on_save = true }");

    try testing.expectEqual(@as(u8, 8), value.tab_size);
    try testing.expectEqual(true, value.format_on_save);
}

test "diffSerialize returns null when every field is default (R12 non-default-only persistence)" {
    const S = Schema(struct {
        insert_spaces_on_tab: bool = true,
        tab_size: u8 = 4,
        format_on_save: bool = false,
    });

    const all_default: S.Value = .{};
    try testing.expect(try S.diffSerialize(testing.allocator, all_default) == null);
}

test "isAllDefault treats a field explicitly spelled out at its default as still default" {
    // Drives `queueNormalizedPersist`'s remove-the-whole-entry branch: the user writes
    // `.{ .insert_spaces_on_tab = true }` (the declared default) back into settings.zon by hand,
    // so the entry is redundant and should come back out of the file. (The partial case — some
    // fields default, some not — is `diffSerialize`'s job; see the test below.)
    const S = Schema(struct {
        insert_spaces_on_tab: bool = true,
        tab_size: u8 = 4,
    });

    try testing.expect(S.isAllDefault(.{}));
    try testing.expect(S.isAllDefault(.{ .insert_spaces_on_tab = true, .tab_size = 4 }));
    try testing.expect(!S.isAllDefault(.{ .insert_spaces_on_tab = false }));
    try testing.expect(!S.isAllDefault(.{ .tab_size = 8 }));
}

test "diffSerialize emits only the fields that differ from T's own defaults" {
    const S = Schema(struct {
        insert_spaces_on_tab: bool = true,
        tab_size: u8 = 4,
        format_on_save: bool = false,
    });

    const changed: S.Value = .{ .tab_size = 8 };
    const blob = (try S.diffSerialize(testing.allocator, changed)).?;
    defer testing.allocator.free(blob);

    try testing.expect(std.mem.indexOf(u8, blob, "tab_size") != null);
    try testing.expect(std.mem.indexOf(u8, blob, "insert_spaces_on_tab") == null);
    try testing.expect(std.mem.indexOf(u8, blob, "format_on_save") == null);
}

test "a partial (diff-only) blob still fills the rest from T's own declared defaults" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        insert_spaces_on_tab: bool = true,
        tab_size: u8 = 4,
        format_on_save: bool = false,
    });

    var value: S.Value = .{};
    // Exactly the shape `diffSerialize` would have produced for `.{ .tab_size = 8 }`.
    S.applyZon(&value, ".{ .tab_size = 8 }");

    try testing.expectEqual(@as(u8, 8), value.tab_size);
    try testing.expectEqual(true, value.insert_spaces_on_tab);
    try testing.expectEqual(false, value.format_on_save);
}
