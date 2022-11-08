const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const deflate = std.compress.deflate;

const ZipError = error{
    WrongFormat,
    UnsupportedCompressionMethod,
    UnsupportedMultipleVolume,
    UnsupportedZip64,
    Inflation,
};

const eocdr_start = [4]u8{ 'P', 'K', 0x05, 0x06 };
const eocdr_min_len = 4 + 18;
const cfh_start = [4]u8{ 'P', 'K', 0x01, 0x02 };
const cfh_min_len = 4 + 42;
const lfh_start = [4]u8{ 'P', 'K', 0x03, 0x04 };
const lfh_min_len = 4 + 26;

pub fn openZip(allocator: mem.Allocator, file: fs.File) !Zip {
    var z: Zip = undefined;
    try z.open(allocator, file);
    return z;
}

//   |<-----                        zip                        ----->|
//   |<-- local file data -->|<-- central directory -->|<-- EOCDR -->|
//   ^                       ^                         ^
//   base_offset (0)         eocdr.cd_offset           eocdr_offset
//
// read zip file by
// 1. scan to find EOCDR, which tells the location of CD
// 2. read CD, which tells the location of local file data

const ZipInfo = struct {
    cd_entries: u16,
    cd_size: u32,
    cd_offset: u32,

    const Self = @This();

    fn fromEocdr(eocdr_bytes: []const u8, eocdr_offset: u64, file_size: u64) !Self {

        // use a stream reader to read header
        var stream = io.fixedBufferStream(eocdr_bytes);
        const reader = stream.reader();

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
            cd_offset == 0xffffffff) return ZipError.UnsupportedZip64;

        if (cd_offset + cd_size > eocdr_offset) return ZipError.WrongFormat;
        if (eocdr_offset - cd_size >= file_size) return ZipError.WrongFormat;

        if (cd_entries * lfh_min_len > cd_offset) return ZipError.WrongFormat;

        return Self{
            .cd_entries = cd_entries,
            .cd_size = cd_size,
            .cd_offset = cd_offset,
        };
    }

    fn fromFile(file: fs.File, size: u64) !Self {
        const blens = [_]u32{ 1 << 10, 65 * 1 << 10 };

        var buf: [blens[1]]u8 = undefined;

        inline for (blens) |blen_wished| {
            // length (from the end) to read
            const blen: u32 = std.math.min(blen_wished, size);

            // read at offset
            _ = try file.pread(buf[0..blen], size - blen);

            // find signature
            if (findEocdrPosition(buf[0..blen])) |p| {
                return Self.fromEocdr(buf[p..blen], size - blen + p, size);
            }

            // detect signature not found
            if (blen == size) return ZipError.WrongFormat;
        }

        return ZipError.WrongFormat;
    }
};

/// Zip is the struct for a zip achive.
/// Open before its members can be accessed;
/// Close when access is no longer needed.
pub const Zip = struct {
    allocator: mem.Allocator,
    file: fs.File,
    members: []Member,
    names_data: []u8,

    pub fn open(self: *Zip, allocator: mem.Allocator, file: fs.File) !void {
        self.allocator = allocator;

        // open file on path
        self.file = file;

        // get zip info by reading the eocdr in file
        const stat = try self.file.stat();
        const info = try ZipInfo.fromFile(self.file, stat.size);

        // allocate space for members, their names
        self.members = try allocator.alloc(Member, info.cd_entries);
        errdefer allocator.free(self.members);
        self.names_data = try allocator.alloc(u8, info.cd_size - cfh_min_len * info.cd_entries);
        errdefer allocator.free(self.names_data);

        // start reading cd from its offset
        try self.file.seekTo(info.cd_offset);

        // obtain info of each member
        var names_len: @TypeOf(self.names_data.len) = 0;
        for (self.members) |*m| {
            try m.init(self, self.names_data[names_len..]);
            names_len += m.name.len;
        }

        // check lfh signature and set data offset
        for (self.members) |*m| {
            try self.file.seekTo(m.lfh_offset);
            const r = self.file.reader();

            try checkStart(r, &lfh_start);

            try r.skipBytes(22, .{});
            const name_len = try r.readIntLittle(u16);
            const extra_len = try r.readIntLittle(u16);
            m.data_offset = m.lfh_offset + lfh_min_len + name_len + extra_len;
        }
    }

    pub fn close(self: *Zip) void {
        self.allocator.free(self.members);
        self.allocator.free(self.names_data);
    }

    pub const Member = struct {
        const Self = @This();
        const Inflator = deflate.Decompressor(fs.File.Reader);

        z: *Zip,
        size: u32,
        orig_size: u32,
        name: []u8,
        lfh_offset: u32,
        data_offset: u32,
        inflator: ?Inflator,

        /// Initialise a member of zip file from a cfh.
        /// `zr` MUST start reading at the cfh.
        /// The member's `name` will be stored to `for_name`, owned by caller.
        fn init(self: *Self, z: *Zip, for_name: []u8) !void {
            self.z = z;
            const zr = z.file.reader();

            // read and verify start
            try checkStart(zr, &cfh_start);

            // ignored fields: made_by_ver, extract_ver, gp_flag
            try zr.skipBytes(6, .{});

            // read method
            const method = try zr.readIntLittle(u16);
            switch (method) {
                0 => self.inflator = null,
                8 => self.inflator.? = undefined,
                else => return ZipError.UnsupportedCompressionMethod,
            }

            // ignored fields: mod_time, mod_date, crc32
            try zr.skipBytes(8, .{});

            self.size = try zr.readIntLittle(u32);
            self.orig_size = try zr.readIntLittle(u32);

            const name_len = try zr.readIntLittle(u16);
            const extra_len = try zr.readIntLittle(u16);
            const cmt_len = try zr.readIntLittle(u16);

            // ignored fields: disk_nbr_start, int_attres, ext_attrs
            try zr.skipBytes(8, .{});

            self.lfh_offset = try zr.readIntLittle(u32);

            self.name = for_name[0..name_len];
            try zr.readNoEof(self.name);

            try zr.skipBytes(extra_len + cmt_len, .{});
        }

        pub fn open(self: *Self, allocator: mem.Allocator) !void {
            try self.z.file.seekTo(self.data_offset);
            if (self.inflator) |*inflator| {
                inflator.* = try deflate.decompressor(allocator, self.z.file.reader(), null);
            }
        }

        pub fn close(self: *Self) void {
            if (self.inflator) |*inflator| {
                inflator.deinit();
            }
        }

        pub fn read(self: *Self, bytes: []u8) !usize {
            if (self.inflator) |*inflator| {
                return inflator.read(bytes);
            } else {
                return self.z.file.read(bytes);
            }
        }
    };
};

fn checkStart(reader: anytype, start: []const u8) !void {
    const is = try reader.isBytes(start);
    if (!is) return ZipError.WrongFormat;
}

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

const testing = std.testing;

// test "zip" {
//     const allocator = testing.allocator;
//
//     var z = try openZip(allocator, "/tmp/test.zip");
//     defer z.close();
//
//     for (z.members) |*m| {
//         try m.open(allocator);
//         defer m.close();
//     }
// }
