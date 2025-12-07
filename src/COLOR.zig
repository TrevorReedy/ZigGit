const std = @import("std");

const Color = struct {
    code: []const u8,

    pub fn apply(self: Color, text: []const u8) void {
        const stdout = std.io.getStdOut().writer();
        _ = stdout.print("{s}{s}\x1b[0m", .{ self.code, text }) catch {};
    }
};

pub const RED = Color{ .code = "\x1b[31m" };
pub const GREEN = Color{ .code = "\x1b[32m" };
pub const YELLOW = Color{ .code = "\x1b[33m" };
