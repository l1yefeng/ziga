const std = @import("std");
const fs = std.fs;

const zip = @import("zip.zig");

/// An unzip program using zip.zig.
/// Very unsafe in terms of CLI usage.
/// Usage:
/// - exe <path>            unzip everything here
/// - exe <path> <name>     unzip named file here
/// - exe -l <path>         list members
pub fn main() !void {
    var it = std.process.args();
    _ = it.next();

    var just_list: bool = false;
    var path: []const u8 = undefined;
    var name: ?[]const u8 = null;

    const arg1 = it.next().?;
    if (std.mem.eql(u8, arg1, "-l")) {
        just_list = true;
        path = it.next().?;
    } else {
        path = arg1;
        name = it.next();
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // zip open
    var file = try fs.cwd().openFile(path, .{});
    defer file.close();
    var z = try zip.openZip(allocator, file);
    defer z.close();

    if (just_list) {
        // print names
        const stdout = std.io.getStdOut();
        for (z.members) |*m| {
            _ = try stdout.write(m.name);
            _ = try stdout.write("\n");
        }
    } else {
        // extract files
        if (name) |n| {
            // just extract n
            for (z.members) |*m| {
                if (std.mem.eql(u8, m.name, n)) {
                    try extract(m);
                    break;
                }
            } else {
                std.process.exit(1);
            }
        } else {
            // extract all
            for (z.members) |*m| {
                try extract(m);
            }
        }
    }
}

/// Extract member m from its archive.
/// Its name is used as the output path.
fn extract(m: *zip.Zip.Member) !void {
    var out: fs.File = undefined;
    if (fs.path.dirname(m.name)) |dir| {
        try fs.cwd().makePath(dir);
        var d = try fs.cwd().openDir(dir, .{});
        defer d.close();
        out = try d.createFile(fs.path.basename(m.name), .{ .truncate = false });
    } else {
        out = try fs.cwd().createFile(m.name, .{ .truncate = false });
    }
    defer out.close();

    try m.open();
    defer m.close();

    var buf: [1 << 12]u8 = undefined;
    var reader = m.limitedRedaer();
    while (reader.bytes_left > 0) {
        const n = try reader.read(&buf);
        try out.writeAll(buf[0..n]);
    }
}

test {
    _ = @import("zip.zig");
    _ = @import("test.zig");
}
