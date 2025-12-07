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
    defer if (attach_session) |s| allocator.free(s);
    try runClient(allocator, socket_path, attach_session);
}

fn parseArgs(allocator: std.mem.Allocator, socket_path: []const u8) !?(?[]const u8) {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cmd = args.next() orelse return @as(?[]const u8, null);

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try printVersion();
        return null;
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp();
        return null;
    } else if (std.mem.eql(u8, cmd, "serve")) {
        initLogFile("server.log");
        try server.startServer(allocator, socket_path);
        return null;
    } else if (std.mem.eql(u8, cmd, "session")) {
        return try handleSessionCommand(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "pty")) {
        return try handlePtyCommand(allocator, &args, socket_path);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try showStatus(allocator, socket_path);
        return null;
    } else if (std.mem.eql(u8, cmd, "show")) {
        const name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing session name. Usage: prise show <name>\n\nAvailable sessions:\n") catch {};
            try listSessionsTo(allocator, std.fs.File.stderr());
            return error.MissingArgument;
        };
        try showSessionVisual(allocator, name);
        return null;
    } else {
        log.err("Unknown command: {s}", .{cmd});
        try printHelp();
        return error.UnknownCommand;
    }
}

fn printVersion() !void {
    var buf: [128]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("prise {s}\n", .{version});
}

fn printHelp() !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print(
        \\prise - Terminal multiplexer
        \\
        \\Usage: prise [command] [options]
        \\
        \\Commands:
        \\  (none)     Start client, connect to server (spawns server if needed)
        \\  serve      Start the server in the foreground
        \\  status     Show server status and running PTYs
        \\  show       Show ASCII layout of a session
        \\  session    Manage sessions (attach, list, rename, delete)
        \\  pty        Manage PTYs (list, kill)
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -v, --version  Show version
        \\
        \\Run 'prise <command> --help' for more information on a command.
        \\
    , .{});
}

fn printSessionHelp() !void {
    try printSessionHelpTo(std.fs.File.stdout());
}

fn printSessionHelpTo(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        \\prise session - Manage sessions
        \\
        \\Usage: prise session <command> [args]
        \\
        \\Commands:
        \\  attach [name]            Attach to a session (most recent if no name given)
        \\  list                     List all sessions
        \\  rename <old> <new>       Rename a session
        \\  delete <name>            Delete a session
        \\
        \\Options:
        \\  -h, --help               Show this help message
        \\
    , .{});
}

fn handleSessionCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !?(?[]const u8) {
    const subcmd = args.next() orelse {
        try printSessionHelp();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printSessionHelp();
        return null;
    } else if (std.mem.eql(u8, subcmd, "attach")) {
        const session = args.next() orelse try findMostRecentSession(allocator);
        return @as(?[]const u8, session);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listSessions(allocator);
        return null;
    } else if (std.mem.eql(u8, subcmd, "rename")) {
        const old_name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing session name. Usage: prise session rename <old-name> <new-name>\n\nAvailable sessions:\n") catch {};
            try listSessionsTo(allocator, std.fs.File.stderr());
            return error.MissingArgument;
        };
        const new_name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing new session name. Usage: prise session rename <old-name> <new-name>\n") catch {};
            return error.MissingArgument;
        };
        try renameSession(allocator, old_name, new_name);
        return null;
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        const name = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing session name. Usage: prise session delete <name>\n\nAvailable sessions:\n") catch {};
            try listSessionsTo(allocator, std.fs.File.stderr());
            return error.MissingArgument;
        };
        try deleteSession(allocator, name);
        return null;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown session command: {s}\n\n", .{subcmd}) catch return error.UnknownCommand;
        std.fs.File.stderr().writeAll(msg) catch {};
        try printSessionHelpTo(std.fs.File.stderr());
        return error.UnknownCommand;
    }
}

fn printPtyHelp() !void {
    try printPtyHelpTo(std.fs.File.stdout());
}

