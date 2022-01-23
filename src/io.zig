const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const os = std.os;
const linux = os.linux;
const IO_Uring = linux.IO_Uring;
const io_uring_cqe = linux.io_uring_cqe;
const io_uring_sqe = linux.io_uring_sqe;
const io_uring_prep_recvmsg = @import("sendmsg.zig").io_uring_prep_recvmsg;
const io_uring_prep_sendmsg = @import("sendmsg.zig").io_uring_prep_sendmsg;

const tigerbeetle_io_log = if (false) std.log.scoped(.@"tigerbeetle-io") else blk: {
    break :blk struct {
        pub fn debug(
            comptime format: []const u8,
            args: anytype,
        ) void {
            _ = format;
            _ = args;
        }
    };
};

const FIFO = @import("fifo.zig").FIFO;
const IO_Darwin = @import("io_darwin.zig").IO;

pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Linux,
    .macos, .tvos, .watchos, .ios => IO_Darwin,
    else => @compileError("IO is not supported for platform"),
};

const IO_Linux = struct {
    ring: IO_Uring,

    /// Operations not yet submitted to the kernel and waiting on available space in the
    /// submission queue.
    unqueued: FIFO(Completion) = .{},

    /// Completions that are ready to have their callbacks run.
    completed: FIFO(Completion) = .{},

    pub fn init(entries: u12, flags: u32) !IO {
        return IO{ .ring = try IO_Uring.init(entries, flags) };
    }

    pub fn deinit(self: *IO) void {
        self.ring.deinit();
    }

    /// Pass all queued submissions to the kernel and peek for completions.
    pub fn tick(self: *IO) !void {
        // We assume that all timeouts submitted by `run_for_ns()` will be reaped by `run_for_ns()`
        // and that `tick()` and `run_for_ns()` cannot be run concurrently.
        // Therefore `timeouts` here will never be decremented and `etime` will always be false.
        var timeouts: usize = 0;
        var etime = false;

        try self.flush(0, &timeouts, &etime);
        assert(etime == false);

        // Flush any SQEs that were queued while running completion callbacks in `flush()`:
        // This is an optimization to avoid delaying submissions until the next tick.
        // At the same time, we do not flush any ready CQEs since SQEs may complete synchronously.
        // We guard against an io_uring_enter() syscall if we know we do not have any queued SQEs.
        // We cannot use `self.ring.sq_ready()` here since this counts flushed and unflushed SQEs.
        const queued = self.ring.sq.sqe_tail -% self.ring.sq.sqe_head;
        if (queued > 0) {
            try self.flush_submissions(0, &timeouts, &etime);
            assert(etime == false);
        }
    }

    /// Pass all queued submissions to the kernel and run for `nanoseconds`.
    /// The `nanoseconds` argument is a u63 to allow coercion to the i64 used
    /// in the __kernel_timespec struct.
    pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
        // We must use the same clock source used by io_uring (CLOCK_MONOTONIC) since we specify the
        // timeout below as an absolute value. Otherwise, we may deadlock if the clock sources are
        // dramatically different. Any kernel that supports io_uring will support CLOCK_MONOTONIC.
        var current_ts: os.timespec = undefined;
        os.clock_gettime(os.CLOCK.MONOTONIC, &current_ts) catch unreachable;
        // The absolute CLOCK_MONOTONIC time after which we may return from this function:
        const timeout_ts: os.linux.kernel_timespec = .{
            .tv_sec = current_ts.tv_sec,
            .tv_nsec = current_ts.tv_nsec + nanoseconds,
        };
        var timeouts: usize = 0;
        var etime = false;
        while (!etime) {
            const timeout_sqe = self.ring.get_sqe() catch blk: {
                // The submission queue is full, so flush submissions to make space:
                try self.flush_submissions(0, &timeouts, &etime);
                break :blk self.ring.get_sqe() catch unreachable;
            };
            // Submit an absolute timeout that will be canceled if any other SQE completes first:
            linux.io_uring_prep_timeout(timeout_sqe, &timeout_ts, 1, os.linux.IORING_TIMEOUT_ABS);
            timeout_sqe.user_data = 0;
            timeouts += 1;
            // The amount of time this call will block is bounded by the timeout we just submitted:
            try self.flush(1, &timeouts, &etime);
        }
        // Reap any remaining timeouts, which reference the timespec in the current stack frame.
        // The busy loop here is required to avoid a potential deadlock, as the kernel determines
        // when the timeouts are pushed to the completion queue, not us.
        while (timeouts > 0) _ = try self.flush_completions(0, &timeouts, &etime);
    }

    fn flush(self: *IO, wait_nr: u32, timeouts: *usize, etime: *bool) !void {
        // Flush any queued SQEs and reuse the same syscall to wait for completions if required:
        try self.flush_submissions(wait_nr, timeouts, etime);
        // We can now just peek for any CQEs without waiting and without another syscall:
        try self.flush_completions(0, timeouts, etime);
        // Run completions only after all completions have been flushed:
        // Loop on a copy of the linked list, having reset the list first, so that any synchronous
        // append on running a completion is executed only the next time round the event loop,
        // without creating an infinite loop.
        {
            var copy = self.completed;
            self.completed = .{};
            while (copy.pop()) |completion| completion.complete();
        }
        // Again, loop on a copy of the list to avoid an infinite loop:
        {
            var copy = self.unqueued;
            self.unqueued = .{};
            while (copy.pop()) |completion| {
                if (completion.linked) {
                    if (copy.pop()) |completion2| {
                        self.enqueueLinked(completion, completion2);
                    }
                } else {
                    self.enqueue(completion);
                }
            }
        }
    }

    fn flush_completions(self: *IO, wait_nr: u32, timeouts: *usize, etime: *bool) !void {
        var cqes: [256]io_uring_cqe = undefined;
        var wait_remaining = wait_nr;
        while (true) {
            // Guard against waiting indefinitely (if there are too few requests inflight),
            // especially if this is not the first time round the loop:
            const completed = self.ring.copy_cqes(&cqes, wait_remaining) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
            if (completed > wait_remaining) wait_remaining = 0 else wait_remaining -= completed;
            for (cqes[0..completed]) |cqe| {
                if (cqe.user_data == 0) {
                    timeouts.* -= 1;
                    // We are only done if the timeout submitted was completed due to time, not if
                    // it was completed due to the completion of an event, in which case `cqe.res`
                    // would be 0. It is possible for multiple timeout operations to complete at the
                    // same time if the nanoseconds value passed to `run_for_ns()` is very short.
                    if (-cqe.res == @enumToInt(os.E.TIME)) etime.* = true;
                    continue;
                }
                tigerbeetle_io_log.debug("flush_completion, cqe.user_data=0x{x}, res={}", .{ cqe.user_data, cqe.res });
                const completion = @intToPtr(*Completion, @intCast(usize, cqe.user_data));
                completion.result = cqe.res;
                // We do not run the completion here (instead appending to a linked list) to avoid:
                // * recursion through `flush_submissions()` and `flush_completions()`,
                // * unbounded stack usage, and
                // * confusing stack traces.
                self.completed.push(completion);
            }
            if (completed < cqes.len) break;
        }
    }

    fn flush_submissions(self: *IO, wait_nr: u32, timeouts: *usize, etime: *bool) !void {
        while (true) {
            _ = self.ring.submit_and_wait(wait_nr) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                // Wait for some completions and then try again:
                // See https://github.com/axboe/liburing/issues/281 re: error.SystemResources.
                // Be careful also that copy_cqes() will flush before entering to wait (it does):
                // https://github.com/axboe/liburing/commit/35c199c48dfd54ad46b96e386882e7ac341314c5
                error.CompletionQueueOvercommitted, error.SystemResources => {
                    try self.flush_completions(1, timeouts, etime);
                    continue;
                },
                else => return err,
            };
            break;
        }
    }

    fn enqueue(self: *IO, completion: *Completion) void {
        const sqe = self.ring.get_sqe() catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.unqueued.push(completion);
                return;
            },
        };
        completion.prep(sqe);
    }

    fn enqueueLinked(self: *IO, completion1: *Completion, completion2: *Completion) void {
        const sqe1 = self.ring.get_sqe() catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.unqueued.push(completion1);
                self.unqueued.push(completion2);
                return;
            },
        };
        const sqe2 = self.ring.get_sqe() catch |err| switch (err) {
            error.SubmissionQueueFull => {
                self.unqueued.push(completion1);
                self.unqueued.push(completion2);
                return;
            },
        };
        completion1.prep(sqe1);
        completion2.prep(sqe2);
    }

    /// This struct holds the data needed for a single io_uring operation
    pub const Completion = struct {
        io: *IO,
        result: i32 = undefined,
        next: ?*Completion = null,
        operation: Operation,
        linked: bool = false,
        // This is one of the usecases for anyopaque outside of C code and as such anyopaque will
        // be replaced with anyopaque eventually: https://github.com/ziglang/zig/issues/323
        context: ?*anyopaque,
        callback: fn (context: ?*anyopaque, completion: *Completion, result: *const anyopaque) void,

        pub fn err(self: *const Completion) os.E {
            if (self.result > -4096 and self.result < 0) {
                return @intToEnum(os.E, -self.result);
            }
            return .SUCCESS;
        }

        fn prep(completion: *Completion, sqe: *io_uring_sqe) void {
            switch (completion.operation) {
                .accept => |*op| {
                    linux.io_uring_prep_accept(
                        sqe,
                        op.socket,
                        &op.address,
                        &op.address_size,
                        op.flags,
                    );
                },
                .cancel => |*op| {
                    io_uring_prep_cancel(sqe, @as(u64, @ptrToInt(op.target_completion)), 0);
                },
                .close => |op| {
                    linux.io_uring_prep_close(sqe, op.fd);
                },
                .connect => |*op| {
                    linux.io_uring_prep_connect(
                        sqe,
                        op.socket,
                        &op.address.any,
                        op.address.getOsSockLen(),
                    );
                },
                .fsync => |op| {
                    linux.io_uring_prep_fsync(sqe, op.fd, op.flags);
                },
                .link_timeout => |*op| {
                    linux.io_uring_prep_link_timeout(sqe, &op.timespec, 0);
                },
                .openat => |op| {
                    linux.io_uring_prep_openat(sqe, op.fd, op.path, op.flags, op.mode);
                },
                .read => |op| {
                    linux.io_uring_prep_read(
                        sqe,
                        op.fd,
                        op.buffer[0..buffer_limit(op.buffer.len)],
                        op.offset,
                    );
                },
                .recv => |op| {
                    linux.io_uring_prep_recv(sqe, op.socket, op.buffer, op.flags);
                },
                .recvmsg => |op| {
                    io_uring_prep_recvmsg(sqe, op.socket, op.msg, op.flags);
                },
                .send => |op| {
                    linux.io_uring_prep_send(sqe, op.socket, op.buffer, op.flags);
                },
                .sendmsg => |op| {
                    io_uring_prep_sendmsg(sqe, op.socket, op.msg, op.flags);
                },
                .timeout => |*op| {
                    linux.io_uring_prep_timeout(sqe, &op.timespec, 0, 0);
                },
                .timeout_remove => |*op| {
                    linux.io_uring_prep_timeout_remove(sqe, @as(u64, @ptrToInt(op.timeout_completion)), 0);
                },
                .write => |op| {
                    linux.io_uring_prep_write(
                        sqe,
                        op.fd,
                        op.buffer[0..buffer_limit(op.buffer.len)],
                        op.offset,
                    );
                },
            }
            sqe.user_data = @ptrToInt(completion);
            tigerbeetle_io_log.debug("sqe.user_data=0x{x}, operation tagname={s}", .{ sqe.user_data, @tagName(completion.operation) });
            if (completion.linked) sqe.flags |= linux.IOSQE_IO_LINK;
        }

        fn complete(completion: *Completion) void {
            switch (completion.operation) {
                .accept => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.AGAIN => error.Again,
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.CANCELED => error.Canceled,
                        os.E.CONNABORTED => error.ConnectionAborted,
                        os.E.FAULT => unreachable,
                        os.E.INVAL => error.SocketNotListening,
                        os.E.MFILE => error.ProcessFdQuotaExceeded,
                        os.E.NFILE => error.SystemFdQuotaExceeded,
                        os.E.NOBUFS => error.SystemResources,
                        os.E.NOMEM => error.SystemResources,
                        os.E.NOTSOCK => error.FileDescriptorNotASocket,
                        os.E.OPNOTSUPP => error.OperationNotSupported,
                        os.E.PERM => error.PermissionDenied,
                        os.E.PROTO => error.ProtocolFailure,
                        else => |errno| os.unexpectedErrno(errno),
                    } else @intCast(os.socket_t, completion.result);
                    completion.callback(completion.context, completion, &result);
                },
                .cancel => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.ALREADY => error.AlreadyInProgress,
                        os.E.NOENT => error.NotFound,
                        else => |errno| os.unexpectedErrno(errno),
                    } else assert(completion.result == 0);
                    completion.callback(completion.context, completion, &result);
                },
                .close => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {}, // A success, see https://github.com/ziglang/zig/issues/2425
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.CANCELED => error.Canceled,
                        os.E.DQUOT => error.DiskQuota,
                        os.E.IO => error.InputOutput,
                        os.E.NOSPC => error.NoSpaceLeft,
                        else => |errno| os.unexpectedErrno(errno),
                    } else assert(completion.result == 0);
                    completion.callback(completion.context, completion, &result);
                },
                .connect => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.ACCES => error.AccessDenied,
                        os.E.ADDRINUSE => error.AddressInUse,
                        os.E.ADDRNOTAVAIL => error.AddressNotAvailable,
                        os.E.AFNOSUPPORT => error.AddressFamilyNotSupported,
                        os.E.AGAIN, os.E.INPROGRESS => error.Again,
                        os.E.ALREADY => error.OpenAlreadyInProgress,
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.CANCELED => error.Canceled,
                        os.E.CONNREFUSED => error.ConnectionRefused,
                        os.E.CONNRESET => error.ConnectionResetByPeer,
                        os.E.FAULT => unreachable,
                        os.E.ISCONN => error.AlreadyConnected,
                        os.E.NETUNREACH => error.NetworkUnreachable,
                        os.E.NOENT => error.FileNotFound,
                        os.E.NOTSOCK => error.FileDescriptorNotASocket,
                        os.E.PERM => error.PermissionDenied,
                        os.E.PROTOTYPE => error.ProtocolNotSupported,
                        os.E.TIMEDOUT => error.ConnectionTimedOut,
                        else => |errno| os.unexpectedErrno(errno),
                    } else assert(completion.result == 0);
                    completion.callback(completion.context, completion, &result);
                },
                .fsync => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.CANCELED => error.Canceled,
                        os.E.DQUOT => error.DiskQuota,
                        os.E.INVAL => error.ArgumentsInvalid,
                        os.E.IO => error.InputOutput,
                        os.E.NOSPC => error.NoSpaceLeft,
                        os.E.ROFS => error.ReadOnlyFileSystem,
                        else => |errno| os.unexpectedErrno(errno),
                    } else assert(completion.result == 0);
                    completion.callback(completion.context, completion, &result);
                },
                .link_timeout => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            // TODO: maybe we should enqueue the linked target completion
                            // just before this with linked field being set to true.
                            tigerbeetle_io_log.debug("Completion.complete 0x{x} op={s} got EINTR calling enqueue", .{ @ptrToInt(completion), @tagName(completion.operation) });
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.CANCELED => error.Canceled,
                        os.E.TIME => {}, // A success.
                        else => |errno| os.unexpectedErrno(errno),
                    } else unreachable;
                    completion.callback(completion.context, completion, &result);
                },
                .openat => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.ACCES => error.AccessDenied,
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.BUSY => error.DeviceBusy,
                        os.E.CANCELED => error.Canceled,
                        os.E.EXIST => error.PathAlreadyExists,
                        os.E.FAULT => unreachable,
                        os.E.FBIG => error.FileTooBig,
                        os.E.INVAL => error.ArgumentsInvalid,
                        os.E.ISDIR => error.IsDir,
                        os.E.LOOP => error.SymLinkLoop,
                        os.E.MFILE => error.ProcessFdQuotaExceeded,
                        os.E.NAMETOOLONG => error.NameTooLong,
                        os.E.NFILE => error.SystemFdQuotaExceeded,
                        os.E.NODEV => error.NoDevice,
                        os.E.NOENT => error.FileNotFound,
                        os.E.NOMEM => error.SystemResources,
                        os.E.NOSPC => error.NoSpaceLeft,
                        os.E.NOTDIR => error.NotDir,
                        os.E.OPNOTSUPP => error.FileLocksNotSupported,
                        os.E.OVERFLOW => error.FileTooBig,
                        os.E.PERM => error.AccessDenied,
                        os.E.AGAIN => error.Again,
                        else => |errno| os.unexpectedErrno(errno),
                    } else @intCast(os.fd_t, completion.result);
                    completion.callback(completion.context, completion, &result);
                },
                .read => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.AGAIN => error.Again,
                        os.E.BADF => error.NotOpenForReading,
                        os.E.CANCELED => error.Canceled,
                        os.E.CONNRESET => error.ConnectionResetByPeer,
                        os.E.FAULT => unreachable,
                        os.E.INVAL => error.Alignment,
                        os.E.IO => error.InputOutput,
                        os.E.ISDIR => error.IsDir,
                        os.E.NOBUFS => error.SystemResources,
                        os.E.NOMEM => error.SystemResources,
                        os.E.NXIO => error.Unseekable,
                        os.E.OVERFLOW => error.Unseekable,
                        os.E.SPIPE => error.Unseekable,
                        else => |errno| os.unexpectedErrno(errno),
                    } else @intCast(usize, completion.result);
                    completion.callback(completion.context, completion, &result);
                },
                .recv, .recvmsg => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.AGAIN => error.Again,
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.CANCELED => error.Canceled,
                        os.E.CONNREFUSED => error.ConnectionRefused,
                        os.E.FAULT => unreachable,
                        os.E.INVAL => unreachable,
                        os.E.NOMEM => error.SystemResources,
                        os.E.NOTCONN => error.SocketNotConnected,
                        os.E.NOTSOCK => error.FileDescriptorNotASocket,
                        os.E.CONNRESET => error.ConnectionResetByPeer,
                        else => |errno| os.unexpectedErrno(errno),
                    } else @intCast(usize, completion.result);
                    completion.callback(completion.context, completion, &result);
                },
                .send, .sendmsg => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            tigerbeetle_io_log.debug("Completion.complete 0x{x} op={s} got EINTR calling enqueue", .{ @ptrToInt(completion), @tagName(completion.operation) });
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.ACCES => error.AccessDenied,
                        os.E.AGAIN => error.Again,
                        os.E.ALREADY => error.FastOpenAlreadyInProgress,
                        os.E.AFNOSUPPORT => error.AddressFamilyNotSupported,
                        os.E.BADF => error.FileDescriptorInvalid,
                        os.E.CANCELED => error.Canceled,
                        os.E.CONNRESET => error.ConnectionResetByPeer,
                        os.E.DESTADDRREQ => unreachable,
                        os.E.FAULT => unreachable,
                        os.E.INVAL => unreachable,
                        os.E.ISCONN => unreachable,
                        os.E.MSGSIZE => error.MessageTooBig,
                        os.E.NOBUFS => error.SystemResources,
                        os.E.NOMEM => error.SystemResources,
                        os.E.NOTCONN => error.SocketNotConnected,
                        os.E.NOTSOCK => error.FileDescriptorNotASocket,
                        os.E.OPNOTSUPP => error.OperationNotSupported,
                        os.E.PIPE => error.BrokenPipe,
                        else => |errno| os.unexpectedErrno(errno),
                    } else @intCast(usize, completion.result);
                    completion.callback(completion.context, completion, &result);
                },
                .timeout => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.CANCELED => error.Canceled,
                        os.E.TIME => {}, // A success.
                        else => |errno| os.unexpectedErrno(errno),
                    } else unreachable;
                    completion.callback(completion.context, completion, &result);
                },
                .timeout_remove => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.CANCELED => error.Canceled,
                        os.E.BUSY => error.AlreadyInProgress,
                        os.E.NOENT => error.NotFound,
                        else => |errno| os.unexpectedErrno(errno),
                    } else assert(completion.result == 0);
                    completion.callback(completion.context, completion, &result);
                },
                .write => {
                    const result = if (completion.result < 0) switch (completion.err()) {
                        os.E.INTR => {
                            completion.io.enqueue(completion);
                            return;
                        },
                        os.E.AGAIN => error.Again,
                        os.E.BADF => error.NotOpenForWriting,
                        os.E.CANCELED => error.Canceled,
                        os.E.DESTADDRREQ => error.NotConnected,
                        os.E.DQUOT => error.DiskQuota,
                        os.E.FAULT => unreachable,
                        os.E.FBIG => error.FileTooBig,
                        os.E.INVAL => error.Alignment,
                        os.E.IO => error.InputOutput,
                        os.E.NOSPC => error.NoSpaceLeft,
                        os.E.NXIO => error.Unseekable,
                        os.E.OVERFLOW => error.Unseekable,
                        os.E.PERM => error.AccessDenied,
                        os.E.PIPE => error.BrokenPipe,
                        os.E.SPIPE => error.Unseekable,
                        else => |errno| os.unexpectedErrno(errno),
                    } else @intCast(usize, completion.result);
                    completion.callback(completion.context, completion, &result);
                },
            }
        }
    };

    pub const LinkedCompletion = struct {
        main_completion: Completion = undefined,
        linked_completion: Completion = undefined,
        main_result: ?union(enum) {
            connect: ConnectError!void,
            recv: RecvError!usize,
            send: SendError!usize,
        } = null,
        linked_result: ?TimeoutError!void = null,
    };

    /// This union encodes the set of operations supported as well as their arguments.
    const Operation = union(enum) {
        accept: struct {
            socket: os.socket_t,
            address: os.sockaddr = undefined,
            address_size: os.socklen_t = @sizeOf(os.sockaddr),
            flags: u32,
        },
        cancel: struct {
            target_completion: *Completion,
        },
        close: struct {
            fd: os.fd_t,
        },
        connect: struct {
            socket: os.socket_t,
            address: std.net.Address,
        },
        fsync: struct {
            fd: os.fd_t,
            flags: u32,
        },
        link_timeout: struct {
            timespec: os.timespec,
        },
        openat: struct {
            fd: os.fd_t,
            path: [*:0]const u8,
            flags: u32,
            mode: os.mode_t,
        },
        read: struct {
            fd: os.fd_t,
            buffer: []u8,
            offset: u64,
        },
        recv: struct {
            socket: os.socket_t,
            buffer: []u8,
            flags: u32,
        },
        recvmsg: struct {
            socket: os.socket_t,
            msg: *os.msghdr,
            flags: u32,
        },
        send: struct {
            socket: os.socket_t,
            buffer: []const u8,
            flags: u32,
        },
        sendmsg: struct {
            socket: os.socket_t,
            msg: *const os.msghdr_const,
            flags: u32,
        },
        timeout: struct {
            timespec: os.timespec,
        },
        timeout_remove: struct {
            timeout_completion: *Completion,
        },
        write: struct {
            fd: os.fd_t,
            buffer: []const u8,
            offset: u64,
        },
    };

    pub const AcceptError = error{
        Again,
        FileDescriptorInvalid,
        ConnectionAborted,
        SocketNotListening,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        FileDescriptorNotASocket,
        OperationNotSupported,
        PermissionDenied,
        ProtocolFailure,
        Canceled,
    } || os.UnexpectedError;

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!os.socket_t,
        ) void,
        completion: *Completion,
        socket: os.socket_t,
        flags: u32,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const AcceptError!os.socket_t, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .accept = .{
                    .socket = socket,
                    .address = undefined,
                    .address_size = @sizeOf(os.sockaddr),
                    .flags = flags,
                },
            },
        };
        self.enqueue(completion);
    }

    pub const CancelError = error{ AlreadyInProgress, NotFound } || os.UnexpectedError;

    pub fn cancel(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CancelError!void,
        ) void,
        completion: *Completion,
        cancel_completion: *Completion,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const CancelError!void, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .cancel = .{
                    .target_completion = cancel_completion,
                },
            },
        };
        self.enqueue(completion);
    }

    pub const CancelTimeoutError = error{
        AlreadyInProgress,
        NotFound,
        Canceled,
    } || os.UnexpectedError;

    pub fn cancelTimeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CancelTimeoutError!void,
        ) void,
        completion: *Completion,
        timeout_completion: *Completion,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const CancelTimeoutError!void, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .timeout_remove = .{
                    .timeout_completion = timeout_completion,
                },
            },
        };
        self.enqueue(completion);
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
        Canceled,
    } || os.UnexpectedError;

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: os.fd_t,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const CloseError!void, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .close = .{ .fd = fd },
            },
        };
        self.enqueue(completion);
    }

    pub const ConnectError = error{
        AccessDenied,
        AddressInUse,
        AddressNotAvailable,
        AddressFamilyNotSupported,
        Again,
        OpenAlreadyInProgress,
        FileDescriptorInvalid,
        ConnectionRefused,
        AlreadyConnected,
        NetworkUnreachable,
        FileNotFound,
        FileDescriptorNotASocket,
        PermissionDenied,
        ProtocolNotSupported,
        ConnectionTimedOut,
        Canceled,
    } || os.UnexpectedError;

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        socket: os.socket_t,
        address: std.net.Address,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const ConnectError!void, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .connect = .{
                    .socket = socket,
                    .address = address,
                },
            },
        };
        self.enqueue(completion);
    }

    pub fn connectWithTimeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *LinkedCompletion,
            result: ConnectError!void,
        ) void,
        completion: *LinkedCompletion,
        socket: os.socket_t,
        address: std.net.Address,
        timeout_ns: u63,
    ) void {
        completion.main_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "main_completion", comp);
                    linked_comp.main_result = .{
                        .connect = @intToPtr(*const ConnectError!void, @ptrToInt(res)).*,
                    };
                    tigerbeetle_io_log.debug("IO.connectWithTimeout, connect result={}", .{linked_comp.main_result.?.connect});
                    if (linked_comp.linked_result) |_| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            linked_comp.main_result.?.connect,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .connect = .{
                    .socket = socket,
                    .address = address,
                },
            },
            .linked = true,
        };
        completion.linked_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "linked_completion", comp);
                    linked_comp.linked_result = @intToPtr(*const TimeoutError!void, @ptrToInt(res)).*;
                    tigerbeetle_io_log.debug("IO.connectWithTimeout, link_timeout result={}", .{linked_comp.linked_result.?});
                    if (linked_comp.main_result) |main_result| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            main_result.connect,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .link_timeout = .{
                    .timespec = .{ .tv_sec = 0, .tv_nsec = timeout_ns },
                },
            },
        };
        completion.main_result = null;
        completion.linked_result = null;
        self.enqueueLinked(
            &completion.main_completion,
            &completion.linked_completion,
        );
    }

    pub const FsyncError = error{
        FileDescriptorInvalid,
        DiskQuota,
        ArgumentsInvalid,
        InputOutput,
        NoSpaceLeft,
        ReadOnlyFileSystem,
        Canceled,
    } || os.UnexpectedError;

    pub fn fsync(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: FsyncError!void,
        ) void,
        completion: *Completion,
        fd: os.fd_t,
        flags: u32,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const FsyncError!void, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .fsync = .{
                    .fd = fd,
                    .flags = flags,
                },
            },
        };
        self.enqueue(completion);
    }

    pub const OpenatError = error{
        AccessDenied,
        FileDescriptorInvalid,
        DeviceBusy,
        PathAlreadyExists,
        FileTooBig,
        ArgumentsInvalid,
        IsDir,
        SymLinkLoop,
        ProcessFdQuotaExceeded,
        NameTooLong,
        SystemFdQuotaExceeded,
        NoDevice,
        FileNotFound,
        SystemResources,
        NoSpaceLeft,
        NotDir,
        FileLocksNotSupported,
        Again,
        Canceled,
    } || os.UnexpectedError;

    pub fn openat(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: OpenatError!os.fd_t,
        ) void,
        completion: *Completion,
        fd: os.fd_t,
        path: [*:0]const u8,
        flags: u32,
        mode: os.mode_t,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const OpenatError!os.fd_t, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .openat = .{
                    .fd = fd,
                    .path = path,
                    .flags = flags,
                    .mode = mode,
                },
            },
        };
        self.enqueue(completion);
    }

    pub const ReadError = error{
        Again,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        Canceled,
    } || os.UnexpectedError;

    pub fn read(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: os.fd_t,
        buffer: []u8,
        offset: u64,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const ReadError!usize, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .read = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
        };
        self.enqueue(completion);
    }

    pub const RecvError = error{
        Again,
        FileDescriptorInvalid,
        ConnectionRefused,
        SystemResources,
        SocketNotConnected,
        FileDescriptorNotASocket,
        Canceled,
    } || os.UnexpectedError;

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: os.socket_t,
        buffer: []u8,
        flags: u32,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const RecvError!usize, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .recv = .{
                    .socket = socket,
                    .buffer = buffer,
                    .flags = flags,
                },
            },
        };
        self.enqueue(completion);
    }

    pub fn recvmsg(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: os.socket_t,
        msg: *os.msghdr,
        flags: u32,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const RecvError!usize, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .recvmsg = .{
                    .socket = socket,
                    .msg = msg,
                    .flags = flags,
                },
            },
        };
        self.enqueue(completion);
    }

    pub fn recvWithTimeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *LinkedCompletion,
            result: RecvError!usize,
        ) void,
        completion: *LinkedCompletion,
        socket: os.socket_t,
        buffer: []u8,
        recv_flags: u32,
        timeout_ns: u63,
    ) void {
        completion.main_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "main_completion", comp);
                    linked_comp.main_result = .{
                        .recv = @intToPtr(*const RecvError!usize, @ptrToInt(res)).*,
                    };
                    tigerbeetle_io_log.debug("IO.recvWithTimeout comp=0x{x}, main_result={}", .{ @ptrToInt(comp), linked_comp.main_result.?.recv });
                    if (linked_comp.linked_result) |_| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            linked_comp.main_result.?.recv,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .recv = .{
                    .socket = socket,
                    .buffer = buffer,
                    .flags = recv_flags,
                },
            },
            .linked = true,
        };
        completion.linked_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "linked_completion", comp);
                    linked_comp.linked_result = @intToPtr(*const TimeoutError!void, @ptrToInt(res)).*;
                    tigerbeetle_io_log.debug("IO.recvWithTimeout comp=0x{x}, linked_result={}", .{ @ptrToInt(comp), linked_comp.linked_result.? });
                    if (linked_comp.main_result) |main_result| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            main_result.recv,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .link_timeout = .{
                    .timespec = .{ .tv_sec = 0, .tv_nsec = timeout_ns },
                },
            },
        };
        completion.main_result = null;
        completion.linked_result = null;
        self.enqueueLinked(
            &completion.main_completion,
            &completion.linked_completion,
        );
    }

    pub fn recvmsgWithTimeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *LinkedCompletion,
            result: RecvError!usize,
        ) void,
        completion: *LinkedCompletion,
        socket: os.socket_t,
        msg: *os.msghdr,
        recv_flags: u32,
        timeout_ns: u63,
    ) void {
        completion.main_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "main_completion", comp);
                    linked_comp.main_result = .{
                        .recv = @intToPtr(*const RecvError!usize, @ptrToInt(res)).*,
                    };
                    if (linked_comp.linked_result) |_| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            linked_comp.main_result.?.recv,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .recvmsg = .{
                    .socket = socket,
                    .msg = msg,
                    .flags = recv_flags,
                },
            },
            .linked = true,
        };
        completion.linked_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "linked_completion", comp);
                    linked_comp.linked_result = @intToPtr(*const TimeoutError!void, @ptrToInt(res)).*;
                    if (linked_comp.main_result) |main_result| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            main_result.recv,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .link_timeout = .{
                    .timespec = .{ .tv_sec = 0, .tv_nsec = timeout_ns },
                },
            },
        };
        completion.main_result = null;
        completion.linked_result = null;
        self.enqueueLinked(
            &completion.main_completion,
            &completion.linked_completion,
        );
    }

    pub const SendError = error{
        AccessDenied,
        Again,
        FastOpenAlreadyInProgress,
        AddressFamilyNotSupported,
        FileDescriptorInvalid,
        ConnectionResetByPeer,
        MessageTooBig,
        SystemResources,
        SocketNotConnected,
        FileDescriptorNotASocket,
        OperationNotSupported,
        BrokenPipe,
        Canceled,
    } || os.UnexpectedError;

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: os.socket_t,
        buffer: []const u8,
        flags: u32,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const SendError!usize, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .send = .{
                    .socket = socket,
                    .buffer = buffer,
                    .flags = flags,
                },
            },
        };
        self.enqueue(completion);
    }

    pub fn sendmsg(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: os.socket_t,
        msg: *const os.msghdr_const,
        flags: u32,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const SendError!usize, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .sendmsg = .{
                    .socket = socket,
                    .msg = msg,
                    .flags = flags,
                },
            },
        };
        self.enqueue(completion);
    }

    pub fn sendWithTimeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *LinkedCompletion,
            result: SendError!usize,
        ) void,
        completion: *LinkedCompletion,
        socket: os.socket_t,
        buffer: []const u8,
        send_flags: u32,
        timeout_ns: u63,
    ) void {
        completion.main_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "main_completion", comp);
                    linked_comp.main_result = .{
                        .send = @intToPtr(*const SendError!usize, @ptrToInt(res)).*,
                    };
                    if (linked_comp.linked_result) |_| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            linked_comp.main_result.?.send,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .send = .{
                    .socket = socket,
                    .buffer = buffer,
                    .flags = send_flags,
                },
            },
            .linked = true,
        };
        completion.linked_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "linked_completion", comp);
                    linked_comp.linked_result = @intToPtr(*const TimeoutError!void, @ptrToInt(res)).*;
                    if (linked_comp.main_result) |main_result| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            main_result.send,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .link_timeout = .{
                    .timespec = .{ .tv_sec = 0, .tv_nsec = timeout_ns },
                },
            },
        };
        completion.main_result = null;
        completion.linked_result = null;
        self.enqueueLinked(
            &completion.main_completion,
            &completion.linked_completion,
        );
    }

    pub fn sendmsgWithTimeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *LinkedCompletion,
            result: SendError!usize,
        ) void,
        completion: *LinkedCompletion,
        socket: os.socket_t,
        msg: *const os.msghdr_const,
        send_flags: u32,
        timeout_ns: u63,
    ) void {
        completion.main_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "main_completion", comp);
                    linked_comp.main_result = .{
                        .send = @intToPtr(*const SendError!usize, @ptrToInt(res)).*,
                    };
                    if (linked_comp.linked_result) |_| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            linked_comp.main_result.?.send,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .sendmsg = .{
                    .socket = socket,
                    .msg = msg,
                    .flags = send_flags,
                },
            },
            .linked = true,
        };
        completion.linked_completion = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    const linked_comp = @fieldParentPtr(LinkedCompletion, "linked_completion", comp);
                    linked_comp.linked_result = @intToPtr(*const TimeoutError!void, @ptrToInt(res)).*;
                    if (linked_comp.main_result) |main_result| {
                        callback(
                            @intToPtr(Context, @ptrToInt(ctx)),
                            linked_comp,
                            main_result.send,
                        );
                    }
                }
            }.wrapper,
            .operation = .{
                .link_timeout = .{
                    .timespec = .{ .tv_sec = 0, .tv_nsec = timeout_ns },
                },
            },
        };
        completion.main_result = null;
        completion.linked_result = null;
        self.enqueueLinked(
            &completion.main_completion,
            &completion.linked_completion,
        );
    }

    pub const TimeoutError = error{Canceled} || os.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const TimeoutError!void, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .timeout = .{
                    .timespec = .{ .tv_sec = 0, .tv_nsec = nanoseconds },
                },
            },
        };
        self.enqueue(completion);
    }

    pub const WriteError = error{
        Again,
        NotOpenForWriting,
        NotConnected,
        DiskQuota,
        FileTooBig,
        Alignment,
        InputOutput,
        NoSpaceLeft,
        Unseekable,
        AccessDenied,
        BrokenPipe,
        Canceled,
    } || os.UnexpectedError;

    pub fn write(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    ) void {
        completion.* = .{
            .io = self,
            .context = context,
            .callback = struct {
                fn wrapper(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                    callback(
                        @intToPtr(Context, @ptrToInt(ctx)),
                        comp,
                        @intToPtr(*const WriteError!usize, @ptrToInt(res)).*,
                    );
                }
            }.wrapper,
            .operation = .{
                .write = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
        };
        self.enqueue(completion);
    }
};

