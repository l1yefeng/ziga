const std = @import("std");
const zip = @import("zip.zig");

pub fn main() !void {
    var it = std.process.args();
    _ = it.next();

    if (it.next()) |path| {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        // zip open
        var z = try zip.openZip(allocator, path);
        defer z.close();

        // list zip entries
        for (z.members) |*member| {
            var buf = try allocator.alloc(u8, member.orig_size);
            defer allocator.free(buf);

            _ = try z.readm(member, buf);
            std.debug.print("{s}", .{buf});
        }
    } else {
        std.debug.panic("no path was given!\n", .{});
    }
}

test {
    _ = @import("zip.zig");
}
