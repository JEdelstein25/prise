const std = @import("std");
const posix = std.posix;
const root = @import("../io.zig");

pub const Loop = struct {
    allocator: std.mem.Allocator,
    next_id: usize = 1,
    next_fd: posix.socket_t = 100,
    pending: std.AutoHashMap(usize, PendingOp),
    completions: std.ArrayList(QueuedCompletion),

    const PendingOp = struct {
        ctx: root.Context,
        kind: OpKind,
        fd: posix.socket_t = undefined,
        buf: []u8 = &.{},
    };

    const QueuedCompletion = struct {
        id: usize,
        result: root.Result,
    };

    const OpKind = enum {
        socket,
        connect,
        accept,
        recv,
        send,
        close,
        timer,
    };

    pub fn init(allocator: std.mem.Allocator) !Loop {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(usize, PendingOp).init(allocator),
            .completions = std.ArrayList(QueuedCompletion).empty,
        };
    }

    pub fn deinit(self: *Loop) void {
        self.pending.deinit();
        self.completions.deinit(self.allocator);
    }

    pub fn socket(
        self: *Loop,
        domain: u32,
        socket_type: u32,
        protocol: u32,
        ctx: root.Context,
    ) !root.Task {
        _ = domain;
        _ = socket_type;
        _ = protocol;

        const id = self.next_id;
        self.next_id += 1;

        const fd = self.next_fd;
        self.next_fd += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .socket,
            .fd = fd,
        });

        try self.completions.append(self.allocator, .{
            .id = id,
            .result = .{ .socket = fd },
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn connect(
        self: *Loop,
        fd: posix.socket_t,
        addr: *const posix.sockaddr,
        addr_len: posix.socklen_t,
        ctx: root.Context,
    ) !root.Task {
        _ = addr;
        _ = addr_len;

        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .connect,
            .fd = fd,
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn accept(
        self: *Loop,
        fd: posix.socket_t,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .accept,
            .fd = fd,
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn recv(
        self: *Loop,
        fd: posix.socket_t,
        buf: []u8,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .recv,
            .fd = fd,
            .buf = buf,
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn send(
        self: *Loop,
        fd: posix.socket_t,
        buf: []const u8,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .send,
            .fd = fd,
            .buf = @constCast(buf),
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn close(
        self: *Loop,
        fd: posix.socket_t,
        ctx: root.Context,
    ) !root.Task {
        _ = fd;

        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .close,
        });

        try self.completions.append(self.allocator, .{
            .id = id,
            .result = .{ .close = {} },
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn timeout(
        self: *Loop,
        nanoseconds: u64,
        ctx: root.Context,
    ) !root.Task {
        _ = nanoseconds; // Mock doesn't actually wait

        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .timer,
        });

        // Mock immediately completes timers
        try self.completions.append(self.allocator, .{
            .id = id,
            .result = .{ .timer = {} },
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn cancel(self: *Loop, id: usize) !void {
        _ = self.pending.remove(id);
        var i: usize = 0;
        while (i < self.completions.items.len) {
            if (self.completions.items[i].id == id) {
                _ = self.completions.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        while (true) {
            if (mode == .until_done and self.pending.count() == 0) break;
            if (self.completions.items.len == 0 and mode == .once) break;

            if (self.completions.items.len == 0) break;

            const completion = self.completions.orderedRemove(0);
            const op = self.pending.get(completion.id) orelse continue;
            _ = self.pending.remove(completion.id);

            try op.ctx.cb(self, .{
                .userdata = op.ctx.ptr,
                .msg = op.ctx.msg,
                .callback = op.ctx.cb,
                .result = completion.result,
            });

            if (mode == .once) break;
        }
    }

    pub fn completeConnect(self: *Loop, fd: posix.socket_t) !void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect and entry.value_ptr.fd == fd) {
                try self.completions.append(self.allocator, .{
                    .id = entry.key_ptr.*,
                    .result = .{ .connect = {} },
                });
                return;
            }
        }
        return error.OperationNotFound;
    }

    pub fn completeAccept(self: *Loop, fd: posix.socket_t) !void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .accept and entry.value_ptr.fd == fd) {
                const client_fd = self.next_fd;
                self.next_fd += 1;
                try self.completions.append(self.allocator, .{
                    .id = entry.key_ptr.*,
                    .result = .{ .accept = client_fd },
                });
                return;
            }
        }
        return error.OperationNotFound;
    }

    pub fn completeRecv(self: *Loop, fd: posix.socket_t, data: []const u8) !void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .recv and entry.value_ptr.fd == fd) {
                const buf = entry.value_ptr.buf;
                const n = @min(buf.len, data.len);
                @memcpy(buf[0..n], data[0..n]);
                try self.completions.append(self.allocator, .{
                    .id = entry.key_ptr.*,
                    .result = .{ .recv = n },
                });
                return;
            }
        }
        return error.OperationNotFound;
    }

    pub fn completeSend(self: *Loop, fd: posix.socket_t, bytes_sent: usize) !void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .send and entry.value_ptr.fd == fd) {
                try self.completions.append(self.allocator, .{
                    .id = entry.key_ptr.*,
                    .result = .{ .send = bytes_sent },
                });
                return;
            }
        }
        return error.OperationNotFound;
    }

    pub fn completeWithError(self: *Loop, fd: posix.socket_t, err: anyerror) !void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.fd == fd) {
                try self.completions.append(self.allocator, .{
                    .id = entry.key_ptr.*,
                    .result = .{ .err = err },
                });
                return;
            }
        }
        return error.OperationNotFound;
    }

    pub const RunMode = enum {
        until_done,
        once,
        forever,
    };
};