fn printPtyHelpTo(file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        \\prise pty - Manage PTYs
        \\
        \\Usage: prise pty <command> [args]
        \\
        \\Commands:
        \\  list                     List all PTYs
        \\  spawn [options]          Spawn a new PTY or create a split
        \\  kill <id>                Kill a PTY by ID
        \\  send <id> <text>         Send text input to a PTY
        \\
        \\Spawn options:
        \\  --cwd <dir>              Working directory (orphaned PTY only)
        \\  -v, --vertical           Create vertical split in active session
        \\  -h, --horizontal         Create horizontal split in active session
        \\
        \\General options:
        \\  --help                   Show this help message
        \\
    , .{});
}

fn handlePtyCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator, socket_path: []const u8) !?(?[]const u8) {
    const subcmd = args.next() orelse {
        try printPtyHelp();
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printPtyHelp();
        return null;
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listPtys(allocator, socket_path);
        return null;
    } else if (std.mem.eql(u8, subcmd, "spawn")) {
        var cwd: ?[]const u8 = null;
        var direction: []const u8 = "row"; // default: vertical split (side by side)
        var use_split: bool = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--cwd")) {
                cwd = args.next() orelse {
                    std.fs.File.stderr().writeAll("Missing directory for --cwd\n") catch {};
                    return error.MissingArgument;
                };
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--horizontal")) {
                direction = "col";
                use_split = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--vertical")) {
                direction = "row";
                use_split = true;
            }
        }
        if (use_split) {
            try splitPane(allocator, socket_path, direction);
        } else {
            try spawnPty(allocator, socket_path, cwd);
        }
        return null;
    } else if (std.mem.eql(u8, subcmd, "kill")) {
        const id_str = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing PTY ID. Usage: prise pty kill <id>\n\nUse 'prise pty list' to see available PTYs.\n") catch {};
            return error.MissingArgument;
        };
        const pty_id = std.fmt.parseInt(u32, id_str, 10) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Invalid PTY ID: {s}\n", .{id_str}) catch return error.InvalidArgument;
            std.fs.File.stderr().writeAll(msg) catch {};
            return error.InvalidArgument;
        };
        try killPty(allocator, socket_path, pty_id);
        return null;
    } else if (std.mem.eql(u8, subcmd, "send")) {
        const id_str = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing PTY ID. Usage: prise pty send <id> <text>\n") catch {};
            return error.MissingArgument;
        };
        const pty_id = std.fmt.parseInt(u32, id_str, 10) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Invalid PTY ID: {s}\n", .{id_str}) catch return error.InvalidArgument;
            std.fs.File.stderr().writeAll(msg) catch {};
            return error.InvalidArgument;
        };
        const text = args.next() orelse {
            std.fs.File.stderr().writeAll("Missing text. Usage: prise pty send <id> <text>\n") catch {};
            return error.MissingArgument;
        };
        try sendPtyInput(allocator, socket_path, pty_id, text);
        return null;
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown pty command: {s}\n\n", .{subcmd}) catch return error.UnknownCommand;
        std.fs.File.stderr().writeAll(msg) catch {};
        try printPtyHelpTo(std.fs.File.stderr());
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

    var app = client.App.init(allocator) catch |err| {
        var buf: [512]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&buf);
        defer stderr.interface.flush() catch {};
        switch (err) {
            error.InitLuaMustReturnTable => stderr.interface.print("error: init.lua must return a UI table\n  example: return require('prise').default()\n", .{}) catch {},
            error.InitLuaFailed => stderr.interface.print("error: failed to load init.lua (check logs for details)\n", .{}) catch {},
            error.DefaultUIFailed => stderr.interface.print("error: failed to load default UI\n", .{}) catch {},
            else => {},
        }
        return err;
    };
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
    try listSessionsTo(allocator, std.fs.File.stdout());
}

fn listSessionsTo(allocator: std.mem.Allocator, file: std.fs.File) !void {
    var buf: [8192]u8 = undefined;
    var writer = file.writer(&buf);
    defer writer.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try writer.interface.print("No sessions found.\n", .{});
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

        // Read session to get tab/pane counts
        const info = getSessionInfo(allocator, dir, entry.name) catch {
            try writer.interface.print("  {s}\n", .{name_without_ext});
            count += 1;
            continue;
        };

        try writer.interface.print("  {s: <18} {d} tab(s), {d} pane(s)\n", .{ name_without_ext, info.tab_count, info.pane_count });
        count += 1;
    }

    if (count == 0) {
        try writer.interface.print("No sessions found.\n", .{});
    }
}

