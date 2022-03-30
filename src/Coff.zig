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
sections: std.ArrayListUnmanaged(Section) = .{},
relocations: std.AutoArrayHashMapUnmanaged(u16, []const Relocation) = .{},

const Header = struct {
    machine: std.coff.MachineType,
    number_of_sections: u16,
    timedate_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

const Section = struct {
    ptr: [*]const u8,
    size: u32,

    fn slice(section: Section) []const u8 {
        return section.ptr[0..section.size];
    }

    fn fromSlice(buf: []const u8) Section {
        return .{ .ptr = buf.ptr, .size = @intCast(u32, buf.len) };
    }
};

const Relocation = struct {
    virtual_address: u32,
    symbol_table_index: u32,
    tag: u16,
};

const SectionHeader = struct {
    name: [32]u8,
    virtual_size: u32,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32,
    pointer_to_line_numbers: u32,
    number_of_relocations: u16,
    number_of_line_numbers: u16,
    characteristics: u32,

    /// Returns the alignment for the section in bytes
    fn alignment(header: SectionHeader) u32 {
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_1BYTES != 0) return 1;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_2BYTES != 0) return 2;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_4BYTES != 0) return 4;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_8BYTES != 0) return 8;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_16BYTES != 0) return 16;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_32BYTES != 0) return 32;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_64BYTES != 0) return 64;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_128BYTES != 0) return 128;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_256BYTES != 0) return 256;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_512BYTES != 0) return 512;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_1024BYTES != 0) return 1024;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_2048BYTES != 0) return 2048;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_4096BYTES != 0) return 4096;
        if (header.characteristics & flags.IMAGE_SCN_ALIGN_8192BYTES != 0) return 8192;
        unreachable;
    }

    const flags = struct {
        const IMAGE_SCN_ALIGN_1BYTES: u32 = 0x00100000;
        const IMAGE_SCN_ALIGN_2BYTES: u32 = 0x00200000;
        const IMAGE_SCN_ALIGN_4BYTES: u32 = 0x00300000;
        const IMAGE_SCN_ALIGN_8BYTES: u32 = 0x00400000;
        const IMAGE_SCN_ALIGN_16BYTES: u32 = 0x00500000;
        const IMAGE_SCN_ALIGN_32BYTES: u32 = 0x00600000;
        const IMAGE_SCN_ALIGN_64BYTES: u32 = 0x00700000;
        const IMAGE_SCN_ALIGN_128BYTES: u32 = 0x00800000;
        const IMAGE_SCN_ALIGN_256BYTES: u32 = 0x00900000;
        const IMAGE_SCN_ALIGN_512BYTES: u32 = 0x00A00000;
        const IMAGE_SCN_ALIGN_1024BYTES: u32 = 0x00B00000;
        const IMAGE_SCN_ALIGN_2048BYTES: u32 = 0x00C00000;
        const IMAGE_SCN_ALIGN_4096BYTES: u32 = 0x00D00000;
        const IMAGE_SCN_ALIGN_8192BYTES: u32 = 0x00E00000;
    };

    /// When a section name contains the symbol `$`, it is considered
    /// a grouped section. e.g. a section named `.text$X` contributes
    /// to the `.text` section within the image.
    /// The character after the dollar sign, indicates the order when
    /// multiple (same prefix) sections were found.
    fn isGrouped(header: SectionHeader) bool {
        return std.mem.indexOfScalar(u8, &header.name, '$') != null;
    }
};

/// Initializes a new `Coff` instance. The file will not be parsed yet.
pub fn init(allocator: Allocator, file: std.fs.File, path: []const u8) Coff {
    return .{
        .allocator = allocator,
        .file = file,
        .name = path,
        .header = undefined,
    };
}

/// Frees all resources of the `Coff` file. This does not close the file handle.
pub fn deinit(coff: *Coff) void {
    const gpa = coff.allocator;
    coff.section_table.deinit(gpa);
    for (coff.sections.items) |section, sec_index| {
        gpa.free(section.slice());
        if (coff.relocations.get(@intCast(u16, sec_index))) |relocs| {
            gpa.free(relocs);
        }
    }
    coff.sections.deinit(gpa);
    coff.relocations.deinit(gpa);
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
    try parseSectionData(coff);
    try parseRelocations(coff);
}

fn parseSectionTable(coff: *Coff) !void {
    if (coff.header.number_of_sections == 0) return;
    try coff.section_table.ensureUnusedCapacity(coff.allocator, coff.header.number_of_sections);
    const reader = coff.file.reader();

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
            .virtual_size = try reader.readIntLittle(u32),
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
        if (sec_header.virtual_size != 0) {
            log.err("Invalid object file. Expected virtual size '0' but found '{d}'", .{sec_header.virtual_size});
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

/// Parses all section data of the coff file.
/// Asserts section headers are known.
fn parseSectionData(coff: *Coff) !void {
    if (coff.header.number_of_sections == 0) return;
    std.debug.assert(coff.section_table.items.len == coff.header.number_of_sections);
    try coff.sections.ensureUnusedCapacity(coff.allocator, coff.header.number_of_sections);
    const reader = coff.file.reader();
    for (coff.section_table.items) |sec_header| {
        try coff.file.seekTo(sec_header.pointer_to_raw_data);
        const buf = try coff.allocator.alloc(u8, sec_header.virtual_size);
        try reader.readNoEof(buf);
        coff.sections.appendAssumeCapacity(Section.fromSlice(buf));
    }
}

fn parseRelocations(coff: *Coff) !void {
    if (coff.header.number_of_sections == 0) return;
    const reader = coff.file.reader();
    for (coff.section_table.items) |sec_header, index| {
        if (sec_header.number_of_relocations == 0) continue;
        const sec_index = @intCast(u16, index);

        const relocations = try coff.allocator.alloc(Relocation, sec_header.number_of_relocations);
        errdefer coff.allocator.free(relocations);

        try coff.file.seekTo(sec_header.pointer_to_relocations);
        for (relocations) |*reloc| {
            reloc.* = .{
                .virtual_address = try reader.readIntLittle(u32),
                .symbol_table_index = try reader.readIntLittle(u32),
                .tag = try reader.readIntLittle(u16),
            };
        }

        try coff.relocations.putNoClobber(coff.allocator, sec_index, relocations);
    }
}
