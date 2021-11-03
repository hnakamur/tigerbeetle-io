tigerbeetle-io
==============

An IO event loop extracted from [TigerBeetle](https://github.com/coilhq/tigerbeetle/).

- written in Zig
- uses io_uring on Linux, kqueue on macOS
- enhanced features from TigerBeetle IO
    - cancel
    - cancelTimeout
- target Zig version: 0.8.1

I wrote [a blog post](https://dev.to/hnakamur/experimenting-timeout-and-cancellation-with-zig-asyncawait-and-tigerbeetle-io-53o5) about this. (also backup at [blog.md](blog.md)).

## How to build

```bash
zig build
```

## Run Examples

### Print Hello world to stdout

```bash
./zig-out/bin/hello
```

### Callback-based TCP echo server and client

Run the server.

```bash
./zig-out/bin/tcp_echo_server
```

Run the client in another terminal.

```bash
./zig-out/bin/tcp_echo_client
```

### Async TCP echo server and client

This example is using async/await in Zig, as said in `3.` in https://github.com/ziglang/zig/issues/8224#issuecomment-800539080

> being driven by async/await in Zig by wrapping the callback into an async frame


Run the server.

```bash
./zig-out/bin/async_tcp_echo_server
```

Run the client in another terminal.

```bash
./zig-out/bin/async_tcp_echo_client
```

### Async TCP echo server and client with response delay and receive timeout

Run the server.
Specify delay in milliseconds.

```bash
./zig-out/bin/async_tcp_echo_server_deley 1000
```

Run the client in another terminal with receive timeout in milliseconds.

```bash
./zig-out/bin/async_tcp_echo_client 1100
```

output examples:

```
$ time ./zig-out/bin/async_tcp_echo_client_timeout 1100
recv_timeout=1100 ms.
Sent:     Hello from client!
submitted recv and timeout.
resume frame after recv.
Received: Hello from client!
recvWithTimeoutCancelTimeoutCallback start

real    0m1.007s
user    0m0.781s
sys     0m0.226s
```

```
$ time ./zig-out/bin/async_tcp_echo_client_timeout 900
recv_timeout=900 ms.
Sent:     Hello from client!
submitted recv and timeout.
resume frame after timeout.
recv canceled.
recvWithTimeoutCancelRecvCallback start

real    0m0.906s
user    0m0.710s
sys     0m0.194s
```
