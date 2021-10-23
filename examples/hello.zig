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
        fd: os.fd_t,

        write_buf: []const u8 = "Hello world\n",

        written: usize = 0,

        fn hello() !void {
            var self: Context = .{
                .io = try IO.init(32, 0),
                .fd = std.io.getStdOut().handle,
            };
            defer self.io.deinit();

            var completion: IO.Completion = undefined;

            self.io.write(
                *Context,
                &self,
                write_callback,
                &completion,
                self.fd,
                self.write_buf,
                0,
            );
            while (!self.done) try self.io.tick();
        }

        fn write_callback(
            self: *Context,
            _: *IO.Completion,
            result: IO.WriteError!usize,
        ) void {
            self.written = result catch @panic("write error");
            self.done = true;
        }
    }.hello();
}
