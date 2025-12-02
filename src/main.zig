//! Entry point for the prise terminal multiplexer client.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io = @import("io.zig");
const msgpack = @import("msgpack.zig");
const rpc = @import("rpc.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const posix = std.posix;

pub const version = build_options.version;

const log = std.log.scoped(.main);

var log_file: ?std.fs.File = null;

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
    .log_scope_levels = &.{
        .{ .scope = .page_list, .level = .warn },
    },
};

var log_buffer: [4096]u8 = undefined;

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const file = log_file orelse return;
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    const msg = std.fmt.bufPrint(&log_buffer, prefix ++ format ++ "\n", args) catch return;
    _ = file.write(msg) catch {};
}

const MAX_LOG_SIZE = 64 * 1024 * 1024; // 64 MiB

fn initLogFile(filename: []const u8) void {
    const home = posix.getenv("HOME") orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrint(&path_buf, "{s}/.cache/prise", .{home}) catch return;

    std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ log_dir, filename }) catch return;

    if (std.fs.openFileAbsolute(log_path, .{ .mode = .read_write })) |file| {
        const stat = file.stat() catch {
            file.close();
            return;
        };
        if (stat.size > MAX_LOG_SIZE) {
            file.setEndPos(0) catch {};
            file.seekTo(0) catch {};
        } else {
            file.seekFromEnd(0) catch {};
        }
        log_file = file;
    } else |_| {
        log_file = std.fs.createFileAbsolute(log_path, .{}) catch return;
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const uid = posix.getuid();
    var socket_buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/tmp/prise-{d}.sock", .{uid});

    const attach_session = try parseArgs(allocator, socket_path) orelse return;
    try runClient(allocator, socket_path, attach_session);
}

fn parseArgs(allocator: std.mem.Allocator, socket_path: []const u8) !?(?[]const u8) {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cmd = args.next() orelse return @as(?[]const u8, null);

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        var buf: [128]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&buf);
        stdout.interface.print("prise {s}\n", .{version}) catch {};
        stdout.interface.flush() catch {};
        return null;
    } else if (std.mem.eql(u8, cmd, "serve")) {
        initLogFile("server.log");
        try server.startServer(allocator, socket_path);
        return null;
    } else if (std.mem.eql(u8, cmd, "session")) {
        return try handleSessionCommand(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "pty")) {
        return try handlePtyCommand(allocator, &args, socket_path);
    } else {
        log.err("Unknown command: {s}", .{cmd});
        log.err("Available commands: serve, session, pty", .{});
        return error.UnknownCommand;
    }
}

fn handleSessionCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !?(?[]const u8) {
    const subcmd = args.next() orelse {
        log.err("Missing session command. Available commands: attach, list", .{});
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "attach")) {
        const session = args.next() orelse try findMostRecentSession(allocator);
        return @as(?[]const u8, session);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listSessions(allocator);
        return null;
    } else {
        log.err("Unknown session command: {s}", .{subcmd});
        log.err("Available commands: attach, list", .{});
        return error.UnknownCommand;
    }
}

fn handlePtyCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator, socket_path: []const u8) !?(?[]const u8) {
    const subcmd = args.next() orelse {
        log.err("Missing pty command. Available commands: list, kill", .{});
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "list")) {
        try listPtys(allocator, socket_path);
        return null;
    } else {
        log.err("Unknown pty command: {s}", .{subcmd});
        log.err("Available commands: list, kill", .{});
        return error.UnknownCommand;
    }
}

fn runClient(allocator: std.mem.Allocator, socket_path: []const u8, attach_session: ?[]const u8) !void {
    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.err("Server not running. Start it with: prise serve", .{});
            return error.ServerNotRunning;
        }
        return err;
    };

    initLogFile("client.log");
    log.info("Connecting to server at {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var app = try client.App.init(allocator);
    defer app.deinit();

    app.socket_path = socket_path;
    app.attach_session = attach_session;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    app.initial_cwd = posix.getcwd(&cwd_buf) catch null;

    try app.setup(&loop);
    try loop.run(.until_done);

    if (app.state.connection_refused) {
        log.err("Connection refused. Server may have crashed. Start it with: prise serve", .{});
        posix.unlink(socket_path) catch {};
        return error.ConnectionRefused;
    }
}

fn getSessionsDir(allocator: std.mem.Allocator) !struct { dir: std.fs.Dir, path: []const u8 } {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const sessions_dir = try std.fs.path.join(allocator, &.{ home, ".local", "state", "prise", "sessions" });

    const dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| {
        allocator.free(sessions_dir);
        if (err == error.FileNotFound) {
            return error.NoSessionsFound;
        }
        return err;
    };

    return .{ .dir = dir, .path = sessions_dir };
}