const SessionInfo = struct {
    tab_count: usize,
    pane_count: usize,
};

fn getSessionInfo(allocator: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !SessionInfo {
    const file = try dir.openFile(filename, .{});
    defer file.close();
    const json = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var tab_count: usize = 0;
    var pane_count: usize = 0;

    if (parsed.value == .object) {
        if (parsed.value.object.get("tabs")) |tabs| {
            if (tabs == .array) {
                tab_count = tabs.array.items.len;
                for (tabs.array.items) |tab| {
                    pane_count += countPanesInNode(tab);
                }
            }
        }
    }
    return .{ .tab_count = tab_count, .pane_count = pane_count };
}

fn countPanesInNode(value: std.json.Value) usize {
    if (value != .object) return 0;
    const obj = value.object;
    if (obj.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "pane")) return 1;
    if (obj.get("root")) |r| return countPanesInNode(r);
    if (obj.get("children")) |ch| if (ch == .array) {
        var n: usize = 0;
        for (ch.array.items) |c| n += countPanesInNode(c);
        return n;
    };
    return 0;
}

fn renameSession(allocator: std.mem.Allocator, old_name: []const u8, new_name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{old_name});
            return error.SessionNotFound;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var old_filename_buf: [256]u8 = undefined;
    const old_filename = std.fmt.bufPrint(&old_filename_buf, "{s}.json", .{old_name}) catch {
        try stdout.interface.print("Session name too long.\n", .{});
        return error.NameTooLong;
    };

    var new_filename_buf: [256]u8 = undefined;
    const new_filename = std.fmt.bufPrint(&new_filename_buf, "{s}.json", .{new_name}) catch {
        try stdout.interface.print("Session name too long.\n", .{});
        return error.NameTooLong;
    };

    dir.access(old_filename, .{}) catch {
        try stdout.interface.print("Session '{s}' not found.\n", .{old_name});
        return error.SessionNotFound;
    };

    dir.access(new_filename, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        dir.rename(old_filename, new_filename) catch |rename_err| {
            try stdout.interface.print("Failed to rename session: {}\n", .{rename_err});
            return rename_err;
        };
        try stdout.interface.print("Renamed session '{s}' to '{s}'.\n", .{ old_name, new_name });
        return;
    };

    try stdout.interface.print("Session '{s}' already exists.\n", .{new_name});
    return error.SessionAlreadyExists;
}

fn deleteSession(allocator: std.mem.Allocator, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{name});
            return error.SessionNotFound;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.json", .{name}) catch {
        try stdout.interface.print("Session name too long.\n", .{});
        return error.NameTooLong;
    };

    dir.deleteFile(filename) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{name});
            return error.SessionNotFound;
        }
        try stdout.interface.print("Failed to delete session: {}\n", .{err});
        return err;
    };

    try stdout.interface.print("Deleted session '{s}'.\n", .{name});
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

fn killPty(allocator: std.mem.Allocator, socket_path: []const u8, pty_id: u32) !void {
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

    const request = try msgpack.encode(allocator, .{ 0, 1, "close_pty", .{pty_id} });
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

    if (msg.response.result == .string) {
        try stdout.interface.print("Error: {s}\n", .{msg.response.result.string});
        return;
    }

    try stdout.interface.print("PTY {d} killed.\n", .{pty_id});
}

fn sendPtyInput(allocator: std.mem.Allocator, socket_path: []const u8, pty_id: u32, text: []const u8) !void {
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

    // Process escape sequences in text (e.g., \n -> newline)
    var processed = std.ArrayList(u8).empty;
    defer processed.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '\\') {
            switch (text[i + 1]) {
                'n' => {
                    try processed.append(allocator, '\n');
                    i += 2;
                },
                'r' => {
                    try processed.append(allocator, '\r');
                    i += 2;
                },
                't' => {
                    try processed.append(allocator, '\t');
                    i += 2;
                },
                '\\' => {
                    try processed.append(allocator, '\\');
                    i += 2;
                },
                else => {
                    try processed.append(allocator, text[i]);
                    i += 1;
                },
            }
        } else {
            try processed.append(allocator, text[i]);
            i += 1;
        }
    }

    // Send as notification: [2, "write_pty", [pty_id, data]]
    const notification = try msgpack.encode(allocator, .{ 2, "write_pty", .{ pty_id, processed.items } });
    defer allocator.free(notification);

    _ = try posix.write(sock, notification);
    try stdout.interface.print("Sent {d} bytes to PTY {d}\n", .{ processed.items.len, pty_id });
}

