// Wrapper for ghostty's key encoding since it's not publicly exported
const ghostty = @import("ghostty-vt");

pub fn encode(
    writer: anytype,
    key: ghostty.input.KeyEvent,
    terminal: *const ghostty.Terminal,
) !void {
    const opts = .{
        .alt_esc_prefix = terminal.modes.get(.alt_esc_prefix),
        .cursor_key_application = terminal.modes.get(.cursor_keys),
        .keypad_key_application = terminal.modes.get(.keypad_keys),
        .ignore_keypad_with_numlock = terminal.modes.get(.ignore_keypad_with_numlock),
        .modify_other_keys_state_2 = terminal.flags.modify_other_keys_2,
        .kitty_flags = terminal.screens.active.kitty_keyboard.current(),
        .macos_option_as_alt = .false,
    };

    // Use default encoding (not kitty)
    try legacyEncode(writer, key, opts);
}

// Simplified legacy encoding - just handle basics
fn legacyEncode(
    writer: anytype,
    key: ghostty.input.KeyEvent,
    opts: anytype,
) !void {
    _ = opts;

    // If we have UTF-8, write it
    if (key.utf8.len > 0 and !key.mods.ctrl) {
        try writer.writeAll(key.utf8);
        return;
    }

    // Handle special keys and control sequences
    switch (key.key) {
        .enter => try writer.writeAll("\r"),
        .tab => try writer.writeAll("\t"),
        .backspace => try writer.writeAll("\x7F"),
        .escape => try writer.writeAll("\x1B"),
        .space => {
            if (key.mods.ctrl) {
                try writer.writeAll("\x00");
            } else {
                try writer.writeAll(" ");
            }
        },
        .arrow_up => try writer.writeAll("\x1B[A"),
        .arrow_down => try writer.writeAll("\x1B[B"),
        .arrow_right => try writer.writeAll("\x1B[C"),
        .arrow_left => try writer.writeAll("\x1B[D"),
        .delete => try writer.writeAll("\x1B[3~"),
        .insert => try writer.writeAll("\x1B[2~"),
        .home => try writer.writeAll("\x1B[H"),
        .end => try writer.writeAll("\x1B[F"),
        .page_up => try writer.writeAll("\x1B[5~"),
        .page_down => try writer.writeAll("\x1B[6~"),
        .f1 => try writer.writeAll("\x1BOP"),
        .f2 => try writer.writeAll("\x1BOQ"),
        .f3 => try writer.writeAll("\x1BOR"),
        .f4 => try writer.writeAll("\x1BOS"),
        .f5 => try writer.writeAll("\x1B[15~"),
        .f6 => try writer.writeAll("\x1B[17~"),
        .f7 => try writer.writeAll("\x1B[18~"),
        .f8 => try writer.writeAll("\x1B[19~"),
        .f9 => try writer.writeAll("\x1B[20~"),
        .f10 => try writer.writeAll("\x1B[21~"),
        .f11 => try writer.writeAll("\x1B[23~"),
        .f12 => try writer.writeAll("\x1B[24~"),
        .unidentified => {
            // Handle control sequences for unidentified keys with UTF-8
            if (key.utf8.len > 0) {
                if (key.mods.ctrl and key.utf8.len == 1 and key.utf8[0] >= 'a' and key.utf8[0] <= 'z') {
                    // Ctrl+letter -> control code
                    const ctrl_code: u8 = key.utf8[0] - 'a' + 1;
                    try writer.writeByte(ctrl_code);
                } else if (key.mods.ctrl and key.utf8.len == 1 and key.utf8[0] >= 'A' and key.utf8[0] <= 'Z') {
                    // Ctrl+capital letter -> control code
                    const ctrl_code: u8 = key.utf8[0] - 'A' + 1;
                    try writer.writeByte(ctrl_code);
                } else {
                    try writer.writeAll(key.utf8);
                }
            }
        },
        else => {},
    }
}