pub fn buffer_limit(buffer_len: usize) usize {
    // Linux limits how much may be written in a `pwrite()/pread()` call, which is `0x7ffff000` on
    // both 64-bit and 32-bit systems, due to using a signed C int as the return value, as well as
    // stuffing the errno codes into the last `4096` values.
    // Darwin limits writes to `0x7fffffff` bytes, more than that returns `EINVAL`.
    // The corresponding POSIX limit is `std.math.maxInt(isize)`.
    const limit = switch (builtin.target.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    return std.math.min(limit, buffer_len);
}

pub fn io_uring_prep_cancel(
    sqe: *io_uring_sqe,
    cancel_user_data: u64,
    flags: u32,
) void {
    sqe.* = .{
        .opcode = .ASYNC_CANCEL,
        .flags = 0,
        .ioprio = 0,
        .fd = -1,
        .off = 0,
        .addr = cancel_user_data,
        .len = 0,
        .rw_flags = flags,
        .user_data = 0,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .__pad2 = [2]u64{ 0, 0 },
    };
}

test "ref all decls" {
    std.testing.refAllDecls(IO);
}

test "write/fsync/read" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        fd: os.fd_t,

        write_buf: [20]u8 = [_]u8{97} ** 20,
        read_buf: [20]u8 = [_]u8{98} ** 20,

        written: usize = 0,
        fsynced: bool = false,
        read: usize = 0,

        fn run_test() !void {
            const path = "test_io_write_fsync_read";
            const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
            defer file.close();
            defer std.fs.cwd().deleteFile(path) catch {};

            var self: Context = .{
                .io = try IO.init(32, 0),
                .fd = file.handle,
            };
            defer self.io.deinit();

            var completion: IO.Completion = undefined;

            self.io.write(
                *Context,
                &self,
                write_callback,
                &completion,
                self.fd,
                &self.write_buf,
                10,
            );
            while (!self.done) try self.io.tick();

            try testing.expectEqual(self.write_buf.len, self.written);
            try testing.expect(self.fsynced);
            try testing.expectEqual(self.read_buf.len, self.read);
            try testing.expectEqualSlices(u8, &self.write_buf, &self.read_buf);
        }

        fn write_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.WriteError!usize,
        ) void {
            self.written = result catch @panic("write error");
            self.io.fsync(*Context, self, fsync_callback, completion, self.fd, 0);
        }

        fn fsync_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.FsyncError!void,
        ) void {
            result catch @panic("fsync error");
            self.fsynced = true;
            self.io.read(*Context, self, read_callback, completion, self.fd, &self.read_buf, 10);
        }

        fn read_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ReadError!usize,
        ) void {
            _ = completion;
            self.read = result catch @panic("read error");
            self.done = true;
        }
    }.run_test();
}

