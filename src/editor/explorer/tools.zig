const std = @import("std");
const Pixi = @import("../../Pixi.zig");
const core = @import("mach").core;
const imgui = @import("zig-imgui");
const layers = @import("layers.zig");
const zmath = @import("zmath");

pub fn draw() void {
    imgui.pushStyleColorImVec4(imgui.Col_Header, Pixi.state.theme.foreground.toImguiVec4());
    imgui.pushStyleColorImVec4(imgui.Col_HeaderHovered, Pixi.state.theme.foreground.toImguiVec4());
    imgui.pushStyleColorImVec4(imgui.Col_HeaderActive, Pixi.state.theme.foreground.toImguiVec4());
    defer imgui.popStyleColorEx(3);

    imgui.pushStyleVarImVec2(imgui.StyleVar_ItemSpacing, .{ .x = 4.0, .y = 4.0 });
    imgui.pushStyleVarImVec2(imgui.StyleVar_SelectableTextAlign, .{ .x = 0.5, .y = 0.8 });
    imgui.pushStyleVarImVec2(imgui.StyleVar_FramePadding, .{ .x = 6.0, .y = 6.0 });
    defer imgui.popStyleVarEx(3);

    if (imgui.beginChild("Tools", .{
        .x = imgui.getWindowWidth(),
        .y = -1.0,
    }, imgui.ChildFlags_None, imgui.WindowFlags_ChildWindow)) {
        defer imgui.endChild();

        const style = imgui.getStyle();

        const button_width = imgui.getWindowWidth() / 3.6;
        const button_height = 36.0;

        const color_width = (imgui.getContentRegionAvail().x - style.indent_spacing) / 2.0 - style.item_spacing.x;

        {
            // Row 1
            {
                imgui.setCursorPosX(style.item_spacing.x * 3.0);
                drawTool(Pixi.fa.mouse_pointer, button_width, button_height, .pointer);
                imgui.sameLine();
                drawTool(Pixi.fa.pencil_alt, button_width, button_height, .pencil);
                imgui.sameLine();
                drawTool(Pixi.fa.eraser, button_width, button_height, .eraser);
            }

            imgui.spacing();

            // Row 2
            {
                imgui.setCursorPosX(style.item_spacing.x * 3.0);
                drawTool(Pixi.fa.sort_amount_up, button_width, button_height, .heightmap);
                imgui.sameLine();
                drawTool(Pixi.fa.fill_drip, button_width, button_height, .bucket);
                imgui.sameLine();
                drawTool(Pixi.fa.clipboard_check, button_width, button_height, .selection);
            }
        }

        imgui.pushStyleColorImVec4(imgui.Col_Header, Pixi.state.theme.background.toImguiVec4());
        imgui.pushStyleColorImVec4(imgui.Col_HeaderHovered, Pixi.state.theme.background.toImguiVec4());
        imgui.pushStyleColorImVec4(imgui.Col_HeaderActive, Pixi.state.theme.background.toImguiVec4());
        defer imgui.popStyleColorEx(3);

        imgui.spacing();

        if (imgui.collapsingHeader(Pixi.fa.paint_brush ++ "  Colors", imgui.TreeNodeFlags_DefaultOpen)) {
            imgui.indent();
            defer imgui.unindent();

            var heightmap_visible: bool = false;
            if (Pixi.Editor.getFile(Pixi.state.open_file_index)) |file| {
                heightmap_visible = file.heightmap.visible;
            }

            if (heightmap_visible) {
                var height: i32 = @as(i32, @intCast(Pixi.state.colors.height));
                if (imgui.sliderInt("Height", &height, 0, 255)) {
                    Pixi.state.colors.height = @as(u8, @intCast(std.math.clamp(height, 0, 255)));
                }
            } else {
                var disable_hotkeys: bool = false;

                const primary: imgui.Vec4 = if (Pixi.state.tools.current == .heightmap) .{ .x = 255, .y = 255, .z = 255, .w = 255 } else .{
                    .x = @as(f32, @floatFromInt(Pixi.state.colors.primary[0])) / 255.0,
                    .y = @as(f32, @floatFromInt(Pixi.state.colors.primary[1])) / 255.0,
                    .z = @as(f32, @floatFromInt(Pixi.state.colors.primary[2])) / 255.0,
                    .w = @as(f32, @floatFromInt(Pixi.state.colors.primary[3])) / 255.0,
                };

                const secondary: imgui.Vec4 = .{
                    .x = @as(f32, @floatFromInt(Pixi.state.colors.secondary[0])) / 255.0,
                    .y = @as(f32, @floatFromInt(Pixi.state.colors.secondary[1])) / 255.0,
                    .z = @as(f32, @floatFromInt(Pixi.state.colors.secondary[2])) / 255.0,
                    .w = @as(f32, @floatFromInt(Pixi.state.colors.secondary[3])) / 255.0,
                };

                if (imgui.colorButtonEx("Primary", primary, imgui.ColorEditFlags_AlphaPreview, .{
                    .x = color_width,
                    .y = 64,
                })) {
                    const color = Pixi.state.colors.primary;
                    Pixi.state.colors.primary = Pixi.state.colors.secondary;
                    Pixi.state.colors.secondary = color;
                }
                if (imgui.beginItemTooltip()) {
                    defer imgui.endTooltip();
                    imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), "Right click to edit color.");
                }
                if (imgui.beginPopupContextItem()) {
                    defer imgui.endPopup();
                    var c = Pixi.math.Color.initFloats(primary.x, primary.y, primary.z, primary.w).toSlice();
                    if (imgui.colorPicker4("Primary", &c, imgui.ColorEditFlags_None, null)) {
                        Pixi.state.colors.primary = .{
                            @as(u8, @intFromFloat(c[0] * 255.0)),
                            @as(u8, @intFromFloat(c[1] * 255.0)),
                            @as(u8, @intFromFloat(c[2] * 255.0)),
                            @as(u8, @intFromFloat(c[3] * 255.0)),
                        };
                    }
                    disable_hotkeys = true;
                }
                imgui.sameLine();

                if (imgui.colorButtonEx("Secondary", secondary, imgui.ColorEditFlags_AlphaPreview, .{
                    .x = color_width,
                    .y = 64,
                })) {
                    const color = Pixi.state.colors.primary;
                    Pixi.state.colors.primary = Pixi.state.colors.secondary;
                    Pixi.state.colors.secondary = color;
                }

                if (imgui.beginItemTooltip()) {
                    defer imgui.endTooltip();
                    imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), "Right click to edit color.");
                }

                if (imgui.beginPopupContextItem()) {
                    defer imgui.endPopup();
                    var c = Pixi.math.Color.initFloats(secondary.x, secondary.y, secondary.z, secondary.w).toSlice();
                    if (imgui.colorPicker4("Secondary", &c, imgui.ColorEditFlags_None, null)) {
                        Pixi.state.colors.secondary = .{
                            @as(u8, @intFromFloat(c[0] * 255.0)),
                            @as(u8, @intFromFloat(c[1] * 255.0)),
                            @as(u8, @intFromFloat(c[2] * 255.0)),
                            @as(u8, @intFromFloat(c[3] * 255.0)),
                        };
                    }

                    disable_hotkeys = true;
                }

                Pixi.state.hotkeys.disable = disable_hotkeys;
            }
        }

        const chip_width = 24.0;

        {
            imgui.indent();
            defer imgui.unindent();

            defer imgui.endChild();
            if (imgui.beginChild("ColorVariations", .{ .x = -1.0, .y = 28.0 }, imgui.ChildFlags_None, imgui.WindowFlags_ChildWindow | imgui.WindowFlags_NoScrollWithMouse)) {
                const count: usize = @intFromFloat((imgui.getContentRegionAvail().x) / (chip_width + style.item_spacing.x));

                const hue_shift: f32 = Pixi.state.settings.suggested_hue_shift;
                const hue_step: f32 = hue_shift / @as(f32, @floatFromInt(count));

                const sat_shift: f32 = Pixi.state.settings.suggested_sat_shift;
                const sat_step: f32 = sat_shift / @as(f32, @floatFromInt(count));

                const lit_shift: f32 = Pixi.state.settings.suggested_lit_shift;
                const lit_step: f32 = lit_shift / @as(f32, @floatFromInt(count));

                imgui.spacing();

                const chip_bar_width = @as(f32, @floatFromInt(count)) * (chip_width + style.item_spacing.x);

                const width_difference = imgui.getContentRegionAvail().x - chip_bar_width;

                if (width_difference > 0.0) {
                    imgui.indentEx(width_difference / 2.0);
                }

                const red = @as(f32, @floatFromInt(Pixi.state.colors.primary[0])) / 255.0;
                const green = @as(f32, @floatFromInt(Pixi.state.colors.primary[1])) / 255.0;
                const blue = @as(f32, @floatFromInt(Pixi.state.colors.primary[2])) / 255.0;
                const alpha = @as(f32, @floatFromInt(Pixi.state.colors.primary[3])) / 255.0;

                const primary_hsl = zmath.rgbToHsl(.{ red, green, blue, alpha });

                const lightness_index: usize = @intFromFloat(@floor(primary_hsl[2] * @as(f32, @floatFromInt(count))));

                for (0..count) |i| {
                    const towards_purple: f32 = std.math.sign((primary_hsl[0] * 360.0) - 270.0);
                    const towards_yellow: f32 = std.math.sign((primary_hsl[0] * 360.0) - 60.0);
                    const purple_half: f32 = if (i < @divFloor(count, 2)) towards_purple else towards_yellow;
                    const difference: f32 = @as(f32, @floatFromInt(lightness_index)) - @as(f32, @floatFromInt(i));

                    const hue: f32 = primary_hsl[0] + std.math.clamp(difference * hue_step * purple_half, -hue_shift, hue_shift);
                    const saturation: f32 = primary_hsl[1] + difference * sat_step * purple_half;
                    const lightness: f32 = primary_hsl[2] - difference * lit_step;

                    var variation_hsl = zmath.hslToRgb(.{ hue, saturation, lightness, alpha });
                    variation_hsl = zmath.clampFast(variation_hsl, zmath.f32x4s(0.0), zmath.f32x4s(1.0));

                    const variation_color: imgui.Vec4 = .{ .x = variation_hsl[0], .y = variation_hsl[1], .z = variation_hsl[2], .w = variation_hsl[3] };

                    imgui.pushIDInt(@intCast(i));
                    defer imgui.popID();
                    if (imgui.colorButtonEx("##color", variation_color, imgui.ColorEditFlags_None, .{ .x = chip_width, .y = chip_width })) {
                        Pixi.state.colors.primary = .{
                            @intFromFloat(variation_color.x * 255.0),
                            @intFromFloat(variation_color.y * 255.0),
                            @intFromFloat(variation_color.z * 255.0),
                            @intFromFloat(variation_color.w * 255.0),
                        };
                    }
                    imgui.sameLine();

                    if (imgui.beginItemTooltip()) {
                        defer imgui.endTooltip();
                        imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), "Right click for suggested color options.");
                    }

                    if (imgui.beginPopupContextItem()) {
                        defer imgui.endPopup();

                        imgui.separatorText("Suggested Colors");

                        _ = imgui.sliderFloat("Hue Shift", &Pixi.state.settings.suggested_hue_shift, 0.0, 1.0);
                        _ = imgui.sliderFloat("Saturation Shift", &Pixi.state.settings.suggested_sat_shift, 0.0, 1.0);
                        _ = imgui.sliderFloat("Lightness Shift", &Pixi.state.settings.suggested_lit_shift, 0.0, 1.0);
                    }
                }
            }
        }

        if (imgui.collapsingHeader(Pixi.fa.layer_group ++ "  Layers", imgui.TreeNodeFlags_SpanAvailWidth | imgui.TreeNodeFlags_DefaultOpen)) {
            imgui.indent();
            defer imgui.unindent();
            layers.draw();
        }

        if (imgui.collapsingHeader(Pixi.fa.palette ++ "  Palettes", imgui.TreeNodeFlags_SpanFullWidth | imgui.TreeNodeFlags_DefaultOpen)) {
            imgui.indent();
            defer imgui.unindent();

            imgui.setNextItemWidth(-1.0);
            if (imgui.beginCombo("##PaletteCombo", if (Pixi.state.colors.palette) |palette| palette.name else "none", imgui.ComboFlags_HeightLargest)) {
                defer imgui.endCombo();
                searchPalettes() catch unreachable;
            }

            const columns: usize = @intFromFloat(@floor(imgui.getContentRegionAvail().x / (chip_width + style.item_spacing.x)));

            const chip_row_width: f32 = @as(f32, @floatFromInt(columns)) * (chip_width + style.item_spacing.x);

            const width_difference = imgui.getContentRegionAvail().x - chip_row_width;

            if (width_difference > 0.0) {
                imgui.indentEx(width_difference / 2.0);
            }

            const content_region_avail = imgui.getContentRegionAvail().y;

            const shadow_min: imgui.Vec2 = .{ .x = imgui.getCursorPosX() + imgui.getWindowPos().x, .y = imgui.getCursorPosY() + imgui.getWindowPos().y };
            const shadow_max: imgui.Vec2 = .{ .x = shadow_min.x + @as(f32, @floatFromInt(columns)) * (chip_width + style.item_spacing.x) - style.item_spacing.x, .y = shadow_min.y + Pixi.state.settings.shadow_length };
            const shadow_color = Pixi.math.Color.initFloats(0.0, 0.0, 0.0, Pixi.state.settings.shadow_opacity * 4.0).toU32();
            var scroll_y: f32 = 0.0;

            defer imgui.endChild(); // This can get cut off and causes a crash if begin child is not called because its off screen.
            if (imgui.beginChild("PaletteColors", .{ .x = 0.0, .y = @max(content_region_avail, chip_width) }, imgui.ChildFlags_None, imgui.WindowFlags_ChildWindow)) {
                if (Pixi.state.colors.palette) |palette| {
                    scroll_y = imgui.getScrollY();
                    for (palette.colors, 0..) |color, i| {
                        const c: imgui.Vec4 = .{
                            .x = @as(f32, @floatFromInt(color[0])) / 255.0,
                            .y = @as(f32, @floatFromInt(color[1])) / 255.0,
                            .z = @as(f32, @floatFromInt(color[2])) / 255.0,
                            .w = @as(f32, @floatFromInt(color[3])) / 255.0,
                        };
                        imgui.pushIDInt(@as(c_int, @intCast(i)));
                        if (imgui.colorButtonEx(palette.name, .{ .x = c.x, .y = c.y, .z = c.z, .w = c.w }, imgui.ColorEditFlags_None, .{ .x = chip_width, .y = chip_width })) {
                            Pixi.state.colors.primary = color;
                        }
                        imgui.popID();

                        if (@mod(i + 1, columns) > 0 and i != palette.colors.len - 1)
                            imgui.sameLine();
                    }
                } else {
                    imgui.pushStyleColorImVec4(imgui.Col_Text, Pixi.state.theme.text_background.toImguiVec4());
                    defer imgui.popStyleColor();
                    imgui.textWrapped("Currently there is no palette loaded, click the dropdown to select a palette");

                    const new_palette_text = std.fmt.allocPrintZ(Pixi.state.allocator, "To add new palettes, download a .hex palette from lospec.com and place it here: \n {s}{c}{s}", .{
                        Pixi.state.root_path,
                        std.fs.path.sep,
                        Pixi.assets.palettes,
                    }) catch unreachable;
                    defer Pixi.state.allocator.free(new_palette_text);

                    imgui.textWrapped(new_palette_text);
                }
            }

            if (Pixi.state.colors.palette != null and scroll_y != 0.0) {
                if (imgui.getWindowDrawList()) |draw_list| {
                    draw_list.addRectFilledMultiColor(shadow_min, shadow_max, shadow_color, shadow_color, 0x00000000, 0x00000000);
                }
            }
        }
    }
}

