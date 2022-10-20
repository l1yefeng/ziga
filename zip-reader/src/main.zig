const std = @import("std");
const Zip = @import("zip.zig").Zip;

pub fn main() !void {
    var it = std.process.args();
    _ = it.next();

    if (it.next()) |path| {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        // zip open
        var z: Zip = undefined;
        try z.open(allocator, path);
        defer z.close();

        // list zip entries
        for (z.members) |*member| {
            try member.open();
            defer member.close();

            var buf = try allocator.alloc(u8, member.orig_size);
            defer allocator.free(buf);
            _ = try member.read(buf);

            std.debug.print("{s}", .{buf});
        }
    } else {
        std.debug.panic("no path was given!\n", .{});
    }
}
