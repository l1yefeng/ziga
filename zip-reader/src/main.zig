const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const deflate = std.compress.deflate;

const ZipError = error{
    FileFormat,
    UnsupportedCompressionMethod,
    UnsupportedMultipleVolume,
};

fn readZip(path: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    // zip open
    const z = try Zip.open(gpa.allocator(), path);
    defer z.close();

    // list zip entries
    for (z.members) |*member| {
        std.debug.print("{d:<10}\t{s}\n", .{ member.orig_size, member.name });
        std.debug.print("------\n", .{});

        // print content

        try z.file.seekTo(member.data_offset);
        var reader = z.file.reader();

        if (member.deflated) {
            var dat = try z.allocator.alloc(u8, member.orig_size);
            defer z.allocator.free(dat);

            var dec = try std.compress.deflate.decompressor(z.allocator, reader, null);
            defer dec.deinit();
            errdefer dec.deinit();

            try dec.reader().readNoEof(dat);
            std.debug.print("{s}", .{dat});
        } else {
            var dat = try z.allocator.alloc(u8, member.orig_size);
            defer z.allocator.free(dat);

            try reader.readNoEof(dat);
            std.debug.print("{s}", .{dat});
        }

        std.debug.print("\n", .{});
    }
}

fn getFirstArg() ?[]const u8 {
    var it = std.process.args();
    _ = it.next();
    return it.next();
}

pub fn main() !void {
    if (getFirstArg()) |path| {
        return readZip(path);
    }
}

const eocdr_start = [4]u8{ 'P', 'K', 0x05, 0x06 };
const eocdr_min_len = eocdr_start.len + 18;

fn findEocdrPosition(block: []const u8) ?usize {
    var i = block.len - eocdr_min_len;
    i += 1;
    while (i > 0) {
        i -= 1;

        const j = i + eocdr_start.len;
        if (mem.eql(u8, block[i..j], &eocdr_start)) {
            const cmt_len_pos = i + eocdr_min_len - 2;
            const cmt_len = mem.readIntLittle(u16, &block[cmt_len_pos]);
            if (cmt_len_pos + 2 + cmt_len <= block.len) {
                return i;
            }
        }
    }

    return null;
}

//   |<-----                        zip                        ----->|
//   |<-- local file data -->|<-- central directory -->|<-- EOCDR -->|
//   ^                       ^                         ^
//   base_offset (0)         eocdr.cd_offset           eocdr_offset
//
// read zip file by
// 1. scan to find EOCDR, which tells the location of CD
// 2. read CD, which tells the location of local file data

const ZipInfo = packed struct {
    cd_entries: u16,
    cd_size: u32,
    cd_offset: u32,

    fn init(eocdr_bytes: []const u8, eocdr_offset: u64, file_size: u64) !ZipInfo {

        // use a stream reader to read header
        var stream = std.io.fixedBufferStream(eocdr_bytes);
        var reader = stream.reader();

        // skip signature
        try reader.skipBytes(eocdr_start.len, .{});

        // disk number, dir disk number, record this disk are unused
        const disk_nbr = try reader.readIntLittle(u16);
        const cd_start_disk = try reader.readIntLittle(u16);
        const cd_entries_curr_disk = try reader.readIntLittle(u16);
        const cd_entries = try reader.readIntLittle(u16);
        const cd_size = try reader.readIntLittle(u32);
        const cd_offset = try reader.readIntLittle(u32);

        if (cd_entries != cd_entries_curr_disk or
            cd_start_disk != 0 or
            disk_nbr != 0) return ZipError.UnsupportedMultipleVolume;

        if (cd_entries == 0xffff or
            cd_size == 0xffff or
            cd_offset == 0xffffffff) std.debug.panic("zip64!\n", .{});

        if (cd_offset + cd_size > eocdr_offset) return ZipError.FileFormat;
        if (eocdr_offset - cd_size >= file_size) return ZipError.FileFormat;

        // TODO use const for 30 and verify its correctness
        if (cd_entries * lfh_min_len > cd_offset) return ZipError.FileFormat;

        return ZipInfo{
            .cd_entries = cd_entries,
            .cd_size = cd_size,
            .cd_offset = cd_offset,
        };
    }
};