pub fn drawTool(label: [:0]const u8, w: f32, h: f32, tool: Pixi.Tools.Tool) void {
    imgui.pushStyleVarImVec2(imgui.StyleVar_SelectableTextAlign, .{ .x = 0.5, .y = 0.5 });
    defer imgui.popStyleVar();

    const selected = Pixi.state.tools.current == tool;
    if (selected) {
        imgui.pushStyleColorImVec4(imgui.Col_Text, Pixi.state.theme.text.toImguiVec4());
    } else {
        imgui.pushStyleColorImVec4(imgui.Col_Text, Pixi.state.theme.text_secondary.toImguiVec4());
    }
    defer imgui.popStyleColor();
    if (imgui.selectableEx(label, selected, imgui.SelectableFlags_None, .{ .x = w, .y = h })) {
        Pixi.state.tools.set(tool);
    }

    if (tool == .pencil or tool == .eraser or tool == .selection) {
        imgui.pushStyleColorImVec4(imgui.Col_Text, Pixi.state.theme.text.toImguiVec4());
        defer imgui.popStyleColor();
        if (imgui.beginPopupContextItem()) {
            defer imgui.endPopup();

            imgui.separatorText("Stroke Options");

            var stroke_size: c_int = @intCast(Pixi.state.tools.stroke_size);
            if (imgui.sliderInt("Size", &stroke_size, 1, Pixi.state.settings.stroke_max_size)) {
                Pixi.state.tools.stroke_size = @intCast(stroke_size);
            }

            const shape_label: [:0]const u8 = switch (Pixi.state.tools.stroke_shape) {
                .circle => "Circle",
                .square => "Square",
            };
            if (imgui.beginCombo("Shape", shape_label, imgui.ComboFlags_None)) {
                defer imgui.endCombo();
                if (imgui.selectable("Circle")) Pixi.state.tools.stroke_shape = .circle;
                if (imgui.selectable("Square")) Pixi.state.tools.stroke_shape = .square;
            }
        }
    }
    drawTooltip(tool);
}

