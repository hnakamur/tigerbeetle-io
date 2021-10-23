const Version = @import("version.zig").Version;

pub const Response = struct {
    version: Version,
    status_code: u16,
    status_text: []const u8,
    body: []const u8,
};