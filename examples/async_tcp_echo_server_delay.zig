const std = @import("std");
const mem = std.mem;
const net = std.net;
const time = std.time;
const os = std.os;
const IO = @import("tigerbeetle-io").IO;

fn IoOpContext(comptime ResultType: type) type {
    return struct {
        frame: anyframe = undefined,
        result: ResultType = undefined,
    };
}

const ClientHandler = struct {
    io: *IO,
    sock: os.socket_t,
    recv_buf: []u8,
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator, io: *IO, sock: os.socket_t) !*ClientHandler {
        var buf = try allocator.alloc(u8, 1024);
        var self = try allocator.create(ClientHandler);
        self.* = ClientHandler{
            .io = io,
            .sock = sock,
            .recv_buf = buf,
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *ClientHandler) !void {
        try close(self.io, self.sock);
        self.allocator.free(self.recv_buf);
        self.allocator.destroy(self);
    }

    fn start(self: *ClientHandler, delay_nanoseconds: u63) !void {
        defer self.deinit() catch unreachable; // TODO: log error

        while (true) {
            const received = try recv(self.io, self.sock, self.recv_buf);
            if (received == 0) {
                return;
            }

            _ = try timeout(self.io, delay_nanoseconds);
            _ = try send(self.io, self.sock, self.recv_buf[0..received]);
        }
    }

    const SendContext = IoOpContext(IO.SendError!usize);
    fn send(io: *IO, sock: os.socket_t, buffer: []const u8) IO.SendError!usize {
        var ctx: IoOpContext(IO.SendError!usize) = undefined;
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

    const TimeoutContext = IoOpContext(IO.TimeoutError!void);
    fn timeout(io: *IO, nanoseconds: u63) IO.TimeoutError!void {
        var ctx: TimeoutContext = undefined;
        var completion: IO.Completion = undefined;
        io.timeout(
            *TimeoutContext,
            &ctx,
            timeoutCallback,
            &completion,
            nanoseconds,
        );
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result;
    }
    fn timeoutCallback(
        ctx: *TimeoutContext,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        ctx.result = result;
        resume ctx.frame;
    }
};

const Server = struct {
    io: IO,
    server: os.socket_t,
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator, address: std.net.Address) !Server {
        const kernel_backlog = 1;
        const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);

        try os.setsockopt(
            server,
            os.SOL_SOCKET,
            os.SO_REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        try os.bind(server, &address.any, address.getOsSockLen());
        try os.listen(server, kernel_backlog);

        var self: Server = .{
            .io = try IO.init(32, 0),
            .server = server,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Server) void {
        os.close(self.server);
        self.io.deinit();
    }

    pub fn start(self: *Server, delay_nanoseconds: u63) !void {
        while (true) {
            const client_sock = try accept(&self.io, self.server, 0);
            var handler = try ClientHandler.init(self.allocator, &self.io, client_sock);
            try handler.start(delay_nanoseconds);
        }
    }

    pub fn run(self: *Server) !void {
        while (true) try self.io.tick();
    }

    const AcceptContext = IoOpContext(IO.AcceptError!os.socket_t);
    fn accept(io: *IO, server_sock: os.socket_t, flags: u32) IO.AcceptError!os.socket_t {
        var ctx: AcceptContext = undefined;
        var completion: IO.Completion = undefined;
        io.accept(*AcceptContext, &ctx, acceptCallback, &completion, server_sock, flags);
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result;
    }
    fn acceptCallback(
        ctx: *AcceptContext,
        completion: *IO.Completion,
        result: IO.AcceptError!os.socket_t,
    ) void {
        ctx.result = result;
        resume ctx.frame;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);

    var server = try Server.init(allocator, address);
    defer server.deinit();

    var delay: u63 = std.time.ns_per_s;
    var args = std.process.args();
    if (args.nextPosix()) |_| {
        if (args.nextPosix()) |arg| {
            if (std.fmt.parseInt(u63, arg, 10)) |v| {
                delay = v * std.time.ns_per_ms;
            } else |_| {}
        }
    }
    std.debug.print("delay={d} ms.\n", .{delay / time.ns_per_ms});

    _ = async server.start(delay);
    try server.run();
}