fn getInfoFromEocdr(file: fs.File, size: u64) !ZipInfo {
    const blens = [_]u32{ 1 << 10, 65 * 1 << 10 };

    var buf: [blens[1]]u8 = undefined;

    for (blens) |blen_wished| {
        // length (from the end) to read
        const blen: u32 = std.math.min(blen_wished, size);

        // read at offset
        _ = try file.pread(buf[0..blen], size - blen);

        // find signature
        if (findEocdrPosition(buf[0..blen])) |p| {
            return ZipInfo.init(buf[p..blen], size - blen + p, size);
        }

        // detect signature not found
        if (blen == size) return ZipError.FileFormat;
    }

    return ZipError.FileFormat;
}

const cfh_start = [_]u8{ 'P', 'K', 0x01, 0x02 };
const cfh_min_len = cfh_start.len + 42;

const ZipMember = struct {
    deflated: bool,
    size: u32,
    orig_size: u32,
    name: []u8,
    lfh_offset: u32,
    data_offset: u32,

    fn init(self: *ZipMember, reader: anytype, for_name: []u8) !void {

        // read and verify start
        if (reader.isBytes(&cfh_start)) |is| {
            if (!is) return ZipError.FileFormat;
        } else |err| {
            return err;
        }

        // ignored fields: made_by_ver, extract_ver, gp_flag
        try reader.skipBytes(6, .{});

        // read method
        const method = try reader.readIntLittle(u16);
        switch (method) {
            0 => self.deflated = false,
            8 => self.deflated = true,
            else => return ZipError.UnsupportedCompressionMethod,
        }

        // ignored fields: mod_time, mod_date, crc32
        try reader.skipBytes(8, .{});

        self.size = try reader.readIntLittle(u32);
        self.orig_size = try reader.readIntLittle(u32);

        const name_len = try reader.readIntLittle(u16);
        const extra_len = try reader.readIntLittle(u16);
        const cmt_len = try reader.readIntLittle(u16);

        // ignored fields: disk_nbr_start, int_attres, ext_attrs
        try reader.skipBytes(8, .{});

        self.lfh_offset = try reader.readIntLittle(u32);

        self.name = for_name[0..name_len];
        try reader.readNoEof(self.name);

        try reader.skipBytes(extra_len + cmt_len, .{});
    }
};

const lfh_start = [_]u8{ 'P', 'K', 0x03, 0x04 };
const lfh_min_len = lfh_start.len + 26;

/// Zip is the struct for a zip achive.
/// Open before its members can be accessed;
/// Close when access is no longer needed.
const Zip = struct {
    allocator: mem.Allocator,
    file: fs.File,
    members: []ZipMember,
    names_data: []u8,

    fn open(allocator: mem.Allocator, path: []const u8) !Zip {
        // open file on path
        var file = try fs.openFileAbsolute(path, .{ .mode = fs.File.OpenMode.read_only });
        errdefer file.close();

        // get zip info by reading the eocdr in file
        const stat = try file.stat();
        const info = try getInfoFromEocdr(file, stat.size);

        // allocate space for members, their names
        var members = try allocator.alloc(ZipMember, info.cd_entries);
        errdefer allocator.free(members);
        var names_data = try allocator.alloc(u8, info.cd_size - cfh_min_len * info.cd_entries);
        errdefer allocator.free(names_data);

        // start reading cd from its offset
        try file.seekTo(info.cd_offset);
        var file_reader = file.reader();

        // obtain info of each member
        var names_len: @TypeOf(names_data.len) = 0;
        for (members) |*member| {
            try member.init(file_reader, names_data[names_len..]);
            names_len += member.name.len;
        }

        // check lfh signature and set data offset
        for (members) |*member| {
            try file.seekTo(member.lfh_offset);
            var r = file.reader();

            if (r.isBytes(&lfh_start)) |is| {
                if (!is) return ZipError.FileFormat;
            } else |err| {
                return err;
            }

            try r.skipBytes(22, .{});
            const name_len = try r.readIntLittle(u16);
            const extra_len = try r.readIntLittle(u16);
            member.data_offset = member.lfh_offset + @as(u32, lfh_min_len) + name_len + extra_len;
        }

        return Zip{
            .allocator = allocator,
            .file = file,
            .members = members,
            .names_data = names_data,
        };
    }

    fn close(self: *const Zip) void {
        self.file.close();
        self.allocator.free(self.members);
        self.allocator.free(self.names_data);
    }
};

test {
    const z = try Zip.open(std.testing.allocator, "/tmp/test.zip");
    z.close();
}
