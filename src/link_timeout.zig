const std = @import("std");
const testing = std.testing;
const builtin = std.builtin;
const mem = std.mem;
const time = std.time;
const net = std.net;
const os = std.os;
const linux = os.linux;
const IO_Uring = linux.IO_Uring;
const io_uring_sqe = linux.io_uring_sqe;

pub fn link_timeout(
    self: *IO_Uring,
    user_data: u64,
    ts: *const os.__kernel_timespec,
    flags: u32,
) !*io_uring_sqe {
    const sqe = try self.get_sqe();
    io_uring_prep_link_timeout(sqe, ts, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `poll(2)`.
/// Returns a pointer to the SQE.
pub fn poll_add(
    self: *IO_Uring,
    user_data: u64,
    fd: os.fd_t,
    poll_mask: u32,
) !*io_uring_sqe {
    const sqe = try self.get_sqe();
    io_uring_prep_poll_add(sqe, fd, poll_mask);
    sqe.user_data = user_data;
    return sqe;
}

pub fn io_uring_prep_link_timeout(
    sqe: *io_uring_sqe,
    ts: *const os.__kernel_timespec,
    flags: u32,
) void {
    linux.io_uring_prep_rw(.LINK_TIMEOUT, sqe, -1, ts, 1, 0);
    sqe.rw_flags = flags;
}

pub fn io_uring_prep_poll_add(
    sqe: *io_uring_sqe,
    fd: os.fd_t,
    poll_mask: u32,
) void {
    linux.io_uring_prep_rw(.POLL_ADD, sqe, fd, @as(?*c_void, null), 0, 0);
    sqe.rw_flags = std.mem.nativeToLittle(u32, poll_mask);
}

test "timeout_link_chain1" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    var buffer = [_]u8{0} ** 128;
    const iovecs = [_]os.iovec{os.iovec{ .iov_base = &buffer, .iov_len = buffer.len }};
    const sqe_readv = try ring.readv(0x11111111, fds[0], &iovecs, 0);
    sqe_readv.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 0, .tv_nsec = 1000000 };
    const seq_link_timeout = try link_timeout(&ring, 0x22222222, &ts, 0);
    seq_link_timeout.flags |= linux.IOSQE_IO_LINK;

    const seq_nop = try ring.nop(0x33333333);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 3), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            // poll cancel really should return -ECANCEL...
            0x11111111 => {
                if (cqe.res != -linux.EINTR and cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                // FASTPOLL kernels can cancel successfully
                if (cqe.res != -linux.EALREADY and cqe.res != -linux.ETIME) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x33333333 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

test "timeout_link_chain2" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    const sqe_poll_add = try poll_add(&ring, 0x11111111, fds[0], os.POLLIN);
    sqe_poll_add.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 0, .tv_nsec = 1000000 };
    const seq_link_timeout = try link_timeout(&ring, 0x22222222, &ts, 0);
    seq_link_timeout.flags |= linux.IOSQE_IO_LINK;

    const seq_nop = try ring.nop(0x33333333);
    seq_nop.flags |= linux.IOSQE_IO_LINK;

    _ = try ring.nop(0x44444444);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 4), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.ETIME) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x33333333, 0x44444444 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

