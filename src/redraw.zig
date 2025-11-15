const std = @import("std");
const msgpack = @import("msgpack.zig");
const Allocator = std.mem.Allocator;

/// Neovim-compatible UI protocol for screen updates
/// All updates are sent as notifications: [2, "redraw", [events]]
/// UI Event types matching Neovim's protocol
pub const UIEvent = union(enum) {
    grid_resize: GridResize,
    grid_line: GridLine,
    grid_cursor_goto: GridCursorGoto,
    grid_scroll: GridScroll,
    grid_clear: GridClear,
    grid_destroy: GridDestroy,
    hl_attr_define: HlAttrDefine,
    default_colors_set: DefaultColorsSet,
    flush: void,

    /// ["grid_resize", grid, width, height]
    pub const GridResize = struct {
        grid: u32,
        width: u32,
        height: u32,
    };

    /// ["grid_line", grid, row, col_start, cells, wrap]
    /// where cells is an array of [text, hl_id, repeat]
    pub const GridLine = struct {
        grid: u32,
        row: u32,
        col_start: u32,
        cells: []Cell,
        wrap: bool,

        pub const Cell = struct {
            text: []const u8,
            hl_id: ?u32 = null, // omitted = reuse previous
            repeat: ?u32 = null, // omitted = 1
        };
    };

    /// ["grid_cursor_goto", grid, row, col]
    pub const GridCursorGoto = struct {
        grid: u32,
        row: u32,
        col: u32,
    };

    /// ["grid_scroll", grid, top, bot, left, right, rows, cols]
    pub const GridScroll = struct {
        grid: u32,
        top: u32,
        bot: u32,
        left: u32,
        right: u32,
        rows: i32, // + = up, - = down
        cols: i32, // always 0 for now
    };

    /// ["grid_clear", grid]
    pub const GridClear = struct {
        grid: u32,
    };

    /// ["grid_destroy", grid]
    pub const GridDestroy = struct {
        grid: u32,
    };

    /// ["hl_attr_define", id, rgb_attr, cterm_attr, info]
    pub const HlAttrDefine = struct {
        id: u32,
        rgb_attr: HlAttrs,
        cterm_attr: HlAttrs,
        info: []const u8, // empty array unless ext_hlstate enabled

        pub const HlAttrs = struct {
            foreground: ?u32 = null,
            background: ?u32 = null,
            special: ?u32 = null,
            reverse: bool = false,
            italic: bool = false,
            bold: bool = false,
            strikethrough: bool = false,
            underline: bool = false,
            undercurl: bool = false,
            underdouble: bool = false,
            underdotted: bool = false,
            underdashed: bool = false,
            blend: ?u8 = null, // 0-100
            url: ?[]const u8 = null,
        };
    };

    /// ["default_colors_set", rgb_fg, rgb_bg, rgb_sp, cterm_fg, cterm_bg]
    pub const DefaultColorsSet = struct {
        rgb_fg: u32,
        rgb_bg: u32,
        rgb_sp: u32,
        cterm_fg: u32,
        cterm_bg: u32,
    };
};

