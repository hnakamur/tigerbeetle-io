const std = @import("std");
const os = std.os;
const IO_Uring = linux.IO_Uring;
const io_uring_sqe = linux.io_uring_sqe;

pub fn recvmsg(
    self: *IO_Uring,
    user_data: u64,
    fd: os.fd_t,
    msg: *os.msghdr,
    flags: u32,
) !*io_uring_sqe {
    const sqe = try self.get_sqe();
    io_uring_prep_recvmsg(sqe, fd, msg, flags);
    sqe.user_data = user_data;
    return sqe;
}

pub fn sendmsg(
    self: *IO_Uring,
    user_data: u64,
    fd: os.fd_t,
    msg: *const os.msghdr_const,
    flags: u32,
) !*io_uring_sqe {
    const sqe = try self.get_sqe();
    io_uring_prep_sendmsg(sqe, fd, msg, flags);
    sqe.user_data = user_data;
    return sqe;
}

pub fn io_uring_prep_recvmsg(
    sqe: *io_uring_sqe,
    fd: os.fd_t,
    msg: *os.msghdr,
    flags: u32,
) void {
    linux.io_uring_prep_rw(.RECVMSG, sqe, fd, msg, 1, 0);
    sqe.rw_flags = flags;
}

pub fn io_uring_prep_sendmsg(
    sqe: *io_uring_sqe,
    fd: os.fd_t,
    msg: *const os.msghdr_const,
    flags: u32,
) void {
    linux.io_uring_prep_rw(.SENDMSG, sqe, fd, msg, 1, 0);
    sqe.rw_flags = flags;
}

const testing = std.testing;
const builtin = std.builtin;
const linux = os.linux;
const mem = std.mem;
const net = std.net;

test "sendmsg/recvmsg" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(2, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    const address_server = try net.Address.parseIp4("127.0.0.1", 3131);

    const server = try os.socket(address_server.any.family, os.SOCK_DGRAM, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL_SOCKET, os.SO_REUSEPORT, &mem.toBytes(@as(c_int, 1)));
    try os.setsockopt(server, os.SOL_SOCKET, os.SO_REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address_server.any, address_server.getOsSockLen());

    const client = try os.socket(address_server.any.family, os.SOCK_DGRAM, 0);
    defer os.close(client);

    const buffer_send = [_]u8{42} ** 128;
    var iovecs_send = [_]os.iovec_const{
        os.iovec_const{ .iov_base = &buffer_send, .iov_len = buffer_send.len },
    };
    const msg_send = os.msghdr_const{
        .msg_name = &address_server.any,
        .msg_namelen = address_server.getOsSockLen(),
        .msg_iov = &iovecs_send,
        .msg_iovlen = 1,
        .msg_control = null,
        .msg_controllen = 0,
        .msg_flags = 0,
    };
    const sqe_sendmsg = try sendmsg(&ring, 0x11111111, client, &msg_send, 0);
    sqe_sendmsg.flags |= linux.IOSQE_IO_LINK;
    try testing.expectEqual(linux.IORING_OP.SENDMSG, sqe_sendmsg.opcode);
    try testing.expectEqual(client, sqe_sendmsg.fd);

    var buffer_recv = [_]u8{0} ** 128;
    var iovecs_recv = [_]os.iovec{
        os.iovec{ .iov_base = &buffer_recv, .iov_len = buffer_recv.len },
    };
    var addr = [_]u8{0} ** 4;
    var address_recv = net.Address.initIp4(addr, 0);
    var msg_recv: os.msghdr = os.msghdr{
        .msg_name = &address_recv.any,
        .msg_namelen = address_recv.getOsSockLen(),
        .msg_iov = &iovecs_recv,
        .msg_iovlen = 1,
        .msg_control = null,
        .msg_controllen = 0,
        .msg_flags = 0,
    };
    const sqe_recvmsg = try recvmsg(&ring, 0x22222222, server, &msg_recv, 0);
    try testing.expectEqual(linux.IORING_OP.RECVMSG, sqe_recvmsg.opcode);
    try testing.expectEqual(server, sqe_recvmsg.fd);

    try testing.expectEqual(@as(u32, 2), ring.sq_ready());
    try testing.expectEqual(@as(u32, 2), try ring.submit_and_wait(2));
    try testing.expectEqual(@as(u32, 0), ring.sq_ready());
    try testing.expectEqual(@as(u32, 2), ring.cq_ready());

    const cqe_sendmsg = try ring.copy_cqe();
    if (cqe_sendmsg.res == -linux.EINVAL) return error.SkipZigTest;
    try testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0x11111111,
        .res = buffer_send.len,
        .flags = 0,
    }, cqe_sendmsg);

    const cqe_recvmsg = try ring.copy_cqe();
    if (cqe_recvmsg.res == -linux.EINVAL) return error.SkipZigTest;
    try testing.expectEqual(linux.io_uring_cqe{
        .user_data = 0x22222222,
        .res = buffer_recv.len,
        .flags = 0,
    }, cqe_recvmsg);

    try testing.expectEqualSlices(u8, buffer_send[0..buffer_recv.len], buffer_recv[0..]);
}
