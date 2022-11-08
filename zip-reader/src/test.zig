const std = @import("std");
const testing = std.testing;

test "open and read file" {
    const fs = std.fs;

    const f = try fs.cwd().openFile("/tmp/test.js", .{});
    defer f.close();

    var buf: [2]u8 = undefined;

    var n = try f.read(&buf);
    try testing.expect(n == 2);
    try testing.expectEqualStrings(&buf, "co");

    try f.seekTo(8);

    n = try f.read(&buf);
    try testing.expect(n == 2);
    try testing.expectEqualStrings(&buf, "lo");

    try f.seekTo(2);

    n = try f.read(&buf);
    try testing.expect(n == 2);
    try testing.expectEqualStrings(&buf, "ns");
}