test "openat/close" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        fd: os.fd_t = 0,

        fn run_test() !void {
            const path = "test_io_openat_close";
            defer std.fs.cwd().deleteFile(path) catch {};

            var self: Context = .{ .io = try IO.init(32, 0) };
            defer self.io.deinit();

            var completion: IO.Completion = undefined;
            self.io.openat(
                *Context,
                &self,
                openat_callback,
                &completion,
                linux.AT_FDCWD,
                path,
                os.O_CLOEXEC | os.O_RDWR | os.O_CREAT,
                0o666,
            );
            while (!self.done) try self.io.tick();

            try testing.expect(self.fd > 0);
        }

        fn openat_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.OpenatError!os.fd_t,
        ) void {
            self.fd = result catch @panic("openat error");
            self.io.close(*Context, self, close_callback, completion, self.fd);
        }

        fn close_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.CloseError!void,
        ) void {
            _ = completion;
            result catch @panic("close error");
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/send/receive" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        send_buf: [10]u8 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 },
        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

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
                .client = client,
            };
            defer self.io.deinit();

            var client_completion: IO.Completion = undefined;
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                address,
            );

            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server, 0);

            while (!self.done) try self.io.tick();

            try testing.expectEqual(self.send_buf.len, self.sent);
            try testing.expectEqual(self.recv_buf.len, self.received);

            try testing.expectEqualSlices(u8, self.send_buf[0..self.received], &self.recv_buf);
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            result catch @panic("connect error");
            self.io.send(
                *Context,
                self,
                send_callback,
                completion,
                self.client,
                &self.send_buf,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn send_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.SendError!usize,
        ) void {
            _ = completion;
            self.sent = result catch @panic("send error");
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
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            self.received = result catch @panic("recv error");
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/sendmsg/recvmsg" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        send_buf: [10]u8 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 },
        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

        send_iovecs: ?[1]os.iovec_const = null,
        recv_iovecs: ?[1]os.iovec = null,

        send_msg: ?os.msghdr_const = null,
        recv_msg: ?os.msghdr = null,
        recv_addr: std.net.Address = undefined,

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
                .client = client,
            };
            defer self.io.deinit();

            self.send_iovecs = [_]os.iovec_const{
                os.iovec_const{ .iov_base = &self.send_buf, .iov_len = self.send_buf.len },
            };
            self.send_msg = os.msghdr_const{
                .msg_name = &address.any,
                .msg_namelen = address.getOsSockLen(),
                .msg_iov = &self.send_iovecs.?,
                .msg_iovlen = 1,
                .msg_control = null,
                .msg_controllen = 0,
                .msg_flags = 0,
            };

            self.recv_iovecs = [_]os.iovec{
                os.iovec{ .iov_base = &self.recv_buf, .iov_len = self.recv_buf.len },
            };
            self.recv_addr = std.net.Address.initIp4([_]u8{0} ** 4, 0);
            self.recv_msg = os.msghdr{
                .msg_name = &self.recv_addr.any,
                .msg_namelen = self.recv_addr.getOsSockLen(),
                .msg_iov = &self.recv_iovecs.?,
                .msg_iovlen = 1,
                .msg_control = null,
                .msg_controllen = 0,
                .msg_flags = 0,
            };

            var client_completion: IO.Completion = undefined;
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                address,
            );

            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server, 0);

            while (!self.done) try self.io.tick();

            try testing.expectEqual(self.send_buf.len, self.sent);
            try testing.expectEqual(self.recv_buf.len, self.received);

            try testing.expectEqualSlices(u8, self.send_buf[0..self.received], &self.recv_buf);
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            result catch @panic("connect error");
            self.io.sendmsg(
                *Context,
                self,
                send_callback,
                completion,
                self.client,
                &self.send_msg.?,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn send_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.SendError!usize,
        ) void {
            _ = completion;
            self.sent = result catch @panic("send error");
        }

        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            self.accepted_sock = result catch @panic("accept error");
            self.io.recvmsg(
                *Context,
                self,
                recv_callback,
                completion,
                self.accepted_sock,
                &self.recv_msg.?,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            self.received = result catch @panic("recv error");
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/sendmsgWithTimeout/recvmsgWithTimeout" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        send_buf: [10]u8 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 },
        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

        send_iovecs: ?[1]os.iovec_const = null,
        recv_iovecs: ?[1]os.iovec = null,

        send_msg: ?os.msghdr_const = null,
        recv_msg: ?os.msghdr = null,
        recv_addr: std.net.Address = undefined,

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
                .client = client,
            };
            defer self.io.deinit();

            self.send_iovecs = [_]os.iovec_const{
                os.iovec_const{ .iov_base = &self.send_buf, .iov_len = self.send_buf.len },
            };
            self.send_msg = os.msghdr_const{
                .msg_name = &address.any,
                .msg_namelen = address.getOsSockLen(),
                .msg_iov = &self.send_iovecs.?,
                .msg_iovlen = 1,
                .msg_control = null,
                .msg_controllen = 0,
                .msg_flags = 0,
            };

            self.recv_iovecs = [_]os.iovec{
                os.iovec{ .iov_base = &self.recv_buf, .iov_len = self.recv_buf.len },
            };
            self.recv_addr = std.net.Address.initIp4([_]u8{0} ** 4, 0);
            self.recv_msg = os.msghdr{
                .msg_name = &self.recv_addr.any,
                .msg_namelen = self.recv_addr.getOsSockLen(),
                .msg_iov = &self.recv_iovecs.?,
                .msg_iovlen = 1,
                .msg_control = null,
                .msg_controllen = 0,
                .msg_flags = 0,
            };

            var client_completion: IO.LinkedCompletion = undefined;
            self.io.connectWithTimeout(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                address,
                5 * std.time.ns_per_s,
            );

            var server_completion: IO.LinkedCompletion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion.main_completion, server, 0);

            while (!self.done) try self.io.tick();

            try testing.expectEqual(self.send_buf.len, self.sent);
            try testing.expectEqual(self.recv_buf.len, self.received);

            try testing.expectEqualSlices(u8, self.send_buf[0..self.received], &self.recv_buf);
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.LinkedCompletion,
            result: IO.ConnectError!void,
        ) void {
            result catch @panic("connect error");
            self.io.sendmsgWithTimeout(
                *Context,
                self,
                send_callback,
                completion,
                self.client,
                &self.send_msg.?,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
                5 * std.time.ns_per_s,
            );
        }

        fn send_callback(
            self: *Context,
            completion: *IO.LinkedCompletion,
            result: IO.SendError!usize,
        ) void {
            _ = completion;
            self.sent = result catch @panic("send error");
        }

        fn accept_callback(
            self: *Context,
            main_completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            self.accepted_sock = result catch @panic("accept error");
            const comp = @fieldParentPtr(IO.LinkedCompletion, "main_completion", main_completion);
            self.io.recvmsgWithTimeout(
                *Context,
                self,
                recv_callback,
                comp,
                self.accepted_sock,
                &self.recv_msg.?,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
                5 * std.time.ns_per_s,
            );
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.LinkedCompletion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            self.received = result catch @panic("recv error");
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/receive/cancel" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,
        cancel_completion: IO.Completion = undefined,

        accepted_sock: os.socket_t = undefined,

        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

        recv_result: IO.RecvError!usize = undefined,

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
                .client = client,
            };
            defer self.io.deinit();

            var client_completion: IO.Completion = undefined;
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                address,
            );

            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server, 0);

            while (!self.done) try self.io.tick();

            try testing.expectError(error.Canceled, self.recv_result);
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            result catch @panic("connect error");
            self.io.recv(
                *Context,
                self,
                recv_callback,
                completion,
                self.client,
                &self.recv_buf,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
            self.io.cancel(
                *Context,
                self,
                cancel_callback,
                &self.cancel_completion,
                completion,
            );
        }

        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            _ = completion;
            self.accepted_sock = result catch @panic("accept error");
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            self.recv_result = result;
        }

        fn cancel_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.CancelError!void,
        ) void {
            _ = completion;
            result catch @panic("cancel error");
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/send/recvWithTimeout" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        send_buf: [10]u8 = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 },
        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

        sent: usize = 0,
        received: usize = 0,
        recv_callback_called: bool = false,

        linked_completion: IO.LinkedCompletion = undefined,

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
                .client = client,
            };
            defer self.io.deinit();

            var client_completion: IO.Completion = undefined;
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                address,
            );

            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server, 0);

            while (!self.done) try self.io.tick();

            try testing.expectEqual(self.send_buf.len, self.sent);
            try testing.expectEqual(self.recv_buf.len, self.received);

            try testing.expectEqualSlices(u8, self.send_buf[0..self.received], &self.recv_buf);

            try testing.expectError(error.Canceled, self.linked_completion.linked_result.?);
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            result catch @panic("connect error");
            self.io.send(
                *Context,
                self,
                send_callback,
                completion,
                self.client,
                &self.send_buf,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
            );
        }

        fn send_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.SendError!usize,
        ) void {
            _ = completion;
            self.sent = result catch @panic("send error");
        }

        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            _ = completion;
            self.accepted_sock = result catch @panic("accept error");
            self.io.recvWithTimeout(
                *Context,
                self,
                recv_callback,
                &self.linked_completion,
                self.accepted_sock,
                &self.recv_buf,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
                std.time.ns_per_ms,
            );
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.LinkedCompletion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            self.received = result catch @panic("recv error");
            self.done = true;
        }
    }.run_test();
}

