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
        try connect(&self.io, self.sock, self.address);

        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "Hello from client!\n", .{}) catch unreachable;
        const sent = try send(&self.io, self.sock, fbs.getWritten());
        std.debug.print("Sent:     {s}", .{self.send_buf[0..sent]});

        const received = try recv(&self.io, self.sock, self.recv_buf);
        std.debug.print("Received: {s}", .{self.recv_buf[0..received]});

        try close(&self.io, self.sock);
        self.done = true;
    }

    pub fn run(self: *Client) !void {
        while (!self.done) try self.io.tick();
    }

    const ConnectContext = struct {
        frame: anyframe = undefined,
        result: IO.ConnectError!void = undefined,
    };
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

    const SendContext = struct {
        frame: anyframe = undefined,
        result: IO.SendError!usize = undefined,
    };
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

    const RecvContext = struct {
        frame: anyframe = undefined,
        result: IO.RecvError!usize = undefined,
    };
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

    const CloseContext = struct {
        frame: anyframe = undefined,
        result: IO.CloseError!void = undefined,
    };
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

    _ = async client.start();
    try client.run();
}
