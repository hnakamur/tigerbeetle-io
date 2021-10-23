const std = @import("std");

pub const Version = enum {
    Http09,
    Http10,
    Http11,
    Http2,
    Http3,

    pub fn from_bytes(input: []const u8) ?Version {
        if (std.mem.startsWith(u8, input, "HTTP/")) {
            const v: []const u8 = input["HTTP/".len..];
            if (v.len == 1) {
                if (v[0] == '2') return .Http2;
                if (v[0] == '3') return .Http3;
            } else if (v.len == 3 and v[1] == '.') {
                if (v[0] == '1') {
                    if (v[2] == '1') return .Http11;
                    if (v[2] == '0') return .Http10;
                } else if (v[0] == '0' and v[2] == '9') return .Http09;
            }
        }
        return null;
    }

    pub fn to_bytes(self: Version) []const u8 {
        return switch (self) {
            .Http09 => "HTTP/0.9",
            .Http10 => "HTTP/1.0",
            .Http11 => "HTTP/1.1",
            .Http2 => "HTTP/2",
            .Http3 => "HTTP/3",
        };        
    }
};

const testing = std.testing;

test "http.Version" {
    try testing.expectEqual(Version.Http09, Version.from_bytes("HTTP/0.9").?);
    try testing.expectEqual(Version.Http10, Version.from_bytes("HTTP/1.0").?);
    try testing.expectEqual(Version.Http11, Version.from_bytes("HTTP/1.1").?);
    try testing.expectEqual(Version.Http2, Version.from_bytes("HTTP/2").?);
    try testing.expectEqual(Version.Http3, Version.from_bytes("HTTP/3").?);
    try testing.expect(Version.from_bytes("HTTP/1.1 ") == null);
}