test "accept/connect/recvWithTimeout" {
    const testing = std.testing;

    try struct {
        const Context = @This();

        io: IO,
        done: bool = false,
        server: os.socket_t,
        client: os.socket_t,

        accepted_sock: os.socket_t = undefined,

        recv_buf: [5]u8 = [_]u8{ 0, 1, 0, 1, 0 },

        recv_result: IO.RecvError!usize = undefined,
        linked_completion: IO.LinkedCompletion = undefined,

        fn run_test() !void {
            const address = try std.net.Address.parseIp4("127.0.0.1", 3133);
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
                .client = client,
            };
            defer self.io.deinit();

            var client_completion: IO.Completion = undefined;
            self.io.connect(
                *Context,
                &self,
                connect_callback,
                &client_completion,
                client,
                address,
            );

            var server_completion: IO.Completion = undefined;
            self.io.accept(*Context, &self, accept_callback, &server_completion, server, 0);

            while (!self.done) try self.io.tick();

            try testing.expectError(error.Canceled, self.recv_result);

            if (self.linked_completion.linked_result.?) |_| {} else |err| {
                std.debug.print("linked_result expect no error, fount error.{s}\n", .{@errorName(err)});
                return error.TestExpectedError;
            }
        }

        fn connect_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.ConnectError!void,
        ) void {
            _ = completion;
            result catch @panic("connect error");
            self.io.recvWithTimeout(
                *Context,
                self,
                recv_callback,
                &self.linked_completion,
                self.client,
                &self.recv_buf,
                if (builtin.target.os.tag == .linux) os.MSG_NOSIGNAL else 0,
                std.time.ns_per_ms,
            );
        }

        fn accept_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.AcceptError!os.socket_t,
        ) void {
            _ = completion;
            self.accepted_sock = result catch @panic("accept error");
        }

        fn recv_callback(
            self: *Context,
            completion: *IO.LinkedCompletion,
            result: IO.RecvError!usize,
        ) void {
            _ = completion;
            self.recv_result = result;
            self.done = true;
        }
    }.run_test();
}