test "timeout_link_chain3" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    const sqe_poll_add = try poll_add(&ring, 0x11111111, fds[0], os.POLLIN);
    sqe_poll_add.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 0, .tv_nsec = 1000000 };
    const seq_link_timeout = try link_timeout(&ring, 0x22222222, &ts, 0);
    seq_link_timeout.flags |= linux.IOSQE_IO_LINK;

    const seq_nop = try ring.nop(0x33333333);
    seq_nop.flags |= linux.IOSQE_IO_LINK;

    // POLL -> TIMEOUT -> NOP

    const sqe_poll_add2 = try poll_add(&ring, 0x44444444, fds[0], os.POLLIN);
    sqe_poll_add2.flags |= linux.IOSQE_IO_LINK;

    const ts2 = os.__kernel_timespec{ .tv_sec = 0, .tv_nsec = 1000000 };
    _ = try link_timeout(&ring, 0x55555555, &ts2, 0);

    // poll on pipe + timeout

    _ = try ring.nop(0x66666666);

    // nop

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 6), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x22222222 => {
                if (cqe.res != -linux.ETIME) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x11111111, 0x33333333, 0x44444444, 0x55555555 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x66666666 => {
                if (cqe.res != 0) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

test "timeout_link_chain4" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    const sqe_nop = try ring.nop(0x11111111);
    sqe_nop.flags |= linux.IOSQE_IO_LINK;

    const sqe_poll_add = try poll_add(&ring, 0x22222222, fds[0], os.POLLIN);
    sqe_poll_add.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 0, .tv_nsec = 1000000 };
    _ = try link_timeout(&ring, 0x33333333, &ts, 0);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 3), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            // poll cancel really should return -ECANCEL...
            0x11111111 => {
                if (cqe.res != 0) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x33333333 => {
                if (cqe.res != -linux.ETIME) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

test "timeout_link_chain5" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    const sqe_nop = try ring.nop(0x11111111);
    sqe_nop.flags |= linux.IOSQE_IO_LINK;

    const ts1 = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    const sqe_link_timeout = try link_timeout(&ring, 0x22222222, &ts1, 0);
    sqe_link_timeout.flags |= linux.IOSQE_IO_LINK;

    const ts2 = os.__kernel_timespec{ .tv_sec = 2, .tv_nsec = 0 };
    _ = try link_timeout(&ring, 0x33333333, &ts2, 0);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 3), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111, 0x22222222 => {
                if (cqe.res != 0 and cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x33333333 => {
                if (cqe.res != -linux.ECANCELED and cqe.res != -linux.EINVAL) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

fn single_link_timeout(ring: *IO_Uring, nsec: i64) !void {
    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    var buffer = [_]u8{0} ** 128;
    const iovecs = [_]os.iovec{os.iovec{ .iov_base = &buffer, .iov_len = buffer.len }};
    const sqe_readv = try ring.readv(0x11111111, fds[0], iovecs[0..], 0);
    sqe_readv.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 0, .tv_nsec = nsec };
    const seq_link_timeout = try link_timeout(ring, 0x22222222, &ts, 0);
    seq_link_timeout.flags |= linux.IOSQE_IO_LINK;

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 2), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111 => {
                if (cqe.res != -linux.EINTR and cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.EALREADY and cqe.res != -linux.ETIME and cqe.res != 0) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

test "single_link_timeout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    try single_link_timeout(&ring, 10);
    try single_link_timeout(&ring, 100000);
    try single_link_timeout(&ring, 500000000);
}

// Test read that will complete, with a linked timeout behind it
test "single_link_no_timeout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    var buffer = [_]u8{0} ** 128;
    const iovecs = [_]os.iovec{os.iovec{ .iov_base = &buffer, .iov_len = buffer.len }};
    const sqe_readv = try ring.readv(0x11111111, fds[0], &iovecs, 0);
    sqe_readv.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    _ = try link_timeout(&ring, 0x22222222, &ts, 0);

    const iovecs2 = [_]os.iovec_const{os.iovec_const{ .iov_base = &buffer, .iov_len = buffer.len }};
    _ = try ring.writev(0x33333333, fds[1], &iovecs2, 0);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 3), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111, 0x33333333 => {
                if (cqe.res != buffer.len) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

// Test read that will not complete, with a linked timeout behind it that
// has errors in the SQE
test "single_link_timeout_error" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    var buffer = [_]u8{0} ** 128;
    const iovecs = [_]os.iovec{os.iovec{ .iov_base = &buffer, .iov_len = buffer.len }};
    const sqe_readv = try ring.readv(0x11111111, fds[0], &iovecs, 0);
    sqe_readv.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    const sqe_link_timeout = try link_timeout(&ring, 0x22222222, &ts, 0);
    // set invalid field, it'll get failed
    sqe_link_timeout.ioprio = 89;

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 2), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.EINVAL) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

// Test linked timeout with NOP
test "single_link_timeout_nop" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    const sqe_nop = try ring.nop(0x11111111);
    sqe_nop.flags |= linux.IOSQE_IO_LINK;

    const ts = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    _ = try link_timeout(&ring, 0x22222222, &ts, 0);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 2), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111 => {
                if (cqe.res != 0) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

// Test linked timeout with timeout (timeoutception)
test "single_link_timeout_ception" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    var fds = try os.pipe();
    defer {
        os.close(fds[0]);
        os.close(fds[1]);
    }

    const ts = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    const sqe_timeout = try ring.timeout(0x11111111, &ts, std.math.maxInt(u32), 0);
    sqe_timeout.flags |= linux.IOSQE_IO_LINK;

    const ts2 = os.__kernel_timespec{ .tv_sec = 2, .tv_nsec = 0 };
    const sqe_link_timeout = try link_timeout(&ring, 0x22222222, &ts2, 0);

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 2), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111 => {
                // newer kernels allow timeout links
                if (cqe.res != -linux.EINVAL and cqe.res != -linux.ETIME) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}

