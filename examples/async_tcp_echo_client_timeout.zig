const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const time = std.time;
const IO = @import("tigerbeetle-io").IO;
const http = @import("http");

fn IoOpContext(comptime ResultType: type) type {
    return struct {
        frame: anyframe = undefined,
        result: ResultType = undefined,
    };
}

const Client = struct {
    io: IO,
    sock: os.socket_t,
    address: std.net.Address,
    send_buf: []u8,
    recv_buf: []u8,
    recv_ctx: RecvWithTimeoutContext = undefined,
    allocator: *mem.Allocator,
    done: bool = false,

    fn init(allocator: *mem.Allocator, address: std.net.Address) !Client {
        const sock = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
        const send_buf = try allocator.alloc(u8, 8192);
        const recv_buf = try allocator.alloc(u8, 8192);

        return Client{
            .io = try IO.init(256, 0),
            .sock = sock,
            .address = address,
            .send_buf = send_buf,
            .recv_buf = recv_buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.send_buf);
        self.allocator.free(self.recv_buf);
        self.io.deinit();
    }

    pub fn start(self: *Client, recv_timeout_nanoseconds: u63) !void {
        defer {
            close(&self.io, self.sock) catch |err| {
                std.debug.print("failed to close socket. err={s}\n", .{@errorName(err)});
            };
            // self.done = true;
        }

        try connect(&self.io, self.sock, self.address);

        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "Hello from client!\n", .{}) catch unreachable;
        const sent = try send(&self.io, self.sock, fbs.getWritten());
        std.debug.print("Sent:     {s}", .{self.send_buf[0..sent]});

        self.recv_ctx.client = self;
        if (recvWithTimeout(&self.io, &self.recv_ctx, self.sock, self.recv_buf, recv_timeout_nanoseconds)) |received| {
            std.debug.print("Received: {s}", .{self.recv_buf[0..received]});
        } else |err| {
            switch (err) {
                error.Canceled => std.debug.print("recv canceled.\n", .{}),
                else => std.debug.print("unexpected error from recvWithTimeout, err={s}\n", .{@errorName(err)}),
            }
        }
    }

    pub fn run(self: *Client) !void {
        while (!self.done) try self.io.tick();
    }

    const ConnectContext = IoOpContext(IO.ConnectError!void);
    fn connect(io: *IO, sock: os.socket_t, address: std.net.Address) IO.ConnectError!void {
        var ctx: ConnectContext = undefined;
        var completion: IO.Completion = undefined;
        io.connect(*ConnectContext, &ctx, connectCallback, &completion, sock, address);
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result;
    }
    fn connectCallback(
        ctx: *ConnectContext,
        completion: *IO.Completion,
        result: IO.ConnectError!void,
    ) void {
        ctx.result = result;
        resume ctx.frame;
    }

    const SendContext = IoOpContext(IO.SendError!usize);
    fn send(io: *IO, sock: os.socket_t, buffer: []const u8) IO.SendError!usize {
        var ctx: SendContext = undefined;
        var completion: IO.Completion = undefined;
        io.send(
            *SendContext,
            &ctx,
            sendCallback,
            &completion,
            sock,
            buffer,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result;
    }
    fn sendCallback(
        ctx: *SendContext,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        ctx.result = result;
        resume ctx.frame;
    }

    const RecvContext = IoOpContext(IO.RecvError!usize);
    fn recv(io: *IO, sock: os.socket_t, buffer: []u8) IO.RecvError!usize {
        var ctx: RecvContext = undefined;
        var completion: IO.Completion = undefined;
        io.recv(
            *RecvContext,
            &ctx,
            recvCallback,
            &completion,
            sock,
            buffer,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result;
    }
    fn recvCallback(
        ctx: *RecvContext,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        ctx.result = result;
        resume ctx.frame;
    }

    const RecvWithTimeoutContext = struct {
        recv_completion: IO.Completion = undefined,
        timeout_completion: IO.Completion = undefined,
        frame: anyframe = undefined,
        result: ?IO.RecvError!usize = null,
        cancel_recv_completion: IO.Completion = undefined,
        cancel_timeout_completion: IO.Completion = undefined,
        client: *Client = null,
    };
    fn recvWithTimeout(io: *IO, ctx: *RecvWithTimeoutContext, sock: os.socket_t, buffer: []u8, timeout_nanoseconds: u63) IO.RecvError!usize {
        io.recv(
            *RecvWithTimeoutContext,
            ctx,
            recvWithTimeoutRecvCallback,
            &ctx.recv_completion,
            sock,
            buffer,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        io.timeout(
            *RecvWithTimeoutContext,
            ctx,
            recvWithTimeoutTimeoutCallback,
            &ctx.timeout_completion,
            timeout_nanoseconds,
        );
        std.debug.print("submitted recv and timeout.\n", .{});
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result.?;
    }
    fn recvWithTimeoutRecvCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        if (ctx.result) |_| {} else {
            completion.io.cancelTimeout(
                *RecvWithTimeoutContext,
                ctx,
                recvWithTimeoutCancelTimeoutCallback,
                &ctx.cancel_timeout_completion,
                &ctx.timeout_completion,
            );
            ctx.result = result;
            std.debug.print("resume frame after recv.\n", .{});
            resume ctx.frame;
        }
    }
    fn recvWithTimeoutTimeoutCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        if (ctx.result) |_| {} else {
            completion.io.cancel(
                *RecvWithTimeoutContext,
                ctx,
                recvWithTimeoutCancelRecvCallback,
                &ctx.cancel_recv_completion,
                &ctx.recv_completion,
            );
            ctx.result = error.Canceled;
            std.debug.print("resume frame after timeout.\n", .{});
            resume ctx.frame;
        }
    }
    fn recvWithTimeoutCancelRecvCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.CancelError!void,
    ) void {
        std.debug.print("recvWithTimeoutCancelRecvCallback start\n", .{});
        ctx.client.done = true;
        if (result) |_| {} else |err| {
            switch (err) {
                error.AlreadyInProgress, error.NotFound => {
                    std.debug.print("recv op canceled, err={s}\n", .{@errorName(err)});
                },
                else => @panic(@errorName(err)),
            }
        }
    }
    fn recvWithTimeoutCancelTimeoutCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.CancelTimeoutError!void,
    ) void {
        std.debug.print("recvWithTimeoutCancelTimeoutCallback start\n", .{});
        ctx.client.done = true;
        if (result) |_| {} else |err| {
            switch (err) {
                error.AlreadyInProgress, error.NotFound, error.Canceled => {
                    std.debug.print("timeout op canceled, err={s}\n", .{@errorName(err)});
                },
                else => @panic(@errorName(err)),
            }
        }
    }

    const CloseContext = IoOpContext(IO.CloseError!void);
    fn close(io: *IO, sock: os.socket_t) IO.CloseError!void {
        var ctx: CloseContext = undefined;
        var completion: IO.Completion = undefined;
        io.close(
            *CloseContext,
            &ctx,
            closeCallback,
            &completion,
            sock,
        );
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result;
    }
    fn closeCallback(
        ctx: *CloseContext,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        ctx.result = result;
        resume ctx.frame;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    var client = try Client.init(allocator, address);
    defer client.deinit();

    var recv_timeout: u63 = 500 * std.time.ns_per_ms;
    var args = std.process.args();
    if (args.nextPosix()) |_| {
        if (args.nextPosix()) |arg| {
            if (std.fmt.parseInt(u63, arg, 10)) |v| {
                recv_timeout = v * std.time.ns_per_ms;
            } else |_| {}
        }
    }
    std.debug.print("recv_timeout={d} ms.\n", .{recv_timeout / time.ns_per_ms});

    _ = async client.start(recv_timeout);
    try client.run();
}
