const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const time = std.time;
const IO = @import("tigerbeetle-io").IO;
const http = @import("http");

const Client = struct {
    io: IO,
    sock: os.socket_t,
    address: std.net.Address,
    recv_timeout_ns: u63,
    send_buf: []u8,
    recv_buf: []u8,
    allocator: *mem.Allocator,
    completion: IO.Completion = undefined,
    recv_completion: IO.Completion = undefined,
    timeout_completion: IO.Completion = undefined,
    cancel_recv_completion: IO.Completion = undefined,
    cancel_timeout_completion: IO.Completion = undefined,
    done: bool = false,

    fn init(allocator: *mem.Allocator, address: std.net.Address, recv_timeout_ns: u63) !Client {
        const sock = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
        const send_buf = try allocator.alloc(u8, 8192);
        const recv_buf = try allocator.alloc(u8, 8192);

        return Client{
            .io = try IO.init(256, 0),
            .sock = sock,
            .address = address,
            .recv_timeout_ns = recv_timeout_ns,
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
        if (result) |_| {
            self.sendHello();
        } else |err| {
            std.debug.print("connectCallback err={s}\n", .{@errorName(err)});
            self.done = true;
        }
    }

    fn sendHello(self: *Client) void {
        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "Hello from client!\n", .{}) catch unreachable;

        self.io.send(
            *Client,
            self,
            sendCallback,
            &self.completion,
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

        self.recvWithTimeout();
    }

    fn recvWithTimeout(self: *Client) void {
        self.io.recv(
            *Client,
            self,
            recvCallback,
            &self.recv_completion,
            self.sock,
            self.recv_buf,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        self.io.timeout(
            *Client,
            self,
            timeoutCallback,
            &self.timeout_completion,
            self.recv_timeout_ns,
        );
    }
    fn recvCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        if (result) |received| {
            std.debug.print("Received: {s}", .{self.recv_buf[0..received]});
            self.io.cancelTimeout(
                *Client,
                self,
                cancelTimeoutCallback,
                &self.cancel_timeout_completion,
                &self.timeout_completion,
            );
        } else |err| {
            std.debug.print("recvCallback err={s}\n", .{@errorName(err)});
            if (err != error.Canceled) {
                @panic(@errorName(err));
            }
        }
    }
    fn timeoutCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        std.debug.print("timeoutCallback start\n", .{});
        if (result) |_| {
            completion.io.cancel(
                *Client,
                self,
                cancelRecvCallback,
                &self.cancel_recv_completion,
                &self.recv_completion,
            );
        } else |err| {
            std.debug.print("timeoutCallback err={s}\n", .{@errorName(err)});
            if (err != error.Canceled) {
                @panic(@errorName(err));
            }
        }
    }
    fn cancelRecvCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.CancelError!void,
    ) void {
        std.debug.print("cancelRecvCallback start\n", .{});
        self.close();
    }
    fn cancelTimeoutCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.CancelTimeoutError!void,
    ) void {
        std.debug.print("cancelTimeoutCallback start\n", .{});
        self.close();
    }

    fn close(self: *Client) void {
        self.io.close(
            *Client,
            self,
            closeCallback,
            &self.completion,
            self.sock,
        );
    }
    fn closeCallback(
        self: *Client,
        completion: *IO.Completion,
        result: IO.CloseError!void,
    ) void {
        std.debug.print("closeCallback start\n", .{});
        _ = result catch @panic("close error");
        self.done = true;
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);

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

    var client = try Client.init(allocator, address, recv_timeout);
    defer client.deinit();
    try client.run();
}
