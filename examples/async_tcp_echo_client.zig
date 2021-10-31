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
    allocator: *mem.Allocator,
    frame: anyframe = undefined,
    connect_result: IO.ConnectError!void = undefined,
    send_result: IO.SendError!usize = undefined,
    recv_result: IO.RecvError!usize = undefined,
    close_result: IO.CloseError!void = undefined,
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

    pub fn start(self: *Client) !void {
        try self.connect(self.sock, self.address);

        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "Hello from client!\n", .{}) catch unreachable;
        const sent = try self.send(self.sock, fbs.getWritten());
        std.debug.print("Sent:     {s}", .{self.send_buf[0..sent]});

        const received = try self.recv(self.sock, self.recv_buf);
        std.debug.print("Received: {s}", .{self.recv_buf[0..received]});

        try self.close(self.sock);
        self.done = true;
    }

    pub fn run(self: *Client) !void {
        while (!self.done) try self.io.tick();
    }

    fn connect(self: *Client, sock: os.socket_t, address: std.net.Address) IO.ConnectError!void {
        var completion: IO.Completion = undefined;
        self.io.connect(*Client, self, connectCallback, &completion, sock, address);
        suspend {
            self.frame = @frame();
        }
        return self.connect_result;
    }
    fn connectCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.ConnectError!void,
    ) void {
        self.connect_result = result;
        resume self.frame;
    }

    fn send(self: *Client, sock: os.socket_t, buffer: []const u8) IO.SendError!usize {
        var completion: IO.Completion = undefined;
        self.io.send(
            *Client,
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
        self: *Client,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        self.send_result = result;
        resume self.frame;
    }

    fn recv(self: *Client, sock: os.socket_t, buffer: []u8) IO.RecvError!usize {
        var completion: IO.Completion = undefined;
        self.io.recv(
            *Client,
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
        self: *Client,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        self.recv_result = result;
        resume self.frame;
    }

    fn close(self: *Client, sock: os.socket_t) IO.CloseError!void {
        var completion: IO.Completion = undefined;
        self.io.close(
            *Client,
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
        self: *Client,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        self.close_result = result;
        resume self.frame;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    var client = try Client.init(allocator, address);
    defer client.deinit();

    _ = async client.start();
    try client.run();
}