/// Builder for constructing redraw notifications
pub const RedrawBuilder = struct {
    allocator: Allocator,
    events: std.ArrayList(msgpack.Value),

    pub fn init(allocator: Allocator) RedrawBuilder {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(msgpack.Value).empty,
        };
    }

    pub fn deinit(self: *RedrawBuilder) void {
        for (self.events.items) |event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }

    /// Add a grid_resize event
    pub fn gridResize(self: *RedrawBuilder, grid: u32, width: u32, height: u32) !void {
        // Event format: ["grid_resize", [grid, width, height]]
        const event_name = msgpack.Value{ .string = try self.allocator.dupe(u8, "grid_resize") };

        const args = try self.allocator.alloc(msgpack.Value, 3);
        args[0] = msgpack.Value{ .unsigned = grid };
        args[1] = msgpack.Value{ .unsigned = width };
        args[2] = msgpack.Value{ .unsigned = height };

        const args_array = msgpack.Value{ .array = args };

        // Event is [event_name, args]
        const event_arr = try self.allocator.alloc(msgpack.Value, 2);
        event_arr[0] = event_name;
        event_arr[1] = args_array;

        try self.events.append(self.allocator, msgpack.Value{ .array = event_arr });
    }

    /// Add a grid_line event
    pub fn gridLine(
        self: *RedrawBuilder,
        grid: u32,
        row: u32,
        col_start: u32,
        cells: []const UIEvent.GridLine.Cell,
        wrap: bool,
    ) !void {
        // Event format: ["grid_line", [grid, row, col_start, cells, wrap]]
        const event_name = msgpack.Value{ .string = try self.allocator.dupe(u8, "grid_line") };

        // Build cells array
        const cells_arr = try self.allocator.alloc(msgpack.Value, cells.len);
        for (cells, 0..) |cell, i| {
            var cell_items = std.ArrayList(msgpack.Value).empty;
            defer cell_items.deinit(self.allocator);

            // Always include text
            try cell_items.append(self.allocator, msgpack.Value{ .string = try self.allocator.dupe(u8, cell.text) });

            // Include hl_id if present
            if (cell.hl_id) |hl| {
                try cell_items.append(self.allocator, msgpack.Value{ .unsigned = hl });
            }

            // Include repeat if present and hl_id was included
            if (cell.repeat) |rep| {
                if (cell.hl_id == null) {
                    // If no hl_id, we need to include nil placeholder
                    try cell_items.insert(self.allocator, 1, msgpack.Value.nil);
                }
                try cell_items.append(self.allocator, msgpack.Value{ .unsigned = rep });
            }

            cells_arr[i] = msgpack.Value{ .array = try cell_items.toOwnedSlice(self.allocator) };
        }

        const args = try self.allocator.alloc(msgpack.Value, 5);
        args[0] = msgpack.Value{ .unsigned = grid };
        args[1] = msgpack.Value{ .unsigned = row };
        args[2] = msgpack.Value{ .unsigned = col_start };
        args[3] = msgpack.Value{ .array = cells_arr };
        args[4] = msgpack.Value{ .boolean = wrap };

        const args_array = msgpack.Value{ .array = args };

        const event_arr = try self.allocator.alloc(msgpack.Value, 2);
        event_arr[0] = event_name;
        event_arr[1] = args_array;

        try self.events.append(self.allocator, msgpack.Value{ .array = event_arr });
    }

    /// Add a grid_cursor_goto event
    pub fn gridCursorGoto(self: *RedrawBuilder, grid: u32, row: u32, col: u32) !void {
        const event_name = msgpack.Value{ .string = try self.allocator.dupe(u8, "grid_cursor_goto") };

        const args = try self.allocator.alloc(msgpack.Value, 3);
        args[0] = msgpack.Value{ .unsigned = grid };
        args[1] = msgpack.Value{ .unsigned = row };
        args[2] = msgpack.Value{ .unsigned = col };

        const args_array = msgpack.Value{ .array = args };

        const event_arr = try self.allocator.alloc(msgpack.Value, 2);
        event_arr[0] = event_name;
        event_arr[1] = args_array;

        try self.events.append(self.allocator, msgpack.Value{ .array = event_arr });
    }

    /// Add a grid_clear event
    pub fn gridClear(self: *RedrawBuilder, grid: u32) !void {
        const event_name = msgpack.Value{ .string = try self.allocator.dupe(u8, "grid_clear") };

        const args = try self.allocator.alloc(msgpack.Value, 1);
        args[0] = msgpack.Value{ .unsigned = grid };

        const args_array = msgpack.Value{ .array = args };

        const event_arr = try self.allocator.alloc(msgpack.Value, 2);
        event_arr[0] = event_name;
        event_arr[1] = args_array;

        try self.events.append(self.allocator, msgpack.Value{ .array = event_arr });
    }

    /// Add a flush event
    pub fn flush(self: *RedrawBuilder) !void {
        const event_name = msgpack.Value{ .string = try self.allocator.dupe(u8, "flush") };

        // Flush has empty args
        const args = try self.allocator.alloc(msgpack.Value, 0);
        const args_array = msgpack.Value{ .array = args };

        const event_arr = try self.allocator.alloc(msgpack.Value, 2);
        event_arr[0] = event_name;
        event_arr[1] = args_array;

        try self.events.append(self.allocator, msgpack.Value{ .array = event_arr });
    }

    /// Add a hl_attr_define event
    pub fn hlAttrDefine(
        self: *RedrawBuilder,
        id: u32,
        rgb_attr: UIEvent.HlAttrDefine.HlAttrs,
        cterm_attr: UIEvent.HlAttrDefine.HlAttrs,
    ) !void {
        const event_name = msgpack.Value{ .string = try self.allocator.dupe(u8, "hl_attr_define") };

        // Build rgb_attr map
        const rgb_map = try buildHlAttrsMap(self.allocator, rgb_attr);

        // Build cterm_attr map
        const cterm_map = try buildHlAttrsMap(self.allocator, cterm_attr);

        // Build empty info array
        const info_arr = try self.allocator.alloc(msgpack.Value, 0);

        const args = try self.allocator.alloc(msgpack.Value, 4);
        args[0] = msgpack.Value{ .unsigned = id };
        args[1] = msgpack.Value{ .map = rgb_map };
        args[2] = msgpack.Value{ .map = cterm_map };
        args[3] = msgpack.Value{ .array = info_arr };

        const args_array = msgpack.Value{ .array = args };

        const event_arr = try self.allocator.alloc(msgpack.Value, 2);
        event_arr[0] = event_name;
        event_arr[1] = args_array;

        try self.events.append(self.allocator, msgpack.Value{ .array = event_arr });
    }

    /// Build the final notification message: [2, "redraw", [events]]
    pub fn build(self: *RedrawBuilder) ![]u8 {
        // Build the notification array
        const notification = try self.allocator.alloc(msgpack.Value, 3);
        notification[0] = msgpack.Value{ .unsigned = 2 }; // type = notification
        notification[1] = msgpack.Value{ .string = try self.allocator.dupe(u8, "redraw") };
        notification[2] = msgpack.Value{ .array = try self.events.toOwnedSlice(self.allocator) };

        const value = msgpack.Value{ .array = notification };
        defer value.deinit(self.allocator);

        return try msgpack.encodeFromValue(self.allocator, value);
    }
};