pub fn drawTooltip(tool: Pixi.Tools.Tool) void {
    if (imgui.isItemHovered(imgui.HoveredFlags_DelayShort)) {
        if (imgui.beginTooltip()) {
            defer imgui.endTooltip();

            const text = switch (tool) {
                .pointer => "Pointer",
                .pencil => "Pencil",
                .eraser => "Eraser",
                .animation => "Animation",
                .heightmap => "Heightmap",
                .bucket => "Bucket",
                .selection => "Selection",
            };

            if (Pixi.state.hotkeys.hotkey(.{ .tool = tool })) |hotkey| {
                const hotkey_text = std.fmt.allocPrintZ(Pixi.state.allocator, "{s} ({s})", .{ text, hotkey.shortcut }) catch unreachable;
                defer Pixi.state.allocator.free(hotkey_text);
                imgui.text(hotkey_text);
            } else {
                imgui.text(text);
            }

            switch (tool) {
                .animation => {
                    if (Pixi.state.hotkeys.hotkey(.{ .proc = .primary })) |hotkey| {
                        const first_text = std.fmt.allocPrintZ(Pixi.state.allocator, "Click and drag with ({s}) released to edit the current animation", .{hotkey.shortcut}) catch unreachable;
                        defer Pixi.state.allocator.free(first_text);

                        const second_text = std.fmt.allocPrintZ(Pixi.state.allocator, "Click and drag while holding ({s}) to create a new animation", .{hotkey.shortcut}) catch unreachable;
                        defer Pixi.state.allocator.free(second_text);

                        imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), first_text);
                        imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), second_text);
                    }
                },
                .pencil, .eraser => {
                    imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), "Right click for size/shape options");
                },
                .selection => {
                    if (Pixi.state.hotkeys.hotkey(.{ .proc = .primary })) |primary_hk| {
                        if (Pixi.state.hotkeys.hotkey(.{ .proc = .secondary })) |secondary_hk| {
                            imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), "Right click for size/shape options");
                            const first_text = std.fmt.allocPrintZ(Pixi.state.allocator, "Click and drag while holding ({s}) to add to selection.", .{primary_hk.shortcut}) catch unreachable;
                            defer Pixi.state.allocator.free(first_text);

                            const second_text = std.fmt.allocPrintZ(Pixi.state.allocator, "Click and drag while holding ({s}) to remove from selection", .{secondary_hk.shortcut}) catch unreachable;
                            defer Pixi.state.allocator.free(second_text);
                            imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), first_text);
                            imgui.textColored(Pixi.state.theme.text_background.toImguiVec4(), second_text);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn searchPalettes() !void {
    var dir_opt = std.fs.cwd().openDir(Pixi.assets.palettes, .{ .access_sub_paths = false, .iterate = true }) catch null;
    if (dir_opt) |*dir| {
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, ext, ".hex")) {
                    const label = try std.fmt.allocPrintZ(Pixi.state.allocator, "{s}", .{entry.name});
                    defer Pixi.state.allocator.free(label);
                    if (imgui.selectable(label)) {
                        const abs_path = try std.fs.path.joinZ(Pixi.state.allocator, &.{ Pixi.assets.palettes, entry.name });
                        defer Pixi.state.allocator.free(abs_path);
                        if (Pixi.state.colors.palette) |*palette|
                            palette.deinit();

                        Pixi.state.colors.palette = Pixi.storage.Internal.Palette.loadFromFile(abs_path) catch null;
                    }
                }
            }
        }
    }
}
