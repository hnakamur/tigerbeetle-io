const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const IO = @import("tigerbeetle-io").IO;

pub fn main() anyerror!void {
    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        recv_buf: [1024]u8 = [_]u8{0} ** 1024,

        sent: usize = 0,
        received: usize = 0,

        fn run_test() !void {
            const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
            const kernel_backlog = 1;
            const server = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
            defer os.close(server);

            const client = try os.socket(address.any.family, os.SOCK_STREAM | os.SOCK_CLOEXEC, 0);
            defer os.close(client);

            try os.setsockopt(
                server,
                os.SOL_SOCKET,
                os.SO_REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try os.bind(server, &address.any, address.getOsSockLen());
            try os.listen(server, kernel_backlog);

            var self: Context = .{
                .io = try IO.init(32, 0),
                .server = server,
            };
            defer self.io.deinit();

            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server, 0);

            while (!self.done) try self.io.tick();
        }

        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            self.accepted_sock = result catch @panic("accept error");
            self.io.recv(
                *Context,
                self,
                recv_callback,
                completion,
                self.accepted_sock,
                &self.recv_buf,
                if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            self.received = result catch @panic("recv error");
            if (self.received == 0) {
                self.done = true;
                return;
            }
            self.io.send(
                *Context,
                self,
                send_callback,
                completion,
                self.accepted_sock,
                self.recv_buf[0..self.received],
                if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn send_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.SendError!usize,
        ) void {
            self.sent = result catch @panic("send error");
            self.io.recv(
                *Context,
                self,
                recv_callback,
                completion,
                self.accepted_sock,
                &self.recv_buf,
                if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }
    }.run_test();
}
