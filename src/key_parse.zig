const std = @import("std");
const ghostty = @import("ghostty-vt");

const KeyEvent = ghostty.input.KeyEvent;
const Key = ghostty.input.Key;

// Mods isn't publicly exposed, but we need it
const Mods = packed struct(u16) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    sides: u4 = 0,
    _padding: u6 = 0,
};

// Static buffers for special characters
const lt_char = "<";
const gt_char = ">";

/// Parse Neovim key notation to ghostty KeyEvent
/// Examples: "<C-a>", "x", "<CR>", "<S-Tab>"
pub fn parseKeyNotation(notation: []const u8) !KeyEvent {
    if (notation.len == 0) return error.EmptyKey;

    // Simple single character - notation is already valid UTF-8
    if (notation.len == 1) {
        return .{
            .key = .unidentified,
            .utf8 = notation, // Use the input string directly
            .mods = .{},
        };
    }

    // Check for angle bracket notation
    if (notation[0] == '<' and notation[notation.len - 1] == '>') {
        const inner = notation[1 .. notation.len - 1];
        return parseAngleBracketKey(inner);
    }

    // Multi-byte UTF-8 character
    return .{
        .key = .unidentified,
        .utf8 = notation,
        .mods = .{},
    };
}

fn parseAngleBracketKey(inner: []const u8) !KeyEvent {
    var mods: Mods = .{};
    var key_str = inner;

    // Parse modifiers
    while (true) {
        if (std.mem.startsWith(u8, key_str, "C-")) {
            mods.ctrl = true;
            key_str = key_str[2..];
        } else if (std.mem.startsWith(u8, key_str, "A-") or std.mem.startsWith(u8, key_str, "M-")) {
            mods.alt = true;
            key_str = key_str[2..];
        } else if (std.mem.startsWith(u8, key_str, "S-")) {
            mods.shift = true;
            key_str = key_str[2..];
        } else {
            break;
        }
    }

    const m = @as(u16, @bitCast(mods));

    // Parse the key itself
    if (std.mem.eql(u8, key_str, "CR") or std.mem.eql(u8, key_str, "Return") or std.mem.eql(u8, key_str, "Enter")) {
        return .{ .key = .enter, .mods = @bitCast(mods) };
    } else if (std.mem.eql(u8, key_str, "Tab")) {
        return .{ .key = .tab, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "BS") or std.mem.eql(u8, key_str, "Backspace")) {
        return .{ .key = .backspace, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Esc") or std.mem.eql(u8, key_str, "Escape")) {
        return .{ .key = .escape, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Space")) {
        return .{ .key = .space, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "lt")) {
        return .{ .key = .unidentified, .utf8 = lt_char, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "gt")) {
        return .{ .key = .unidentified, .utf8 = gt_char, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Del") or std.mem.eql(u8, key_str, "Delete")) {
        return .{ .key = .delete, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Insert")) {
        return .{ .key = .insert, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Home")) {
        return .{ .key = .home, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "End")) {
        return .{ .key = .end, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "PageUp")) {
        return .{ .key = .page_up, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "PageDown")) {
        return .{ .key = .page_down, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Up")) {
        return .{ .key = .arrow_up, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Down")) {
        return .{ .key = .arrow_down, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Left")) {
        return .{ .key = .arrow_left, .mods = @bitCast(m) };
    } else if (std.mem.eql(u8, key_str, "Right")) {
        return .{ .key = .arrow_right, .mods = @bitCast(m) };
    } else if (key_str.len >= 2 and key_str[0] == 'F') {
        // Function keys F1-F12
        const num = std.fmt.parseInt(u8, key_str[1..], 10) catch return error.InvalidKey;
        if (num >= 1 and num <= 12) {
            const key_enum: Key = switch (num) {
                1 => .f1,
                2 => .f2,
                3 => .f3,
                4 => .f4,
                5 => .f5,
                6 => .f6,
                7 => .f7,
                8 => .f8,
                9 => .f9,
                10 => .f10,
                11 => .f11,
                12 => .f12,
                else => unreachable,
            };
            return .{ .key = key_enum, .mods = @bitCast(m) };
        }
    } else if (key_str.len == 1) {
        // Single character with modifiers - key_str points to the original notation
        return .{ .key = .unidentified, .utf8 = key_str, .mods = @bitCast(m) };
    }

    return error.InvalidKey;
}
