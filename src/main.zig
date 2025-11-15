const std = @import("std");

pub fn main() !void {
    const uid = std.posix.getuid();

    var buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&buffer, "/tmp/prise-{d}.sock", .{uid});

    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Starting server (socket not found)\n", .{});
            return;
        }
        return err;
    };

    std.debug.print("Connecting to server (socket exists)\n", .{});
}