/// Helper function to build HlAttrs map
fn buildHlAttrsMap(allocator: Allocator, attrs: UIEvent.HlAttrDefine.HlAttrs) ![]msgpack.Value.KeyValue {
    var items = std.ArrayList(msgpack.Value.KeyValue).empty;
    defer items.deinit(allocator);

    if (attrs.foreground) |fg| {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "foreground") },
            .value = msgpack.Value{ .unsigned = fg },
        });
    }

    if (attrs.background) |bg| {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "background") },
            .value = msgpack.Value{ .unsigned = bg },
        });
    }

    if (attrs.special) |sp| {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "special") },
            .value = msgpack.Value{ .unsigned = sp },
        });
    }

    if (attrs.reverse) {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "reverse") },
            .value = msgpack.Value{ .boolean = true },
        });
    }

    if (attrs.italic) {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "italic") },
            .value = msgpack.Value{ .boolean = true },
        });
    }

    if (attrs.bold) {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "bold") },
            .value = msgpack.Value{ .boolean = true },
        });
    }

    if (attrs.blend) |blend| {
        try items.append(allocator, .{
            .key = msgpack.Value{ .string = try allocator.dupe(u8, "blend") },
            .value = msgpack.Value{ .unsigned = blend },
        });
    }

    return try items.toOwnedSlice(allocator);
}

const testing = std.testing;

test "build grid_resize event" {
    var builder = RedrawBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.gridResize(1, 80, 24);
    try builder.flush();

    const msg = try builder.build();
    defer testing.allocator.free(msg);

    // Decode and verify
    const value = try msgpack.decode(testing.allocator, msg);
    defer value.deinit(testing.allocator);

    try testing.expect(value == .array);
    try testing.expectEqual(@as(usize, 3), value.array.len);
    try testing.expectEqual(@as(u64, 2), value.array[0].unsigned); // type = notification
    try testing.expectEqualStrings("redraw", value.array[1].string);
}

test "build grid_line event" {
    var builder = RedrawBuilder.init(testing.allocator);
    defer builder.deinit();

    const cells = [_]UIEvent.GridLine.Cell{
        .{ .text = "H", .hl_id = 0 },
        .{ .text = "e", .hl_id = 0 },
        .{ .text = "l", .hl_id = 0 },
        .{ .text = "l", .hl_id = 0 },
        .{ .text = "o", .hl_id = 0 },
    };

    try builder.gridLine(1, 0, 0, &cells, false);
    try builder.flush();

    const msg = try builder.build();
    defer testing.allocator.free(msg);

    // Verify it's a valid msgpack message
    const value = try msgpack.decode(testing.allocator, msg);
    defer value.deinit(testing.allocator);

    try testing.expect(value == .array);
    try testing.expectEqual(@as(u64, 2), value.array[0].unsigned);
    try testing.expectEqualStrings("redraw", value.array[1].string);
}

test "build complete redraw notification" {
    var builder = RedrawBuilder.init(testing.allocator);
    defer builder.deinit();

    // Typical redraw sequence
    try builder.gridResize(1, 80, 24);

    const cells = [_]UIEvent.GridLine.Cell{
        .{ .text = "~", .hl_id = 7, .repeat = 80 },
    };
    try builder.gridLine(1, 0, 0, &cells, false);

    try builder.gridCursorGoto(1, 0, 0);
    try builder.flush();

    const msg = try builder.build();
    defer testing.allocator.free(msg);

    // Decode and verify structure
    const value = try msgpack.decode(testing.allocator, msg);
    defer value.deinit(testing.allocator);

    try testing.expect(value == .array);
    try testing.expectEqual(@as(usize, 3), value.array.len);

    // Check notification structure: [2, "redraw", events]
    try testing.expectEqual(@as(u64, 2), value.array[0].unsigned);
    try testing.expectEqualStrings("redraw", value.array[1].string);
    try testing.expect(value.array[2] == .array);

    // Check we have 4 events
    const events = value.array[2].array;
    try testing.expectEqual(@as(usize, 4), events.len);
}