test "timeout" {
    const testing = std.testing;

    const ms = 20;
    const margin = 5;
    const count = 10;

    try struct {
        const Context = @This();

        io: IO,
        count: u32 = 0,
        stop_time: i64 = 0,

        fn run_test() !void {
            const start_time = std.time.milliTimestamp();
            var self: Context = .{ .io = try IO.init(32, 0) };
            defer self.io.deinit();

            var completions: [count]IO.Completion = undefined;
            for (completions) |*completion| {
                self.io.timeout(
                    *Context,
                    &self,
                    timeout_callback,
                    completion,
                    ms * std.time.ns_per_ms,
                );
            }
            while (self.count < count) try self.io.tick();

            try self.io.tick();
            try testing.expectEqual(@as(u32, count), self.count);

            try testing.expectApproxEqAbs(
                @as(f64, ms),
                @intToFloat(f64, self.stop_time - start_time),
                margin,
            );
        }

        fn timeout_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.TimeoutError!void,
        ) void {
            _ = completion;
            result catch @panic("timeout error");
            if (self.stop_time == 0) self.stop_time = std.time.milliTimestamp();
            self.count += 1;
        }
    }.run_test();
}

test "cancel timeout" {
    const testing = std.testing;

    const ms = 0;
    const margin = 5;
    const count = 10;

    try struct {
        const Context = @This();

        io: IO,
        count: u32 = 0,
        cancel_count: u32 = 0,
        stop_time: i64 = 0,

        fn run_test() !void {
            const start_time = std.time.milliTimestamp();
            var self: Context = .{ .io = try IO.init(32, 0) };
            defer self.io.deinit();

            var completions: [count]IO.Completion = undefined;
            var cancel_completions: [count]IO.Completion = undefined;
            for (completions) |*completion, i| {
                self.io.timeout(
                    *Context,
                    &self,
                    timeout_callback,
                    completion,
                    ms * std.time.ns_per_ms,
                );
                self.io.cancelTimeout(
                    *Context,
                    &self,
                    cancel_timeout_callback,
                    &cancel_completions[i],
                    completion,
                );
            }
            while (self.count < count) try self.io.tick();

            try self.io.tick();
            try testing.expectEqual(@as(u32, count), self.count);
            try testing.expectEqual(@as(u32, count), self.cancel_count);
            try testing.expectApproxEqAbs(
                @as(f64, ms),
                @intToFloat(f64, self.stop_time - start_time),
                margin,
            );
        }

        fn timeout_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.TimeoutError!void,
        ) void {
            _ = completion;
            testing.expectError(error.Canceled, result) catch @panic("cancel timeout unexpected error");
            if (self.stop_time == 0) self.stop_time = std.time.milliTimestamp();
            self.count += 1;
        }

        fn cancel_timeout_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.CancelTimeoutError!void,
        ) void {
            _ = completion;
            result catch |err| @panic(@errorName(err));
            self.cancel_count += 1;
        }
    }.run_test();
}

test "submission queue full" {
    const testing = std.testing;

    const ms = 20;
    const count = 10;

    try struct {
        const Context = @This();

        io: IO,
        count: u32 = 0,

        fn run_test() !void {
            var self: Context = .{ .io = try IO.init(1, 0) };
            defer self.io.deinit();

            var completions: [count]IO.Completion = undefined;
            for (completions) |*completion| {
                self.io.timeout(
                    *Context,
                    &self,
                    timeout_callback,
                    completion,
                    ms * std.time.ns_per_ms,
                );
            }
            while (self.count < count) try self.io.tick();

            try self.io.tick();
            try testing.expectEqual(@as(u32, count), self.count);
        }

        fn timeout_callback(
            self: *Context,
            completion: *IO.Completion,
            result: IO.TimeoutError!void,
        ) void {
            _ = completion;
            result catch @panic("timeout error");
            self.count += 1;
        }
    }.run_test();
}
