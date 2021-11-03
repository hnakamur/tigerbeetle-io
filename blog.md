---
title: Experimenting timeout and cancellation with Zig async/await and tigerbeetle-io
published: false
description: 
tags: zig
//cover_image: https://direct_url_to_image.jpg
---
After reading [Proposal: Event loop redesign · Issue #8224 · ziglang/zig](https://github.com/ziglang/zig/issues/8224), I'm really interested in the [TigerBeetle](https://github.com/coilhq/tigerbeetle) IO event loop.

Its API is designed for Linux [io_uring](https://kernel.dk/io_uring.pdf) first and it also has a wrapper for kqueue on macOS in the same API. I suppose other APIs can be wrapped in the same way as kqueue in the future.

I wrote some examples to become familiar to its API at https://github.com/hnakamur/tigerbeetle-io/

## Hello world example

Here is a "Hello world" example which prints "Hello world" to the standard output.

[examples/hello.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/hello.zig)

```zig
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
                writeCallback,
                &completion,
                self.fd,
                self.write_buf,
                0,
            );
            while (!self.done) try self.io.tick();
        }

        fn writeCallback(
            self: *Context,
            _: *IO.Completion,
            result: IO.WriteError!usize,
        ) void {
            self.written = result catch @panic("write error");
            self.done = true;
        }
    }.hello();
}
```

It submits a `write` operation with calling `self.io.write` and `writeCallback` is called when the write operation is completed.

The code for event loop is `while (!self.done) try self.io.tick();`. The loop exits after `self.done` is set to `true` in `writeCallback`.

## Callback-based TCP echo server and client

* [examples/tcp_echo_server.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/tcp_echo_server.zig)
* [examples/tcp_echo_client.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/tcp_echo_client.zig)

Here is some part from the client code.

```zig
const Client = struct {
    // ...(snip)...

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
```

* First, it submits a `connect` operation in the `run` function.
* When the `connect` operation is complete, `connectCallback` is called.
* In `connectCallback`, it handles the result of the `connect` operation. Then it submits a `recv` operation.

I think this is a pain point of the callback style.
Two things, handling the result and starting the next operation is written in one callback function.

Also the code for running one logical operation of `connect` is split in two functions, `run` and `connectCallback`.

Maybe you can use state machines to improve this situation, but I thinks they are also hard to maintain because they are very different from sequential calls of blocking code.

## async-based TCP echo server and client

* [examples/async_tcp_echo_server.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/async_tcp_echo_server.zig)
* [examples/async_tcp_echo_client.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/async_tcp_echo_client.zig)

Here is some part from the client code.

```zig
const Client = struct {
    // ...(snip)...

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

    // ...(snip)...
```

The code above looks just as sequential calls of multiple blocking IO operations. I think it is nice!
You can easily follow the flow of IO operations.

Here is the code for `connect` function.

```zig
    const ConnectContext = IoOpContext(IO.ConnectError!void);
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
```

In `connect`, it submits a `connect` operation then it suspends and saves the frame.
When the `connect` operation is complete, `connectCallback` is called and it sets the result and resumes the saved frame.

Note you can put the `ctx` and `completion` as local variables in `connect` function in the above code.
This is fine because they are valid on the stack until `connect` function exits.

This implementation follows the pattern described in the statement `3.` in the comment https://github.com/ziglang/zig/issues/8224#issuecomment-800539080.

> I feel that the cross-platform abstraction for I/O pollers in the Zig standard library should follow the proactor pattern, and that all async I/O modules have completion-based APIs (callback-based). This would allow for easy C interoperability (pass a callback), and also only requires minimal boilerplate for being driven by async/await in Zig by wrapping the callback into an async frame.

## async-based TCP echo server and client with delayed response and receive timeout

* [examples/async_tcp_echo_server_delay.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/async_tcp_echo_server_delay.zig)
* [examples/async_tcp_echo_client_timeout.zig](https://github.com/hnakamur/tigerbeetle-io/blob/main/examples/async_tcp_echo_client_timeout.zig)

The server code for a delayed response is easy.
It just calls `timeout` before `send`.

```zig
const ClientHandler = struct {
    // ...(snip)...

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

    // ...(snip)...
```

In the client code for receive time, it uses a new function `recvWithTimeout`.

```zig
const Client = struct {
    // ...(snip)...
    pub fn start(self: *Client, recv_timeout_nanoseconds: u63) !void {
        defer {
            close(&self.io, self.sock) catch |err| {
                std.debug.print("failed to close socket. err={s}\n", .{@errorName(err)});
            };
            // self.done = true;
        }

        try connect(&self.io, self.sock, self.address);

        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "Hello from client!\n", .{}) catch unreachable;
        const sent = try send(&self.io, self.sock, fbs.getWritten());
        std.debug.print("Sent:     {s}", .{self.send_buf[0..sent]});

        self.recv_ctx.client = self;
        if (recvWithTimeout(&self.io, &self.recv_ctx, self.sock, self.recv_buf, recv_timeout_nanoseconds)) |received| {
            std.debug.print("Received: {s}", .{self.recv_buf[0..received]});
        } else |err| {
            switch (err) {
                error.Canceled => std.debug.print("recv canceled.\n", .{}),
                else => std.debug.print("unexpected error from recvWithTimeout, err={s}\n", .{@errorName(err)}),
            }
        }
    }
    // ...(snip)...
```

Here is the implementation of `recvWithTimeout`.

```zig
    const RecvWithTimeoutContext = struct {
        recv_completion: IO.Completion = undefined,
        timeout_completion: IO.Completion = undefined,
        frame: anyframe = undefined,
        result: ?IO.RecvError!usize = null,
        cancel_recv_completion: IO.Completion = undefined,
        cancel_timeout_completion: IO.Completion = undefined,
        client: *Client = null,
    };
    fn recvWithTimeout(io: *IO, ctx: *RecvWithTimeoutContext, sock: os.socket_t, buffer: []u8, timeout_nanoseconds: u63) IO.RecvError!usize {
        io.recv(
            *RecvWithTimeoutContext,
            ctx,
            recvWithTimeoutRecvCallback,
            &ctx.recv_completion,
            sock,
            buffer,
            if (std.Target.current.os.tag == .linux) os.MSG_NOSIGNAL else 0,
        );
        io.timeout(
            *RecvWithTimeoutContext,
            ctx,
            recvWithTimeoutTimeoutCallback,
            &ctx.timeout_completion,
            timeout_nanoseconds,
        );
        std.debug.print("submitted recv and timeout.\n", .{});
        suspend {
            ctx.frame = @frame();
        }
        return ctx.result.?;
    }
    fn recvWithTimeoutRecvCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        if (ctx.result) |_| {} else {
            completion.io.cancelTimeout(
                *RecvWithTimeoutContext,
                ctx,
                recvWithTimeoutCancelTimeoutCallback,
                &ctx.cancel_timeout_completion,
                &ctx.timeout_completion,
            );
            ctx.result = result;
            std.debug.print("resume frame after recv.\n", .{});
            resume ctx.frame;
        }
    }
    fn recvWithTimeoutTimeoutCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.TimeoutError!void,
    ) void {
        if (ctx.result) |_| {} else {
            completion.io.cancel(
                *RecvWithTimeoutContext,
                ctx,
                recvWithTimeoutCancelRecvCallback,
                &ctx.cancel_recv_completion,
                &ctx.recv_completion,
            );
            ctx.result = error.Canceled;
            std.debug.print("resume frame after timeout.\n", .{});
            resume ctx.frame;
        }
    }
    fn recvWithTimeoutCancelRecvCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.CancelError!void,
    ) void {
        std.debug.print("recvWithTimeoutCancelRecvCallback start\n", .{});
        ctx.client.done = true;
        if (result) |_| {} else |err| {
            switch (err) {
                error.AlreadyInProgress, error.NotFound => {
                    std.debug.print("recv op canceled, err={s}\n", .{@errorName(err)});
                },
                else => @panic(@errorName(err)),
            }
        }
    }
    fn recvWithTimeoutCancelTimeoutCallback(
        ctx: *RecvWithTimeoutContext,
        completion: *IO.Completion,
        result: IO.CancelTimeoutError!void,
    ) void {
        std.debug.print("recvWithTimeoutCancelTimeoutCallback start\n", .{});
        ctx.client.done = true;
        if (result) |_| {} else |err| {
            switch (err) {
                error.AlreadyInProgress, error.NotFound, error.Canceled => {
                    std.debug.print("timeout op canceled, err={s}\n", .{@errorName(err)});
                },
                else => @panic(@errorName(err)),
            }
        }
    }
```

* `recvWithTimeout` submits two IO operations, `recv` and `timeout`, and then it saves the frame.
* If `recv` is complete before `timeout`, `recvWithTimeoutRecvCallback` is called first. It submits a cancel for the `timeout` operation, sets the result, and resumes the saved frame.
* If `timeout` is complete before `recv`, `recvWithTimeoutTimeoutCallback` is called first. It submits a cancel for the `recv` operation, sets the result, and resumes the saved frame.
* In the above example, it sets `ctx.client.done` to `true` in `recvWithTimeoutCancelRecvCallback` and `recvWithTimeoutCancelTimeoutCallback` to stop the event loop. In a practical application, there's nothing to do in those functions.

Note you need to pass `ctx: *RecvWithTimeoutContext` from outside of `recvWithTimeout` function. This is because when the first one of `recv` and `timeout` operation is completed, `recvWithTimeout` function exits and its local variables becomes invalid since the stack is overwritten by calls for other functions. The `ctx` must live longer than a call of `recvWithTimeout` function.

The code for an IO operation with a timeout is a bit long, but I think it is easy to understand. And once you wrap this as a function, its usage is fairly easy as just calling a blocking function.
