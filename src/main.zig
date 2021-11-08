const std = @import("std");

pub const IO = @import("io.zig").IO;

comptime {
    std.testing.refAllDecls(@This());
}
