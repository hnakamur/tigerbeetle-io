const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const time = std.time;
const IO = @import("tigerbeetle-io").IO;

const ClientHandler = struct {
    io: *IO,
    sock: os.socket_t,
    delay_ns: u63,
    recv_buf: []u8,
    received: usize = 0,
    allocator: mem.Allocator,
    completion: IO.Completion,

    fn init(allocator: mem.Allocator, io: *IO, sock: os.socket_t, delay_ns: u63) !*ClientHandler {
        var buf = try allocator.alloc(u8, 1024);
        var self = try allocator.create(ClientHandler);
        self.* = ClientHandler{
            .io = io,
            .sock = sock,
            .delay_ns = delay_ns,
            .recv_buf = buf,
            .allocator = allocator,
            .completion = undefined,
        };
        return self;
    }

    fn deinit(self: *ClientHandler) !void {
        self.allocator.free(self.recv_buf);
        self.allocator.destroy(self);
    }

    fn start(self: *ClientHandler) !void {
        self.recv();
    }

    fn recv(self: *ClientHandler) void {
        self.io.recv(
            *ClientHandler,
            self,
            recvCallback,
            &self.completion,
            self.sock,
            self.recv_buf,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
    }

    fn recvCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        self.received = result catch @panic("recv error");
        if (self.received == 0) {
            self.io.close(
                *ClientHandler,
                self,
                closeCallback,
                completion,
                self.sock,
            );
            return;
        }
        self.io.timeout(
            *ClientHandler,
            self,
            timeoutCallback,
            completion,
            self.delay_ns,
        );
    }

    fn timeoutCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        self.io.send(
            *ClientHandler,
            self,
            sendCallback,
            completion,
            self.sock,
            self.recv_buf[0..self.received],
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
    }

    fn sendCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        _ = result catch @panic("send error");
        self.recv();
    }

    fn closeCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        _ = result catch @panic("close error");
        self.deinit() catch @panic("ClientHandler deinit error");
    }
};

const Server = struct {
    io: IO,
    server: os.socket_t,
    delay_ns: u63,
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator, address: std.net.Address, delay_ns: u63) !Server {
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
            .delay_ns = delay_ns,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Server) void {
        os.close(self.server);
        self.io.deinit();
    }

    pub fn run(self: *Server) !void {
        var server_completion: IO.Completion = undefined;
        self.io.accept(*Server, self, acceptCallback, &server_completion, self.server, 0);
        while (true) try self.io.tick();
    }

    fn acceptCallback(
        self: *Server,
        completion: *IO.Completion,
        result: IO.AcceptError!os.socket_t,
    ) void {
        const accepted_sock = result catch @panic("accept error");
        var handler = ClientHandler.init(self.allocator, &self.io, accepted_sock, self.delay_ns) catch @panic("handler create error");
        handler.start() catch @panic("handler");
        self.io.accept(*Server, self, acceptCallback, completion, self.server, 0);
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);

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

    var server = try Server.init(allocator, address, delay);
    defer server.deinit();

    try server.run();
}
