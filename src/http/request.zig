const std = @import("std");
const Version = @import("version.zig").Version;

pub const RequestLineParseError = error{
    BadRequest,
    UriTooLong,
};

const max_url_len = 8000;

pub const Request = struct {
    method: []const u8,
    uri: []const u8,
    version: Version,
    line_len: usize,

    pub fn parseBuf(buf: []const u8) RequestLineParseError!Request {
        if (std.mem.indexOfScalar(u8, buf, ' ')) |sp1| {
            const method = buf[0..sp1];
            // TODO: validate method
            if (std.mem.indexOfScalarPos(u8, buf, sp1 + 1, ' ')) |sp2| {
                const uri = buf[sp1 + 1 .. sp2];
                if (uri.len > max_url_len) {
                    return error.UriTooLong;
                }
                // TODO: validate uri
                if (std.mem.indexOfPos(u8, buf, sp2 + 1, "\r\n")) |end| {
                    if (Version.from_bytes(buf[sp2 + 1 .. end])) |v| {
                        return Request{
                            .method = method,
                            .uri = uri,
                            .version = v,
                            .line_len = end + "\r\n".len,
                        };
                    }
                }
            }
        }
        return error.BadRequest;
    }
};