fn spawnPty(allocator: std.mem.Allocator, socket_path: []const u8, cwd: ?[]const u8) !void {
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

    // Build params map for spawn_pty
    var params_list = std.ArrayList(msgpack.Value.KeyValue).empty;
    defer params_list.deinit(allocator);

    try params_list.append(allocator, .{
        .key = .{ .string = "rows" },
        .value = .{ .unsigned = 24 },
    });
    try params_list.append(allocator, .{
        .key = .{ .string = "cols" },
        .value = .{ .unsigned = 80 },
    });
    try params_list.append(allocator, .{
        .key = .{ .string = "attach" },
        .value = .{ .boolean = false },
    });
    if (cwd) |dir| {
        try params_list.append(allocator, .{
            .key = .{ .string = "cwd" },
            .value = .{ .string = dir },
        });
    }

    const params: msgpack.Value = .{ .map = params_list.items };
    const request = try msgpack.encode(allocator, .{ 0, 1, "spawn_pty", params });
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

    // Response should contain pty_id
    if (msg.response.result == .map) {
        for (msg.response.result.map) |kv| {
            if (kv.key == .string and std.mem.eql(u8, kv.key.string, "pty_id")) {
                if (kv.value == .unsigned) {
                    try stdout.interface.print("Spawned PTY {d}\n", .{kv.value.unsigned});
                    return;
                }
            }
        }
    }

    try stdout.interface.print("PTY spawned.\n", .{});
}

fn splitPane(allocator: std.mem.Allocator, socket_path: []const u8, direction: []const u8) !void {
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

    // Build params map for split_pane
    var params_list = std.ArrayList(msgpack.Value.KeyValue).empty;
    defer params_list.deinit(allocator);

    try params_list.append(allocator, .{
        .key = .{ .string = "direction" },
        .value = .{ .string = direction },
    });

    const params: msgpack.Value = .{ .map = params_list.items };
    const request = try msgpack.encode(allocator, .{ 0, 1, "split_pane", params });
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

    if (msg.response.result == .string) {
        try stdout.interface.print("Error: {s}\n", .{msg.response.result.string});
        return;
    }

    const dir_str = if (std.mem.eql(u8, direction, "col")) "horizontal" else "vertical";
    try stdout.interface.print("Created {s} split.\n", .{dir_str});
}

fn showStatus(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    var buf: [16384]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    try stdout.interface.print("Prise Status\n", .{});
    try stdout.interface.print("═════════════════════════════════════════\n\n", .{});

    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        log.err("Failed to create socket: {}", .{err});
        try stdout.interface.print("Server: ✗ not running\n", .{});
        return;
    };
    defer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            try stdout.interface.print("Server: ✗ not running\n\nSaved Sessions:\n", .{});
            stdout.interface.flush() catch {};
            try listSessionsTo(allocator, std.fs.File.stdout());
            return;
        }
        return err;
    };

    try stdout.interface.print("Server: ✓ running ({s})\n\n", .{socket_path});

    const request = try msgpack.encode(allocator, .{ 0, 1, "list_ptys", .{} });
    defer allocator.free(request);
    _ = try posix.write(sock, request);

    var response_buf: [16384]u8 = undefined;
    const n = try posix.read(sock, &response_buf);
    if (n == 0) return;

    const msg = rpc.decodeMessage(allocator, response_buf[0..n]) catch return;
    defer msg.deinit(allocator);

    if (msg != .response or msg.response.err != null) return;
    if (msg.response.result != .map) return;

    var ptys: ?[]const msgpack.Value = null;
    for (msg.response.result.map) |kv| {
        if (kv.key == .string and std.mem.eql(u8, kv.key.string, "ptys")) {
            if (kv.value == .array) ptys = kv.value.array;
        }
    }

    try stdout.interface.print("Running PTYs:\n", .{});
    if (ptys == null or ptys.?.len == 0) {
        try stdout.interface.print("  (none)\n", .{});
    } else {
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
                const indicator = if (clients > 0) "●" else "○";
                const home = std.posix.getenv("HOME") orelse "";
                if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
                    try stdout.interface.print("  {s} {d}: ~{s} [{s}] ({d} clients)\n", .{ indicator, pty_id, cwd[home.len..], title_display, clients });
                } else {
                    try stdout.interface.print("  {s} {d}: {s} [{s}] ({d} clients)\n", .{ indicator, pty_id, cwd, title_display, clients });
                }
            }
        }
    }

    try stdout.interface.print("\nSaved Sessions:\n", .{});
    stdout.interface.flush() catch {};
    try listSessionsTo(allocator, std.fs.File.stdout());
}

