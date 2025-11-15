const std = @import("std");
const msgpack = @import("msgpack.zig");
const Allocator = std.mem.Allocator;

/// msgpack-RPC message types
pub const MessageType = enum(u8) {
    request = 0,
    response = 1,
    notification = 2,
};

/// Request: [type=0, msgid, method, params]
pub const Request = struct {
    msgid: u32,
    method: []const u8,
    params: msgpack.Value,

    pub fn deinit(self: Request, allocator: Allocator) void {
        allocator.free(self.method);
        self.params.deinit(allocator);
    }
};

/// Response: [type=1, msgid, error, result]
pub const Response = struct {
    msgid: u32,
    err: ?msgpack.Value,
    result: msgpack.Value,

    pub fn deinit(self: Response, allocator: Allocator) void {
        if (self.err) |e| e.deinit(allocator);
        self.result.deinit(allocator);
    }
};

/// Notification: [type=2, method, params]
pub const Notification = struct {
    method: []const u8,
    params: msgpack.Value,

    pub fn deinit(self: Notification, allocator: Allocator) void {
        allocator.free(self.method);
        self.params.deinit(allocator);
    }
};

pub const Message = union(MessageType) {
    request: Request,
    response: Response,
    notification: Notification,

    pub fn deinit(self: Message, allocator: Allocator) void {
        switch (self) {
            .request => |r| r.deinit(allocator),
            .response => |r| r.deinit(allocator),
            .notification => |n| n.deinit(allocator),
        }
    }
};

pub const DecodeError = error{
    InvalidMessageFormat,
    InvalidMessageType,
    InvalidArrayLength,
    NotAnArray,
    NotAnInteger,
    NotAString,
} || msgpack.DecodeError;

pub fn decodeMessage(allocator: Allocator, data: []const u8) DecodeError!Message {
    var decoder = msgpack.Decoder.init(allocator, data);
    const value = try decoder.decode();
    errdefer value.deinit(allocator);

    if (value != .array) return error.NotAnArray;
    const arr = value.array;
    if (arr.len < 3) return error.InvalidArrayLength;

    // First element is message type
    if (arr[0] != .unsigned and arr[0] != .integer) return error.NotAnInteger;
    const msg_type_int: u8 = switch (arr[0]) {
        .unsigned => |u| @intCast(u),
        .integer => |i| @intCast(i),
        else => unreachable,
    };

    const result = switch (msg_type_int) {
        0 => blk: { // Request: [0, msgid, method, params]
            if (arr.len != 4) return error.InvalidArrayLength;

            if (arr[1] != .unsigned and arr[1] != .integer) return error.NotAnInteger;
            const msgid: u32 = switch (arr[1]) {
                .unsigned => |u| @intCast(u),
                .integer => |i| @intCast(i),
                else => unreachable,
            };

            if (arr[2] != .string) return error.NotAString;
            const method = try allocator.dupe(u8, arr[2].string);

            break :blk Message{
                .request = .{
                    .msgid = msgid,
                    .method = method,
                    .params = arr[3],
                },
            };
        },
        1 => blk: { // Response: [1, msgid, error, result]
            if (arr.len != 4) return error.InvalidArrayLength;

            if (arr[1] != .unsigned and arr[1] != .integer) return error.NotAnInteger;
            const msgid: u32 = switch (arr[1]) {
                .unsigned => |u| @intCast(u),
                .integer => |i| @intCast(i),
                else => unreachable,
            };

            const err = if (arr[2] == .nil) null else arr[2];

            break :blk Message{
                .response = .{
                    .msgid = msgid,
                    .err = err,
                    .result = arr[3],
                },
            };
        },
        2 => blk: { // Notification: [2, method, params]
            if (arr.len != 3) return error.InvalidArrayLength;

            if (arr[1] != .string) return error.NotAString;
            const method = try allocator.dupe(u8, arr[1].string);

            break :blk Message{
                .notification = .{
                    .method = method,
                    .params = arr[2],
                },
            };
        },
        else => return error.InvalidMessageType,
    };

    // Free the array container and non-extracted elements
    for (arr, 0..) |item, i| {
        switch (result) {
            .request => {
                // We duplicated arr[2] (method), keep arr[3] (params)
                if (i != 3) item.deinit(allocator);
            },
            .response => {
                // Keep arr[2] (error) and arr[3] (result)
                if (i != 2 and i != 3) item.deinit(allocator);
            },
            .notification => {
                // We duplicated arr[1] (method), keep arr[2] (params)
                if (i != 2) item.deinit(allocator);
            },
        }
    }
    allocator.free(arr);

    return result;
}

const testing = std.testing;

test "decode request" {
    // [0, 1, "test_method", []]
    const data = try msgpack.encode(testing.allocator, .{ 0, 1, "test_method", .{} });
    defer testing.allocator.free(data);

    const msg = try decodeMessage(testing.allocator, data);
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .request);
    try testing.expectEqual(@as(u32, 1), msg.request.msgid);
    try testing.expectEqualStrings("test_method", msg.request.method);
}

test "decode response success" {
    // [1, 1, nil, 42]
    const data = try msgpack.encode(testing.allocator, .{ 1, 1, null, 42 });
    defer testing.allocator.free(data);

    const msg = try decodeMessage(testing.allocator, data);
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .response);
    try testing.expectEqual(@as(u32, 1), msg.response.msgid);
    try testing.expect(msg.response.err == null);
    try testing.expect(msg.response.result.unsigned == 42);
}

test "decode notification" {
    // [2, "event_name", {}]
    const data = try msgpack.encode(testing.allocator, .{ 2, "event_name", .{} });
    defer testing.allocator.free(data);

    const msg = try decodeMessage(testing.allocator, data);
    defer msg.deinit(testing.allocator);

    try testing.expect(msg == .notification);
    try testing.expectEqualStrings("event_name", msg.notification.method);
}
