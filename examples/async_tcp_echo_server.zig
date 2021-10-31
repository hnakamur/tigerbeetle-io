const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const IO = @import("tigerbeetle-io").IO;

const ClientHandler = struct {
    io: *IO,
    sock: os.socket_t,
    recv_buf: []u8,
    allocator: *mem.Allocator,
    frame: anyframe = undefined,
    send_result: IO.SendError!usize = undefined,
    recv_result: IO.RecvError!usize = undefined,
    close_result: IO.CloseError!void = undefined,

    fn init(allocator: *mem.Allocator, io: *IO, sock: os.socket_t) !*ClientHandler {
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
        try self.close(self.sock);
        self.allocator.free(self.recv_buf);
        self.allocator.destroy(self);
    }

    fn start(self: *ClientHandler) !void {
        defer self.deinit() catch unreachable; // TODO: log error

        while (true) {
            const received = try self.recv(self.sock, self.recv_buf);
            if (received == 0) {
                return;
            }

            _ = try self.send(self.sock, self.recv_buf[0..received]);
        }
    }

    fn send(self: *ClientHandler, sock: os.socket_t, buffer: []const u8) IO.SendError!usize {
        var completion: IO.Completion = undefined;
        self.io.send(
            *ClientHandler,
            self,
            sendCallback,
            &completion,
            self.sock,
            buffer,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        suspend {
            self.frame = @frame();
        }
        return self.send_result;
    }
    fn sendCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        self.send_result = result;
        resume self.frame;
    }

    fn recv(self: *ClientHandler, sock: os.socket_t, buffer: []u8) IO.RecvError!usize {
        var completion: IO.Completion = undefined;
        self.io.recv(
            *ClientHandler,
            self,
            recvCallback,
            &completion,
            self.sock,
            buffer,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        suspend {
            self.frame = @frame();
        }
        return self.recv_result;
    }
    fn recvCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        self.recv_result = result;
        resume self.frame;
    }

    fn close(self: *ClientHandler, sock: os.socket_t) IO.CloseError!void {
        var completion: IO.Completion = undefined;
        self.io.close(
            *ClientHandler,
            self,
            closeCallback,
            &completion,
            self.sock,
        );
        suspend {
            self.frame = @frame();
        }
        return self.close_result;
    }
    fn closeCallback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        self.close_result = result;
        resume self.frame;
    }
};

const Server = struct {
    io: IO,
    server: os.socket_t,
    allocator: *mem.Allocator,
    frame: anyframe = undefined,
    accept_result: IO.AcceptError!os.socket_t = undefined,

    fn init(allocator: *mem.Allocator, address: std.net.Address) !Server {
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

    pub fn start(self: *Server) !void {
        while (true) {
            const client_sock = try self.accept(self.server, 0);
            var handler = try ClientHandler.init(self.allocator, &self.io, client_sock);
            try handler.start();
        }
    }

    pub fn run(self: *Server) !void {
        while (true) try self.io.tick();
    }

    fn accept(self: *Server, server_sock: os.socket_t, flags: u32) IO.AcceptError!os.socket_t {
        var completion: IO.Completion = undefined;
        self.io.accept(*Server, self, accept_callback, &completion, server_sock, flags);
        suspend {
            self.frame = @frame();
        }
        return self.accept_result;
    }
    fn accept_callback(
        self: *Server,
        completion: *IO.Completion,
        result: IO.AcceptError!os.socket_t,
    ) void {
        self.accept_result = result;
        resume self.frame;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    var server = try Server.init(allocator, address);
    defer server.deinit();

    _ = async server.start();
    try server.run();
}
