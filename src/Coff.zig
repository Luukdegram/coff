//! Represents the object file format for Windows.
//! This contains the structure as well as the ability
//! to parse such file into this structure.
const Coff = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.coff);

allocator: Allocator,
file: std.fs.File,
name: []const u8,

header: Header,
section_table: std.ArrayListUnmanaged(SectionHeader) = .{},

const Header = struct {
    machine: std.coff.MachineType,
    number_of_sections: u16,
    timedate_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

const SectionHeader = struct {
    const Misc = union {
        physical_address: u32,
        virtual_size: u32,
    };

    name: [32]u8,
    misc: Misc,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32,
    pointer_to_line_numbers: u32,
    number_of_relocations: u16,
    number_of_line_numbers: u16,
    characteristics: u32,
};

/// Initializes a new `Coff` instance. The file will not be
/// parsed yet.
pub fn init(allocator: Allocator, file: std.fs.File, path: []const u8) Coff {
    return .{
        .allocator = allocator,
        .file = file,
        .name = path,
        .header = undefined,
    };
}

/// Frees all resources of the `Coff` file. This does
/// not close the file handle.
pub fn deinit(coff: *Coff) void {
    const gpa = coff.allocator;
    coff.section_table.deinit(gpa);
    coff.* = undefined;
}

/// Parses the Coff file in its entirety and allocates any
/// resources required. Memory is owned by the `coff` instance.
pub fn parse(coff: *Coff) !void {
    const reader = coff.file.reader();
    const machine = std.meta.intToEnum(std.coff.MachineType, try reader.readIntLittle(u16)) catch {
        log.err("Given file {s} is not a coff file or contains an unknown machine", .{coff.name});
        return error.UnknownMachine;
    };

    coff.header = .{
        .machine = machine,
        .number_of_sections = try reader.readIntLittle(u16),
        .timedate_stamp = try reader.readIntLittle(u32),
        .pointer_to_symbol_table = try reader.readIntLittle(u32),
        .number_of_symbols = try reader.readIntLittle(u32),
        .size_of_optional_header = try reader.readIntLittle(u16),
        .characteristics = try reader.readIntLittle(u16),
    };

    // When the object file contains an optional header, we simply
    // skip it as object files are not interested in this data.
    if (coff.header.size_of_optional_header != 0) {
        try coff.file.seekBy(@intCast(i64, coff.header.size_of_optional_header));
    }

    try parseSectionTable(coff);
}

fn parseSectionTable(coff: *Coff) !void {
    const reader = coff.file.reader();
    try coff.section_table.ensureUnusedCapacity(coff.allocator, coff.header.number_of_sections);

    var index: u16 = 0;
    while (index < coff.header.number_of_sections) : (index += 1) {
        const sec_header = coff.section_table.addOneAssumeCapacity();

        var name: [32]u8 = undefined;
        try reader.readNoEof(name[0..8]);
        // when name starts with a slash '/', the name of the section
        // contains a long name. The following bytes contain the offset into
        // the string table
        if (name[0] == '/') {
            const offset_len = std.mem.indexOfScalar(u8, name[1..], 0) orelse 7;
            const offset = try std.fmt.parseInt(u32, name[1..][0..offset_len], 10);
            const str_len = try parseStringFromOffset(coff, offset, &name);
            std.mem.set(u8, name[str_len..], 0);
        } else {
            // name is only 8 bytes long, so set all other characters to 0.
            std.mem.set(u8, name[8..], 0);
        }

        sec_header.* = .{
            .name = name,
            .misc = .{ .virtual_size = try reader.readIntLittle(u32) },
            .virtual_address = try reader.readIntLittle(u32),
            .size_of_raw_data = try reader.readIntLittle(u32),
            .pointer_to_raw_data = try reader.readIntLittle(u32),
            .pointer_to_relocations = try reader.readIntLittle(u32),
            .pointer_to_line_numbers = try reader.readIntLittle(u32),
            .number_of_relocations = try reader.readIntLittle(u16),
            .number_of_line_numbers = try reader.readIntLittle(u16),
            .characteristics = try reader.readIntLittle(u32),
        };

        log.debug("Parsed section header: '{s}'", .{std.mem.sliceTo(&name, 0)});
        if (sec_header.misc.virtual_size != 0) {
            log.err("Invalid object file. Expected virtual size '0' but found '{d}'", .{sec_header.misc.virtual_size});
            return error.InvalidVirtualSize;
        }
    }
}

fn stringTableOffset(coff: Coff) u32 {
    return coff.header.pointer_to_symbol_table + (coff.header.number_of_symbols * 18);
}

/// Parses a string from the string table found at given `offset`.
/// Populates the given `buffer` with the string and returns the length.
fn parseStringFromOffset(coff: *Coff, offset: u32, buf: []u8) !usize {
    std.debug.assert(buf.len != 0);

    const current_pos = try coff.file.getPos();
    try coff.file.seekTo(coff.stringTableOffset() + offset);
    const str = (try coff.file.reader().readUntilDelimiterOrEof(buf, 0)) orelse "";
    try coff.file.seekTo(current_pos);
    return str.len;
}
