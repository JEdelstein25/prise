const std = @import("std");
const vaxis = @import("vaxis");

/// Convert a vaxis Key to Neovim key notation
/// Returns a buffer containing the key notation (e.g., "<C-a>", "x", "<CR>")
pub fn fromVaxisKey(key: vaxis.Key, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    // Special keys
    if (key.codepoint == vaxis.Key.escape) {
        try writer.writeAll("<Esc>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.enter) {
        try writer.writeAll("<CR>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.tab) {
        if (key.mods.shift) {
            try writer.writeAll("<S-Tab>");
        } else {
            try writer.writeAll("<Tab>");
        }
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.backspace) {
        try writer.writeAll("<BS>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.delete) {
        try writer.writeAll("<Del>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.insert) {
        try writer.writeAll("<Insert>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.home) {
        try writer.writeAll("<Home>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.end) {
        try writer.writeAll("<End>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.page_up) {
        try writer.writeAll("<PageUp>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.page_down) {
        try writer.writeAll("<PageDown>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.up) {
        try writer.writeAll("<Up>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.down) {
        try writer.writeAll("<Down>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.left) {
        try writer.writeAll("<Left>");
        return stream.getWritten();
    } else if (key.codepoint == vaxis.Key.right) {
        try writer.writeAll("<Right>");
        return stream.getWritten();
    } else if (key.codepoint >= vaxis.Key.f1 and key.codepoint <= vaxis.Key.f12) {
        const fn_num = key.codepoint - vaxis.Key.f1 + 1;
        try writer.print("<F{}>", .{fn_num});
        return stream.getWritten();
    }

    // Regular characters with modifiers
    const has_ctrl = key.mods.ctrl;
    const has_alt = key.mods.alt;
    const has_shift = key.mods.shift;

    // For printable ASCII with modifiers
    if (key.codepoint < 128) {
        const needs_brackets = has_ctrl or has_alt or (has_shift and key.codepoint >= 'a' and key.codepoint <= 'z');

        if (needs_brackets) {
            try writer.writeAll("<");
            if (has_ctrl) try writer.writeAll("C-");
            if (has_alt) try writer.writeAll("A-");
            if (has_shift and key.codepoint >= 'a' and key.codepoint <= 'z') {
                try writer.writeAll("S-");
            }

            // Write the character
            if (key.codepoint == ' ') {
                try writer.writeAll("Space");
            } else if (key.codepoint == '<') {
                try writer.writeAll("lt");
            } else if (key.codepoint == '>') {
                try writer.writeAll("gt");
            } else {
                try writer.writeByte(@intCast(key.codepoint));
            }

            try writer.writeAll(">");
        } else {
            // Plain character
            try writer.writeByte(@intCast(key.codepoint));
        }
        return stream.getWritten();
    }

    // UTF-8 characters
    var utf8_buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(key.codepoint, &utf8_buf);
    try writer.writeAll(utf8_buf[0..len]);
    return stream.getWritten();
}
