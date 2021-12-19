const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const IO = @import("tigerbeetle-io").IO;
const http = @import("http");

const Client = struct {
    io: IO,
    sock: os.socket_t,
    address: std.net.Address,
    send_buf: []u8,
    recv_buf: []u8,
    allocator: mem.Allocator,
    completion: IO.Completion = undefined,
    done: bool = false,

    fn init(allocator: mem.Allocator, address: std.net.Address) !Client {
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

    pub fn run(self: *Client) !void {
        self.io.connect(*Client, self, connectCallback, &self.completion, self.sock, self.address);
        while (!self.done) try self.io.tick();
    }

    fn connectCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.ConnectError!void,
    ) void {
        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "Hello from client!\n", .{}) catch unreachable;

        self.io.send(
            *Client,
            self,
            sendCallback,
            completion,
            self.sock,
            fbs.getWritten(),
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
    }

    fn sendCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        const sent = result catch @panic("send error");
        std.debug.print("Sent:     {s}", .{self.send_buf[0..sent]});
        self.io.recv(
            *Client,
            self,
            recvCallback,
            completion,
            self.sock,
            self.recv_buf,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
    }
    fn recvCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        const received = result catch @panic("recv error");
        std.debug.print("Received: {s}", .{self.recv_buf[0..received]});
        self.io.close(
            *Client,
            self,
            closeCallback,
            completion,
            self.sock,
        );
    }

    fn closeCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        _ = result catch @panic("close error");
        self.done = true;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    var client = try Client.init(allocator, address);
    defer client.deinit();
    try client.run();
}
