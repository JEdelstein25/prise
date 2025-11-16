const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const redraw = @import("redraw.zig");
const key_notation = @import("key_notation.zig");
const posix = std.posix;
const vaxis = @import("vaxis");

pub const UnixSocketClient = struct {
    allocator: std.mem.Allocator,
    fd: ?posix.fd_t = null,
    ctx: io.Context,
    addr: posix.sockaddr.un,

    const Msg = enum {
        socket,
        connect,
    };

    fn handleMsg(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(UnixSocketClient);

        switch (completion.msgToEnum(Msg)) {
            .socket => {
                switch (completion.result) {
                    .socket => |fd| {
                        self.fd = fd;
                        _ = try loop.connect(
                            fd,
                            @ptrCast(&self.addr),
                            @sizeOf(posix.sockaddr.un),
                            .{
                                .ptr = self,
                                .msg = @intFromEnum(Msg.connect),
                                .cb = UnixSocketClient.handleMsg,
                            },
                        );
                    },
                    .err => |err| {
                        defer self.allocator.destroy(self);
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                    },
                    else => unreachable,
                }
            },

            .connect => {
                defer self.allocator.destroy(self);

                switch (completion.result) {
                    .connect => {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .socket = self.fd.? },
                        });
                    },
                    .err => |err| {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                        if (self.fd) |fd| {
                            _ = try loop.close(fd, .{
                                .ptr = null,
                                .cb = struct {
                                    fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
                                }.noop,
                            });
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
};

pub fn connectUnixSocket(
    loop: *io.Loop,
    socket_path: []const u8,
    ctx: io.Context,
) !*UnixSocketClient {
    const client = try loop.allocator.create(UnixSocketClient);
    errdefer loop.allocator.destroy(client);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    client.* = .{
        .allocator = loop.allocator,
        .ctx = ctx,
        .addr = addr,
        .fd = null,
    };

    _ = try loop.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
        .{
            .ptr = client,
            .msg = @intFromEnum(UnixSocketClient.Msg.socket),
            .cb = UnixSocketClient.handleMsg,
        },
    );

    return client;
}

pub const App = struct {
    connected: bool = false,
    connection_refused: bool = false,
    fd: posix.fd_t = undefined,
    allocator: std.mem.Allocator,
    recv_buffer: [4096]u8 = undefined,
    send_buffer: ?[]u8 = null,
    input_send_buffer: ?[]u8 = null,
    pty_id: ?i64 = null,
    response_received: bool = false,
    attached: bool = false,
    vx: vaxis.Vaxis = undefined,
    tty: vaxis.Tty = undefined,
    loop: vaxis.Loop(vaxis.Event) = undefined,
    should_quit: bool = false,
    hl_attrs: std.AutoHashMap(u32, vaxis.Style) = undefined,
    event_thread: ?std.Thread = null,
    io_loop: ?*io.Loop = null,
    tty_buffer: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) !App {
        var app: App = .{
            .allocator = allocator,
            .vx = try vaxis.init(allocator, .{}),
            .tty = undefined,
            .tty_buffer = undefined,
            .loop = undefined,
            .hl_attrs = std.AutoHashMap(u32, vaxis.Style).init(allocator),
        };
        app.tty = try vaxis.Tty.init(&app.tty_buffer);
        app.loop = .{ .tty = &app.tty, .vaxis = &app.vx };
        try app.loop.init();
        std.log.info("Vaxis loop initialized", .{});
        return app;
    }

    pub fn deinit(self: *App) void {
        self.should_quit = true;
        self.loop.stop();
        if (self.event_thread) |thread| {
            thread.join();
        }
        if (self.input_send_buffer) |buf| {
            self.allocator.free(buf);
        }
        self.hl_attrs.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn setup(self: *App, loop: *io.Loop) !void {
        self.io_loop = loop;

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

        // Show cursor at 0,0 initially
        const win = self.vx.window();
        win.showCursor(0, 0);

        try self.render();

        // Spawn thread to handle vaxis events
        std.log.info("Spawning event thread...", .{});
        self.event_thread = try std.Thread.spawn(.{}, eventThreadFn, .{self});
        std.log.info("Event thread spawned", .{});
    }

    fn eventThreadFn(self: *App) void {
        std.log.info("Event thread started", .{});

        // Start the vaxis loop (spawns TTY reader thread)
        self.loop.start() catch |err| {
            std.log.err("Failed to start vaxis loop: {}", .{err});
            return;
        };
        std.log.info("Vaxis loop started in event thread", .{});

        while (!self.should_quit) {
            std.log.debug("Waiting for next event...", .{});
            const event = self.loop.nextEvent();
            std.log.info("Received vaxis event: {s}", .{@tagName(event)});
            self.processEvent(event) catch |err| {
                std.log.err("Error processing event: {}", .{err});
            };
        }
        std.log.info("Event thread exiting", .{});
    }

    pub fn handleRedraw(self: *App, params: msgpack.Value) !void {
        if (params != .array) return error.InvalidRedrawParams;

        const win = self.vx.window();

        for (params.array) |event_val| {
            if (event_val != .array or event_val.array.len < 2) continue;

            const event_name = event_val.array[0];
            if (event_name != .string) continue;

            const event_params = event_val.array[1];
            if (event_params != .array) continue;

            if (std.mem.eql(u8, event_name.string, "grid_resize")) {
                // event_params is [grid, width, height]
                if (event_params.array.len < 3) continue;

                const width = switch (event_params.array[1]) {
                    .unsigned => |u| @as(u16, @intCast(u)),
                    .integer => |i| @as(u16, @intCast(i)),
                    else => continue,
                };
                const height = switch (event_params.array[2]) {
                    .unsigned => |u| @as(u16, @intCast(u)),
                    .integer => |i| @as(u16, @intCast(i)),
                    else => continue,
                };

                const winsize: vaxis.Winsize = .{
                    .rows = height,
                    .cols = width,
                    .x_pixel = 0,
                    .y_pixel = 0,
                };
                try self.vx.resize(self.allocator, self.tty.writer(), winsize);
            } else if (std.mem.eql(u8, event_name.string, "grid_cursor_goto")) {
                // event_params is [grid, row, col]
                if (event_params.array.len < 3) continue;

                const row = switch (event_params.array[1]) {
                    .unsigned => |u| @as(u16, @intCast(u)),
                    .integer => |i| @as(u16, @intCast(i)),
                    else => continue,
                };
                const col = switch (event_params.array[2]) {
                    .unsigned => |u| @as(u16, @intCast(u)),
                    .integer => |i| @as(u16, @intCast(i)),
                    else => continue,
                };

                win.showCursor(col, row);
            } else if (std.mem.eql(u8, event_name.string, "grid_line")) {
                // event_params is [grid, row, col_start, cells, wrap]
                if (event_params.array.len < 4) continue;

                const row = switch (event_params.array[1]) {
                    .unsigned => |u| @as(usize, @intCast(u)),
                    .integer => |i| @as(usize, @intCast(i)),
                    else => continue,
                };
                var col = switch (event_params.array[2]) {
                    .unsigned => |u| @as(usize, @intCast(u)),
                    .integer => |i| @as(usize, @intCast(i)),
                    else => continue,
                };

                const cells = event_params.array[3];
                if (cells != .array) continue;

                var current_hl: u32 = 0;
                for (cells.array) |cell| {
                    if (cell != .array or cell.array.len == 0) continue;

                    const text = if (cell.array[0] == .string) cell.array[0].string else " ";

                    if (cell.array.len > 1 and cell.array[1] != .nil) {
                        current_hl = switch (cell.array[1]) {
                            .unsigned => |u| @as(u32, @intCast(u)),
                            .integer => |i| @as(u32, @intCast(i)),
                            else => current_hl,
                        };
                    }

                    const repeat: usize = if (cell.array.len > 2 and cell.array[2] != .nil)
                        switch (cell.array[2]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => 1,
                        }
                    else
                        1;

                    const style = self.hl_attrs.get(current_hl) orelse vaxis.Style{};

                    var i: usize = 0;
                    while (i < repeat) : (i += 1) {
                        if (col < win.width and row < win.height) {
                            win.writeCell(@intCast(col), @intCast(row), .{
                                .char = .{ .grapheme = text },
                                .style = style,
                            });
                        }
                        col += 1;
                    }
                }
            } else if (std.mem.eql(u8, event_name.string, "grid_clear")) {
                win.clear();
            } else if (std.mem.eql(u8, event_name.string, "hl_attr_define")) {
                // event_params is [id, rgb_attrs, cterm_attrs, info]
                if (event_params.array.len < 2) continue;

                const id = switch (event_params.array[0]) {
                    .unsigned => |u| @as(u32, @intCast(u)),
                    .integer => |i| @as(u32, @intCast(i)),
                    else => continue,
                };

                const rgb_attrs = event_params.array[1];
                if (rgb_attrs != .map) continue;

                var style = vaxis.Style{};

                for (rgb_attrs.map) |kv| {
                    if (kv.key != .string) continue;

                    if (std.mem.eql(u8, kv.key.string, "foreground")) {
                        if (kv.value == .unsigned) {
                            const val = @as(u32, @intCast(kv.value.unsigned));
                            if (val < 256) {
                                // Palette index
                                style.fg = .{ .index = @intCast(val) };
                            } else {
                                // RGB value
                                style.fg = .{ .rgb = .{
                                    @intCast((val >> 16) & 0xFF),
                                    @intCast((val >> 8) & 0xFF),
                                    @intCast(val & 0xFF),
                                } };
                            }
                        }
                    } else if (std.mem.eql(u8, kv.key.string, "background")) {
                        if (kv.value == .unsigned) {
                            const val = @as(u32, @intCast(kv.value.unsigned));
                            if (val < 256) {
                                // Palette index
                                style.bg = .{ .index = @intCast(val) };
                            } else {
                                // RGB value
                                style.bg = .{ .rgb = .{
                                    @intCast((val >> 16) & 0xFF),
                                    @intCast((val >> 8) & 0xFF),
                                    @intCast(val & 0xFF),
                                } };
                            }
                        }
                    } else if (std.mem.eql(u8, kv.key.string, "bold")) {
                        if (kv.value == .boolean and kv.value.boolean) {
                            style.bold = true;
                        }
                    } else if (std.mem.eql(u8, kv.key.string, "italic")) {
                        if (kv.value == .boolean and kv.value.boolean) {
                            style.italic = true;
                        }
                    } else if (std.mem.eql(u8, kv.key.string, "underline")) {
                        if (kv.value == .boolean and kv.value.boolean) {
                            style.ul_style = .single;
                        }
                    } else if (std.mem.eql(u8, kv.key.string, "reverse")) {
                        if (kv.value == .boolean and kv.value.boolean) {
                            style.reverse = true;
                        }
                    }
                }

                try self.hl_attrs.put(id, style);
            } else if (std.mem.eql(u8, event_name.string, "flush")) {
                try self.render();
            }
        }
    }

    pub fn render(self: *App) !void {
        try self.vx.render(self.tty.writer());
    }

    pub fn onConnected(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .socket => |fd| {
                app.fd = fd;
                app.connected = true;
                std.log.info("Connected! fd={}", .{app.fd});

                app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 1, "spawn_pty", .{} });

                _ = try l.send(fd, app.send_buffer.?, .{
                    .ptr = app,
                    .cb = onSendComplete,
                });
            },
            .err => |err| {
                if (err == error.ConnectionRefused) {
                    app.connection_refused = true;
                } else {
                    std.log.err("Connection failed: {}", .{err});
                }
            },
            else => unreachable,
        }
    }

    fn onSendComplete(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        if (app.send_buffer) |buf| {
            app.allocator.free(buf);
            app.send_buffer = null;
        }

        switch (completion.result) {
            .send => |bytes_sent| {
                std.log.info("Sent {} bytes", .{bytes_sent});

                _ = try l.recv(app.fd, &app.recv_buffer, .{
                    .ptr = app,
                    .cb = onRecv,
                });
            },
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn onRecv(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    std.log.info("Server closed connection", .{});
                    return;
                }

                const data = app.recv_buffer[0..bytes_read];
                const msg = try rpc.decodeMessage(app.allocator, data);
                defer msg.deinit(app.allocator);

                switch (msg) {
                    .response => |resp| {
                        std.log.info("Got response: msgid={}", .{resp.msgid});
                        if (resp.err) |err| {
                            std.log.err("Error: {}", .{err});
                        } else {
                            switch (resp.result) {
                                .integer => |i| {
                                    if (app.pty_id == null) {
                                        app.pty_id = i;
                                        std.log.info("PTY spawned with ID: {}", .{i});

                                        // Attach to the session
                                        app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 2, "attach_pty", .{i} });
                                        _ = try l.send(app.fd, app.send_buffer.?, .{
                                            .ptr = app,
                                            .cb = onSendComplete,
                                        });
                                    } else if (!app.attached) {
                                        std.log.info("Attached to session {}", .{i});
                                        app.attached = true;
                                    }
                                },
                                .unsigned => |u| {
                                    if (app.pty_id == null) {
                                        app.pty_id = @intCast(u);
                                        std.log.info("PTY spawned with ID: {}", .{u});

                                        // Attach to the session
                                        app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 2, "attach_pty", .{u} });
                                        _ = try l.send(app.fd, app.send_buffer.?, .{
                                            .ptr = app,
                                            .cb = onSendComplete,
                                        });
                                    } else if (!app.attached) {
                                        std.log.info("Attached to session {}", .{u});
                                        app.attached = true;
                                    }
                                },
                                .string => |s| {
                                    std.log.info("Result: {s}", .{s});
                                },
                                else => {
                                    std.log.info("Result: {}", .{resp.result});
                                },
                            }
                        }
                        app.response_received = true;
                    },
                    .request => {
                        std.log.warn("Got unexpected request from server", .{});
                    },
                    .notification => |notif| {
                        if (std.mem.eql(u8, notif.method, "redraw")) {
                            std.log.debug("Handling redraw notification", .{});
                            app.handleRedraw(notif.params) catch |err| {
                                std.log.err("Failed to handle redraw: {}", .{err});
                            };
                            std.log.debug("Redraw handled, rendering", .{});
                            app.render() catch |err| {
                                std.log.err("Failed to render: {}", .{err});
                            };
                            std.log.debug("Render complete", .{});
                        }
                    },
                }

                // Check if we should quit
                if (app.should_quit) {
                    std.log.info("Quitting, closing connection", .{});
                    _ = try l.close(app.fd, .{
                        .ptr = null,
                        .cb = struct {
                            fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
                        }.noop,
                    });
                    return;
                }

                // Keep receiving
                _ = try l.recv(app.fd, &app.recv_buffer, .{
                    .ptr = app,
                    .cb = onRecv,
                });
            },
            .err => |err| {
                std.log.err("Recv failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn processEvent(self: *App, event: vaxis.Event) !void {
        std.log.debug("Processing event: {s}", .{@tagName(event)});
        switch (event) {
            .key_press => |key| {
                if (self.should_quit) return;

                // Check for Ctrl+C to quit
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    std.log.info("Ctrl+C detected, quitting", .{});
                    self.should_quit = true;
                    // Send a ping to wake up the recv loop
                    self.sendPing() catch {};
                    return;
                }

                // Send keyboard input to the PTY
                if (self.attached and self.pty_id != null) {
                    try self.sendInput(key);
                } else {
                    std.log.debug("Not attached or no PTY, skipping input", .{});
                }
            },
            .winsize => |ws| {
                std.log.debug("Winsize event: {}x{}", .{ ws.rows, ws.cols });
                // Send resize to server, which will send us redraw notifications
                if (self.attached and self.pty_id != null) {
                    try self.sendResize(ws);
                } else {
                    std.log.debug("Not attached or no PTY, skipping resize", .{});
                }
            },
            else => {}, // Ignore other event types
        }
        std.log.debug("Event processed", .{});
    }

    fn sendInput(self: *App, key: vaxis.Key) !void {
        // Convert vaxis key to Neovim key notation
        var notation_buf: [32]u8 = undefined;
        const notation = try key_notation.fromVaxisKey(key, &notation_buf);

        std.log.debug("Sending key: codepoint={} mods=(ctrl={} alt={} shift={}) notation='{s}'", .{
            key.codepoint,
            key.mods.ctrl,
            key.mods.alt,
            key.mods.shift,
            notation,
        });

        // Check if we're already sending something
        if (self.input_send_buffer != null) {
            std.log.warn("Dropping key input - send already in progress", .{});
            return;
        }

        self.input_send_buffer = try msgpack.encode(self.allocator, .{
            2, // notification
            "key_input",
            .{ self.pty_id.?, notation },
        });

        const loop = self.io_loop orelse return error.NoIOLoop;
        std.log.debug("Submitting send operation", .{});
        _ = try loop.send(self.fd, self.input_send_buffer.?, .{
            .ptr = self,
            .cb = onInputSendComplete,
        });
        std.log.debug("Send operation submitted", .{});
    }

    fn onInputSendComplete(_: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        std.log.debug("Input send completed", .{});

        if (app.input_send_buffer) |buf| {
            app.allocator.free(buf);
            app.input_send_buffer = null;
        }

        switch (completion.result) {
            .send => |n| {
                std.log.debug("Sent {} bytes", .{n});
            },
            .err => |err| {
                std.log.err("Input send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn sendResize(self: *App, ws: vaxis.Winsize) !void {
        // Send resize_pty notification to server
        if (self.input_send_buffer) |old_buf| {
            self.allocator.free(old_buf);
        }

        self.input_send_buffer = try msgpack.encode(self.allocator, .{
            2, // notification
            "resize_pty",
            .{ self.pty_id.?, ws.rows, ws.cols },
        });

        const loop = self.io_loop orelse return error.NoIOLoop;
        _ = try loop.send(self.fd, self.input_send_buffer.?, .{
            .ptr = self,
            .cb = onInputSendComplete,
        });
    }

    fn sendPing(self: *App) !void {
        // Send a ping to wake up the recv loop
        if (self.input_send_buffer) |old_buf| {
            self.allocator.free(old_buf);
        }

        self.input_send_buffer = try msgpack.encode(self.allocator, .{
            2, // notification
            "ping",
            .{},
        });

        const loop = self.io_loop orelse return error.NoIOLoop;
        _ = try loop.send(self.fd, self.input_send_buffer.?, .{
            .ptr = self,
            .cb = onInputSendComplete,
        });
    }
};

test "UnixSocketClient - successful connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var connected = false;
    var fd: posix.socket_t = undefined;

    const State = struct {
        connected: *bool,
        fd: *posix.socket_t,
    };

    var state = State{
        .connected = &connected,
        .fd = &fd,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => |socket_fd| {
                    s.fd.* = socket_fd;
                    s.connected.* = true;
                },
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);
    try testing.expect(!connected);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeConnect(socket_fd);
    try loop.run(.once);
    try testing.expect(connected);
    try testing.expectEqual(socket_fd, fd);
}

test "UnixSocketClient - connection refused" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var got_error = false;
    var err_value: ?anyerror = null;

    const State = struct {
        got_error: *bool,
        err_value: *?anyerror,
    };

    var state = State{
        .got_error = &got_error,
        .err_value = &err_value,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => {},
                .err => |err| {
                    s.got_error.* = true;
                    s.err_value.* = err;
                },
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeWithError(socket_fd, error.ConnectionRefused);
    try loop.run(.until_done);
    try testing.expect(got_error);
    try testing.expectEqual(error.ConnectionRefused, err_value.?);
}
