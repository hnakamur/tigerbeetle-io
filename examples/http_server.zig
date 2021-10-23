const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const IO = @import("tigerbeetle-io").IO;
const http = @import("tigerbeetle-io").http;
const datetime = @import("datetime");

const ClientHandler = struct {
    io: *IO,
    sock: os.socket_t,
    recv_buf: []u8,
    send_buf: []u8,
    allocator: *mem.Allocator,
    completion: IO.Completion = undefined,
    request: http.Request = undefined,
    response: http.Response = undefined,
    keep_alive: bool = true,

    fn init(allocator: *mem.Allocator, io: *IO, sock: os.socket_t) !*ClientHandler {
        const recv_buf = try allocator.alloc(u8, 8192);
        const send_buf = try allocator.alloc(u8, 8192);
        var self = try allocator.create(ClientHandler);
        self.* = ClientHandler{
            .io = io,
            .sock = sock,
            .recv_buf = recv_buf,
            .send_buf = send_buf,
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *ClientHandler) !void {
        self.allocator.free(self.send_buf);
        self.allocator.free(self.recv_buf);
        self.allocator.destroy(self);
    }

    fn start(self: *ClientHandler) !void {
        self.io.recv(
            *ClientHandler,
            self,
            recv_callback,
            &self.completion,
            self.sock,
            self.recv_buf,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
    }

    fn recv_callback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        const received = result catch @panic("recv error");
        if (received == 0) {
            self.io.close(
                *ClientHandler,
                self,
                close_callback,
                completion,
                self.sock,
            );
            return;
        }

        if (http.Request.parseBuf(self.recv_buf[0..received])) |req| {
            self.request = req;
            self.response = http.Response{
                        .version = .Http11,
                .status_code = 200,
                .status_text = "OK",
                .body = "Hello from my HTTP server\n",
            };
            switch (self.request.version) {
                // TODO: Handle connection request header.
                .Http09, .Http10 => {
                    self.response.version = self.request.version;
                    self.keep_alive = false;
                },
                else => {},
            }
        } else |err| {
            self.keep_alive = false;
            switch (err) {
                http.RequestLineParseError.UriTooLong => {
                    self.response = http.Response{
                        .version = .Http11,
                        .status_code = 414,
                        .status_text = "URI Too Long",
                        .body = "",
                    };
                },
                http.RequestLineParseError.BadRequest => {
                    self.response = http.Response{
                        .version = .Http11,
                        .status_code = 400,
                        .status_text = "Bad Request",
                        .body = "",
                    };
                },
            }
        }
        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "{s} {d} {s}\r\n", .{
            self.response.version.to_bytes(),
            self.response.status_code,
            self.response.status_text,
        }) catch unreachable;
        var now = datetime.datetime.Datetime.now();
        std.fmt.format(w, "Date: {s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {s}\r\n", .{
            now.date.weekdayName()[0..3],
            now.date.day,
            now.date.monthName()[0..3],
            now.date.year,
            now.time.hour,
            now.time.minute,
            now.time.second,
            now.zone.name,
        }) catch unreachable;

        if (self.keep_alive) {
            if (self.request.version == .Http10) {
                std.fmt.format(w, "Connection: keep-alive\r\n", .{}) catch unreachable;
            }
        } else {
            std.fmt.format(w, "Connection: close\r\n", .{}) catch unreachable;
        }
        std.fmt.format(w, "Content-Length: {d}\r\n", .{self.response.body.len}) catch unreachable;
        std.fmt.format(w, "\r\n", .{}) catch unreachable;
        if (self.response.body.len > 0) {
            std.fmt.format(w, "{s}", .{self.response.body}) catch unreachable;
        }
        self.io.send(
            *ClientHandler,
            self,
            send_callback,
            completion,
            self.sock,
            fbs.getWritten(),
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
    }

    fn send_callback(
        self: *ClientHandler,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        _ = result catch @panic("send error");
        if (self.keep_alive) {
            self.io.recv(
                *ClientHandler,
                self,
                recv_callback,
                completion,
                self.sock,
                self.recv_buf,
                if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        } else {
            self.io.close(
                *ClientHandler,
                self,
                close_callback,
                completion,
                self.sock,
            );
        }
    }

    fn close_callback(
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
    allocator: *mem.Allocator,

    fn init(allocator: *mem.Allocator, address: std.net.Address) !Server {
        const kernel_backlog = 513;
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
            .io = try IO.init(256, 0),
            .server = server,
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
        self.io.accept(*Server, self, accept_callback, &server_completion, self.server, 0);
        while (true) try self.io.tick();
    }

    fn accept_callback(
        self: *Server,
        completion: *IO.Completion,
        result: IO.AcceptError!os.socket_t,
    ) void {
        const accepted_sock = result catch @panic("accept error");
        var handler = ClientHandler.init(self.allocator, &self.io, accepted_sock) catch @panic("handler create error");
        handler.start() catch @panic("handler");
        self.io.accept(*Server, self, accept_callback, completion, self.server, 0);
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    var server = try Server.init(allocator, address);
    defer server.deinit();
    try server.run();
}