test "fail_lone_link_timeouts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    const ts = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    const sqe_link_timeout = try link_timeout(&ring, 0x11111111, &ts, 0);
    sqe_link_timeout.flags |= linux.IOSQE_IO_LINK;

    try testing.expectEqual(@as(u32, 1), try ring.submit());

    const cqe = try ring.copy_cqe();
    try testing.expectEqual(@as(u64, 0x11111111), cqe.user_data);
    try testing.expectEqual(@as(i32, -linux.EINVAL), cqe.res);
}

test "fail_two_link_timeouts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var ring = IO_Uring.init(8, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    // sqe_1: write destined to fail
    // use buf=NULL, to do that during the issuing stage
    const sqe_writev = try ring.get_sqe();
    linux.io_uring_prep_rw(.WRITEV, sqe_writev, 0, @as(?*c_void, null), 1, 0);
    sqe_writev.flags |= linux.IOSQE_IO_LINK;
    sqe_writev.user_data = 0x11111111;

    // sqe_2: valid linked timeout
    const ts = os.__kernel_timespec{ .tv_sec = 1, .tv_nsec = 0 };
    const sqe_link_timeout = try link_timeout(&ring, 0x22222222, &ts, 0);
    sqe_link_timeout.flags |= linux.IOSQE_IO_LINK;

    // sqe_3: invalid linked timeout
    const sqe_link_timeout2 = try link_timeout(&ring, 0x33333333, &ts, 0);
    sqe_link_timeout2.flags |= linux.IOSQE_IO_LINK;

    // sqe_4: invalid linked timeout
    const sqe_link_timeout3 = try link_timeout(&ring, 0x33333333, &ts, 0);
    sqe_link_timeout3.flags |= linux.IOSQE_IO_LINK;

    const nr_wait = try ring.submit();
    try testing.expectEqual(@as(u32, 4), nr_wait);

    var i: usize = 0;
    while (i < nr_wait) : (i += 1) {
        const cqe = try ring.copy_cqe();
        switch (cqe.user_data) {
            0x11111111 => {
                if (cqe.res != -linux.EFAULT and cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x22222222 => {
                if (cqe.res != -linux.ECANCELED) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            0x33333333, 0x44444444 => {
                if (cqe.res != -linux.ECANCELED and cqe.res != -linux.EINVAL) {
                    std.debug.print("Req 0x{x} got {d}\n", .{ cqe.user_data, cqe.res });
                    try testing.expect(false);
                }
            },
            else => @panic("should not happen"),
        }
    }
}
