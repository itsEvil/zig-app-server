const std = @import("std");
const net = std.net;
const CommandSerializer = @import("serializer.zig").CommandSerializer;
const RESP3 = @import("./parser.zig").RESP3Parser;
const logger = @import("../log.zig");
const log = logger.get(.redis);

pub const Buffering = union(enum) {
    NoBuffering,
    Fixed: usize,
};

pub const Client = RedisClient(.NoBuffering);
pub const BufferedClient = RedisClient(.{ .Fixed = 4096 });
pub fn RedisClient(comptime buffering: Buffering) type {
    const ReadBuffer = switch (buffering) {
        .NoBuffering => void,
        .Fixed => |b| std.io.BufferedReader(b, net.Stream.Reader),
    };

    const WriteBuffer = switch (buffering) {
        .NoBuffering => void,
        .Fixed => |b| std.io.BufferedWriter(b, net.Stream.Writer),
    };
    return struct {
        conn: net.Stream,
        reader: switch (buffering) {
            .NoBuffering => net.Stream.Reader,
            .Fixed => ReadBuffer.Reader,
        },
        writer: switch (buffering) {
            .NoBuffering => net.Stream.Writer,
            .Fixed => WriteBuffer.Writer,
        },
        readBuffer: ReadBuffer,
        writeBuffer: WriteBuffer,

        broken: bool,

        const Self = @This();

        pub fn init(self: *Self, conn: net.Stream) !void {
            self.conn = conn;
            switch (buffering) {
                .NoBuffering => {
                    self.reader = conn.reader();
                    self.writer = conn.writer();
                },
                .Fixed => {
                    self.readBuffer = ReadBuffer{ .unbuffered_reader = conn.reader() };
                    self.reader = self.readBuffer.reader();
                    self.writeBuffer = WriteBuffer{ .unbuffered_writer = conn.writer() };
                    self.writer = self.writeBuffer.writer();
                },
            }
            self.broken = false;

            self.send(void, .{"PING"}) catch |err| {
                self.broken = true;
                log.err("client::{any}", .{err});
                if (err == error.GotErrorReply) {
                    return error.ServerTooOld;
                } else {
                    return err;
                }
            };

            //Test Client if 'GET' and 'SET' commands work
            //try testClient(self);
        }

        pub fn close(self: Self) void {
            self.conn.close();
        }

        /// Sends a command to Redis and tries to parse the response as the specified type.
        pub fn send(self: *Self, comptime T: type, cmd: anytype) !T {
            return self.pipelineImpl(T, cmd, .{ .one = {} });
        }

        /// Like `send`, can allocate memory.
        pub fn sendAlloc(self: *Self, comptime T: type, allocator: std.mem.Allocator, cmd: anytype) !T {
            return self.pipelineImpl(T, cmd, .{ .one = {}, .ptr = allocator });
        }

        /// Performs a Redis MULTI/EXEC transaction using pipelining.
        /// It's mostly provided for convenience as the same result
        /// can be achieved by making explicit use of `pipe` and `pipeAlloc`.
        pub fn trans(self: *Self, comptime Ts: type, cmds: anytype) !Ts {
            return self.transactionImpl(Ts, cmds, .{});
        }

        /// Like `trans`, but can allocate memory.
        pub fn transAlloc(self: *Self, comptime Ts: type, allocator: std.mem.Allocator, cmds: anytype) !Ts {
            return transactionImpl(self, Ts, cmds, .{ .ptr = allocator });
        }

        /// Sends a group of commands more efficiently than sending them one by one.
        pub fn pipe(self: *Self, comptime Ts: type, cmds: anytype) !Ts {
            return pipelineImpl(self, Ts, cmds, .{});
        }

        /// Like `pipe`, but can allocate memory.
        pub fn pipeAlloc(self: *Self, comptime Ts: type, allocator: std.mem.Allocator, cmds: anytype) !Ts {
            return pipelineImpl(self, Ts, cmds, .{ .ptr = allocator });
        }

        fn transactionImpl(self: *Self, comptime Ts: type, cmds: anytype, allocator: anytype) !Ts {
            // TODO: this is not threadsafe.
            _ = try self.send(void, .{"MULTI"});
            try self.pipe(void, cmds);

            if (@hasField(@TypeOf(allocator), "ptr")) {
                return self.sendAlloc(Ts, allocator.ptr, .{"EXEC"});
            } else {
                return self.send(Ts, .{"EXEC"});
            }
        }

        fn pipelineImpl(self: *Self, comptime Ts: type, cmds: anytype, allocator: anytype) !Ts {
            // TODO: find a way to express some of the metaprogramming requirements
            // in a more clear way. Using @hasField this way is ugly.
            // Serialize all the commands
            if (@hasField(@TypeOf(allocator), "one")) {
                try CommandSerializer.serializeCommand(self.writer, cmds);
            } else {
                inline for (std.meta.fields(@TypeOf(cmds))) |field| {
                    const cmd = @field(cmds, field.name);
                    // try ArgSerializer.serialize(&self.out.stream, args);
                    try CommandSerializer.serializeCommand(self.writer, cmd);
                }
            } // Here is where the write lock gets released by the `defer` statement.

            if (buffering == .Fixed) {
                try self.writeBuffer.flush();
            }

            // TODO: error procedure
            if (@hasField(@TypeOf(allocator), "one")) {
                if (@hasField(@TypeOf(allocator), "ptr")) {
                    return RESP3.parseAlloc(Ts, allocator.ptr, self.reader);
                } else {
                    return RESP3.parse(Ts, self.reader);
                }
            } else {
                var result: Ts = undefined;

                if (Ts == void) {
                    const cmd_num = std.meta.fields(@TypeOf(cmds)).len;
                    comptime var i: usize = 0;
                    inline while (i < cmd_num) : (i += 1) {
                        try RESP3.parse(void, self.reader);
                    }
                    return;
                } else {
                    switch (@typeInfo(Ts)) {
                        .Struct => {
                            inline for (std.meta.fields(Ts)) |field| {
                                if (@hasField(@TypeOf(allocator), "ptr")) {
                                    @field(result, field.name) = try RESP3.parseAlloc(field.field_type, allocator.ptr, self.reader);
                                } else {
                                    @field(result, field.name) = try RESP3.parse(field.field_type, self.reader);
                                }
                            }
                        },
                        .Array => {
                            var i: usize = 0;
                            while (i < Ts.len) : (i += 1) {
                                if (@hasField(@TypeOf(allocator), "ptr")) {
                                    result[i] = try RESP3.parseAlloc(Ts.Child, allocator.ptr, self.reader);
                                } else {
                                    result[i] = try RESP3.parse(Ts.Child, self.reader);
                                }
                            }
                        },
                        .Pointer => |ptr| {
                            switch (ptr.size) {
                                .One => {
                                    if (@hasField(@TypeOf(allocator), "ptr")) {
                                        result = try RESP3.parseAlloc(Ts, allocator.ptr, self.reader);
                                    } else {
                                        result = try RESP3.parse(Ts, self.reader);
                                    }
                                },
                                .Many => {
                                    if (@hasField(@TypeOf(allocator), "ptr")) {
                                        result = try allocator.alloc(ptr.child, ptr.size);
                                        errdefer allocator.free(result);

                                        for (result) |*elem| {
                                            elem.* = try RESP3.parseAlloc(Ts.Child, allocator.ptr, self.reader);
                                        }
                                    } else {
                                        @compileError("Use sendAlloc / pipeAlloc / transAlloc to decode pointer types.");
                                    }
                                },
                            }
                        },
                        else => @compileError("Unsupported type"),
                    }
                }
                return result;
            }
        }
    };
}

fn testClient(self: *Client) !void {
    log.info("setting key to 1245234", .{});
    const set_reply = try self.send(void, .{ "SET", "key", "1245234" });
    log.info("set reply {}", .{set_reply});
    const get_reply = try self.send(i64, .{ "GET", "key" });
    log.info("key value is: {}", .{get_reply});
}