const LayoutBox = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    label: []const u8,
    pty_id: i64,
};

fn showSessionVisual(allocator: std.mem.Allocator, name: []const u8) !void {
    var buf: [32768]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{name});
            return error.SessionNotFound;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.json", .{name}) catch return error.NameTooLong;

    const file = dir.openFile(filename, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.interface.print("Session '{s}' not found.\n", .{name});
            return error.SessionNotFound;
        }
        return err;
    };
    defer file.close();

    const json = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidFormat;

    try stdout.interface.print("Session: {s}\n\n", .{name});

    const obj = parsed.value.object;
    var active_tab_idx: usize = 0;
    if (obj.get("active_tab")) |at| {
        if (at == .integer and at.integer > 0) active_tab_idx = @intCast(at.integer - 1);
    }

    if (obj.get("tabs")) |tabs_val| {
        if (tabs_val == .array) {
            for (tabs_val.array.items, 0..) |tab, i| {
                try renderTabVisual(allocator, &stdout.interface, tab, i, i == active_tab_idx);
            }
        }
    }
}

fn renderTabVisual(allocator: std.mem.Allocator, writer: anytype, tab: std.json.Value, index: usize, is_active: bool) !void {
    if (tab != .object) return;
    const active_marker = if (is_active) " ◀" else "";
    try writer.print("Tab {d}{s}\n", .{ index + 1, active_marker });

    if (tab.object.get("root")) |root_val| {
        var boxes = std.ArrayList(LayoutBox).empty;
        defer {
            for (boxes.items) |b| allocator.free(b.label);
            boxes.deinit(allocator);
        }
        const grid_width: usize = 60;
        const grid_height: usize = 12;
        try collectLayoutBoxes(allocator, &boxes, root_val, 0, 0, grid_width, grid_height);
        try renderGrid(allocator, writer, boxes.items, grid_width, grid_height);
    }
    try writer.print("\n", .{});
}