fn listSessions(allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("No sessions found.\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 5];
        try stdout.interface.print("{s}\n", .{name_without_ext});
        count += 1;
    }

    if (count == 0) {
        try stdout.interface.print("No sessions found.\n", .{});
    }
}

fn listPtys(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        log.err("Failed to create socket: {}", .{err});
        return error.SocketError;
    };
    defer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            try stdout.interface.print("Server not running.\n", .{});
            return;
        }
        return err;
    };

    const request = try msgpack.encode(allocator, .{ 0, 1, "list_ptys", .{} });
    defer allocator.free(request);

    _ = try posix.write(sock, request);

    var response_buf: [16384]u8 = undefined;
    const n = try posix.read(sock, &response_buf);
    if (n == 0) {
        try stdout.interface.print("No response from server.\n", .{});
        return;
    }

    const msg = rpc.decodeMessage(allocator, response_buf[0..n]) catch |err| {
        log.err("Failed to decode response: {}", .{err});
        return error.DecodeError;
    };
    defer msg.deinit(allocator);

    if (msg != .response) {
        try stdout.interface.print("Unexpected response type.\n", .{});
        return;
    }

    if (msg.response.err) |err_val| {
        const err_str = if (err_val == .string) err_val.string else "unknown error";
        try stdout.interface.print("Server error: {s}\n", .{err_str});
        return;
    }

    const result = msg.response.result;
    if (result != .map) {
        try stdout.interface.print("Invalid response format.\n", .{});
        return;
    }

    var ptys: ?[]const msgpack.Value = null;
    for (result.map) |kv| {
        if (kv.key == .string and std.mem.eql(u8, kv.key.string, "ptys")) {
            if (kv.value == .array) {
                ptys = kv.value.array;
            }
        }
    }

    if (ptys == null or ptys.?.len == 0) {
        try stdout.interface.print("No PTYs running.\n", .{});
        return;
    }

    for (ptys.?) |pty_val| {
        if (pty_val != .map) continue;

        var id: ?u64 = null;
        var cwd: []const u8 = "";
        var title: []const u8 = "";
        var clients: u64 = 0;

        for (pty_val.map) |kv| {
            if (kv.key != .string) continue;
            const key = kv.key.string;

            if (std.mem.eql(u8, key, "id")) {
                id = if (kv.value == .unsigned) kv.value.unsigned else null;
            } else if (std.mem.eql(u8, key, "cwd")) {
                cwd = if (kv.value == .string) kv.value.string else "";
            } else if (std.mem.eql(u8, key, "title")) {
                title = if (kv.value == .string) kv.value.string else "";
            } else if (std.mem.eql(u8, key, "attached_client_count")) {
                clients = if (kv.value == .unsigned) kv.value.unsigned else 0;
            }
        }

        if (id) |pty_id| {
            const title_display = if (title.len > 0) title else "(no title)";
            try stdout.interface.print("{d}: {s} [{s}] ({d} clients)\n", .{ pty_id, cwd, title_display, clients });
        }
    }
}

fn findMostRecentSession(allocator: std.mem.Allocator) ![]const u8 {
    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            log.err("No sessions directory found", .{});
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var most_recent: ?[]const u8 = null;
    var most_recent_time: i128 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (mtime > most_recent_time) {
            if (most_recent) |old| {
                allocator.free(old);
            }
            most_recent_time = mtime;
            const name_without_ext = entry.name[0 .. entry.name.len - 5];
            most_recent = try allocator.dupe(u8, name_without_ext);
        }
    }

    if (most_recent) |name| {
        log.info("Attaching to most recent session: {s}", .{name});
        return name;
    }

    log.err("No session files found", .{});
    return error.NoSessionsFound;
}

test {
    _ = @import("io/mock.zig");
    _ = @import("server.zig");
    _ = @import("msgpack.zig");
    _ = @import("rpc.zig");
    _ = @import("pty.zig");
    _ = @import("client.zig");
    _ = @import("redraw.zig");
    _ = @import("Surface.zig");
    _ = @import("widget.zig");
    _ = @import("TextInput.zig");
    _ = @import("key_encode.zig");
    _ = @import("mouse_encode.zig");
    _ = @import("vaxis_helper.zig");

    if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) {
        _ = @import("io/kqueue.zig");
    } else if (builtin.os.tag == .linux) {
        _ = @import("io/io_uring.zig");
    }
}