test "mock loop - basic socket operation" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    var socket_fd: posix.socket_t = undefined;
    var completed = false;

    const State = struct {
        fd: *posix.socket_t,
        completed: *bool,
    };

    var state = State{
        .fd = &socket_fd,
        .completed = &completed,
    };

    const callback = struct {
        fn cb(l: *Loop, completion: root.Completion) !void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => |fd| {
                    s.fd.* = fd;
                    s.completed.* = true;
                },
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try loop.socket(posix.AF.INET, posix.SOCK.STREAM, 0, .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.until_done);
    try testing.expect(completed);
    try testing.expect(socket_fd >= 100);
}

test "mock loop - connect operation" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    var connected = false;

    const State = struct {
        connected: *bool,
    };

    var state = State{
        .connected = &connected,
    };

    const callback = struct {
        fn cb(l: *Loop, completion: root.Completion) !void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .connect => s.connected.* = true,
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    const addr = std.mem.zeroes(posix.sockaddr);
    _ = try loop.connect(100, &addr, @sizeOf(posix.sockaddr), .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.completeConnect(100);
    try loop.run(.until_done);
    try testing.expect(connected);
}

test "mock loop - accept operation" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    var client_fd: posix.socket_t = undefined;
    var accepted = false;

    const State = struct {
        fd: *posix.socket_t,
        accepted: *bool,
    };

    var state = State{
        .fd = &client_fd,
        .accepted = &accepted,
    };

    const callback = struct {
        fn cb(l: *Loop, completion: root.Completion) !void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .accept => |fd| {
                    s.fd.* = fd;
                    s.accepted.* = true;
                },
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try loop.accept(100, .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.completeAccept(100);
    try loop.run(.until_done);
    try testing.expect(accepted);
    try testing.expect(client_fd >= 100);
}

test "mock loop - recv operation" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    var buf: [64]u8 = undefined;
    var bytes_received: usize = 0;

    const State = struct {
        bytes: *usize,
    };

    var state = State{
        .bytes = &bytes_received,
    };

    const callback = struct {
        fn cb(l: *Loop, completion: root.Completion) !void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .recv => |n| s.bytes.* = n,
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try loop.recv(100, &buf, .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.completeRecv(100, "hello");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 5), bytes_received);
    try testing.expectEqualStrings("hello", buf[0..5]);
}

test "mock loop - close operation" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    var closed = false;

    const State = struct {
        closed: *bool,
    };

    var state = State{
        .closed = &closed,
    };

    const callback = struct {
        fn cb(l: *Loop, completion: root.Completion) !void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .close => s.closed.* = true,
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try loop.close(100, .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.until_done);
    try testing.expect(closed);
}

test "mock loop - cancel operation" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit();

    var completed = false;

    const State = struct {
        completed: *bool,
    };

    var state = State{
        .completed = &completed,
    };

    const callback = struct {
        fn cb(l: *Loop, completion: root.Completion) !void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .connect => s.completed.* = true,
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    const addr = std.mem.zeroes(posix.sockaddr);
    var task = try loop.connect(100, &addr, @sizeOf(posix.sockaddr), .{
        .ptr = &state,
        .cb = callback,
    });

    try testing.expectEqual(@as(usize, 1), loop.pending.count());

    try task.cancel(&loop);

    try testing.expectEqual(@as(usize, 0), loop.pending.count());
    try testing.expectEqual(@as(usize, 0), loop.completions.items.len);

    try loop.run(.until_done);
    try testing.expect(!completed);
}