fn collectLayoutBoxes(allocator: std.mem.Allocator, boxes: *std.ArrayList(LayoutBox), node: std.json.Value, x: usize, y: usize, width: usize, height: usize) !void {
    if (node != .object) return;
    const obj = node.object;

    const type_str = if (obj.get("type")) |t| (if (t == .string) t.string else "unknown") else "unknown";

    if (std.mem.eql(u8, type_str, "pane")) {
        var pty_id: i64 = 0;
        var cwd: []const u8 = "";
        if (obj.get("pty_id")) |p| if (p == .integer) {
            pty_id = p.integer;
        };
        if (obj.get("cwd")) |c| if (c == .string) {
            cwd = c.string;
        };

        const home = std.posix.getenv("HOME") orelse "";
        var label_buf: [64]u8 = undefined;
        const label = if (home.len > 0 and std.mem.startsWith(u8, cwd, home))
            std.fmt.bufPrint(&label_buf, "~{s}", .{cwd[home.len..]}) catch "~"
        else
            std.fmt.bufPrint(&label_buf, "{s}", .{cwd}) catch "";

        try boxes.append(allocator, .{ .x = x, .y = y, .width = width, .height = height, .label = try allocator.dupe(u8, label), .pty_id = pty_id });
    } else if (std.mem.eql(u8, type_str, "split")) {
        const direction = if (obj.get("direction")) |d| (if (d == .string) d.string else "row") else "row";

        if (obj.get("children")) |ch| {
            if (ch == .array) {
                const children = ch.array.items;
                if (children.len == 0) return;

                var ratios = try allocator.alloc(f64, children.len);
                defer allocator.free(ratios);
                var total: f64 = 0;
                for (children, 0..) |child, i| {
                    ratios[i] = 1.0;
                    if (child == .object) if (child.object.get("ratio")) |r| if (r == .float) {
                        ratios[i] = r.float;
                    };
                    total += ratios[i];
                }
                for (ratios) |*r| r.* /= total;

                if (std.mem.eql(u8, direction, "row")) {
                    var cx = x;
                    for (children, 0..) |child, i| {
                        const cw = @as(usize, @intFromFloat(@as(f64, @floatFromInt(width)) * ratios[i]));
                        const aw = if (i == children.len - 1) (x + width - cx) else cw;
                        try collectLayoutBoxes(allocator, boxes, child, cx, y, aw, height);
                        cx += aw;
                    }
                } else {
                    var cy = y;
                    for (children, 0..) |child, i| {
                        const ch_h = @as(usize, @intFromFloat(@as(f64, @floatFromInt(height)) * ratios[i]));
                        const ah = if (i == children.len - 1) (y + height - cy) else ch_h;
                        try collectLayoutBoxes(allocator, boxes, child, x, cy, width, ah);
                        cy += ah;
                    }
                }
            }
        }
    }
}

fn renderGrid(allocator: std.mem.Allocator, writer: anytype, boxes: []const LayoutBox, width: usize, height: usize) !void {
    var grid = try allocator.alloc([]u8, height);
    defer {
        for (grid) |row| allocator.free(row);
        allocator.free(grid);
    }
    for (grid) |*row| {
        row.* = try allocator.alloc(u8, width);
        @memset(row.*, ' ');
    }

    for (boxes) |box| {
        if (box.width < 2 or box.height < 2) continue;
        for (box.x..box.x + box.width) |col| {
            if (col < width) {
                if (box.y < height) grid[box.y][col] = '-';
                if (box.y + box.height - 1 < height) grid[box.y + box.height - 1][col] = '-';
            }
        }
        for (box.y..box.y + box.height) |row| {
            if (row < height) {
                if (box.x < width) grid[row][box.x] = '|';
                if (box.x + box.width - 1 < width) grid[row][box.x + box.width - 1] = '|';
            }
        }
        if (box.y < height and box.x < width) grid[box.y][box.x] = '+';
        if (box.y < height and box.x + box.width - 1 < width) grid[box.y][box.x + box.width - 1] = '+';
        if (box.y + box.height - 1 < height and box.x < width) grid[box.y + box.height - 1][box.x] = '+';
        if (box.y + box.height - 1 < height and box.x + box.width - 1 < width) grid[box.y + box.height - 1][box.x + box.width - 1] = '+';

        if (box.height >= 3 and box.width >= 4) {
            const label_y = box.y + box.height / 2;
            const max_len = box.width - 2;
            var pty_buf: [16]u8 = undefined;
            const pty_str = std.fmt.bufPrint(&pty_buf, "pty={d}", .{box.pty_id}) catch "";
            const pty_start = box.x + 1 + (max_len - @min(pty_str.len, max_len)) / 2;
            for (pty_str, 0..) |c, i| {
                if (pty_start + i < box.x + box.width - 1 and label_y < height) grid[label_y][pty_start + i] = c;
            }
            if (box.height >= 5 and label_y > box.y + 1) {
                const cwd_y = label_y - 1;
                const dl = if (box.label.len > max_len) box.label[0..max_len] else box.label;
                const ls = box.x + 1 + (max_len - dl.len) / 2;
                for (dl, 0..) |c, i| {
                    if (ls + i < box.x + box.width - 1 and cwd_y < height) grid[cwd_y][ls + i] = c;
                }
            }
        }
    }

    for (grid) |row| {
        var end: usize = row.len;
        while (end > 0 and row[end - 1] == ' ') end -= 1;
        try writer.print("{s}\n", .{row[0..end]});
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
