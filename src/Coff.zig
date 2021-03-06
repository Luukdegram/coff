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
relocations: std.AutoHashMapUnmanaged(u16, []const Relocation) = .{},
symbols: std.ArrayListUnmanaged(Symbol) = .{},
string_table: []const u8,

pub const Header = struct {
    machine: std.coff.MachineType,
    number_of_sections: u16,
    timedate_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

pub const Section = struct {
    ptr: [*]const u8,
    size: u32,

    fn slice(section: Section) []const u8 {
        return section.ptr[0..section.size];
    }

    fn fromSlice(buf: []const u8) Section {
        return .{ .ptr = buf.ptr, .size = @intCast(u32, buf.len) };
    }
};

pub const Relocation = struct {
    virtual_address: u32,
    symbol_table_index: u32,
    tag: u16,
};

pub const Symbol = struct {
    name: [8]u8,
    value: u32,
    section_number: i16,
    sym_type: u16,
    storage_class: Class,
    number_aux_symbols: u8,

    pub fn getName(symbol: Symbol, coff: *const Coff) []const u8 {
        if (std.mem.eql(u8, symbol.name[0..4], &.{ 0, 0, 0, 0 })) {
            const offset = std.mem.readIntLittle(u32, symbol.name[4..8]);
            return coff.getString(offset);
        }
        return std.mem.sliceTo(&symbol.name, 0);
    }

    pub fn complexType(symbol: Symbol) ComplexType {
        return @intToEnum(ComplexType, @truncate(u8, symbol.sym_type >> 4));
    }

    pub fn baseType(symbol: Symbol) BaseType {
        return @intToEnum(BaseType, @truncate(u8, symbol.sym_type >> 8));
    }

    const ComplexType = enum(u8) {
        ///No derived type; the symbol is a simple scalar variable.
        IMAGE_SYM_DTYPE_NULL = 0,
        ///The symbol is a pointer to base type.
        IMAGE_SYM_DTYPE_POINTER = 1,
        ///The symbol is a function that returns a base type.
        IMAGE_SYM_DTYPE_FUNCTION = 2,
        ///The symbol is an array of base type.
        IMAGE_SYM_DTYPE_ARRAY = 3,
    };

    pub const BaseType = enum(u8) {
        ///No type information or unknown base type. Microsoft tools use this setting
        IMAGE_SYM_TYPE_NULL = 0,
        ///No valid type; used with void pointers and functions
        IMAGE_SYM_TYPE_VOID = 1,
        ///A character (signed byte)
        IMAGE_SYM_TYPE_CHAR = 2,
        ///A 2-byte signed integer
        IMAGE_SYM_TYPE_SHORT = 3,
        ///A natural integer type (normally 4 bytes in Windows)
        IMAGE_SYM_TYPE_INT = 4,
        ///A 4-byte signed integer
        IMAGE_SYM_TYPE_LONG = 5,
        ///A 4-byte floating-point number
        IMAGE_SYM_TYPE_FLOAT = 6,
        ///An 8-byte floating-point number
        IMAGE_SYM_TYPE_DOUBLE = 7,
        ///A structure
        IMAGE_SYM_TYPE_STRUCT = 8,
        ///A union
        IMAGE_SYM_TYPE_UNION = 9,
        ///An enumerated type
        IMAGE_SYM_TYPE_ENUM = 10,
        ///A member of enumeration (a specific value)
        IMAGE_SYM_TYPE_MOE = 11,
        ///A byte; unsigned 1-byte integer
        IMAGE_SYM_TYPE_BYTE = 12,
        ///A word; unsigned 2-byte integer
        IMAGE_SYM_TYPE_WORD = 13,
        ///An unsigned integer of natural size (normally, 4 bytes)
        IMAGE_SYM_TYPE_UINT = 14,
        ///An unsigned 4-byte integer
        IMAGE_SYM_TYPE_DWORD = 15,
    };

    pub const Class = enum(u8) {
        ///No assigned storage class.
        IMAGE_SYM_CLASS_NULL = 0,
        ///The automatic (stack) variable. The Value field specifies the stack frame offset.
        IMAGE_SYM_CLASS_AUTOMATIC = 1,
        ///A value that Microsoft tools use for external symbols. The Value field indicates the size if the section number is IMAGE_SYM_UNDEFINED (0). If the section number is not zero, then the Value field specifies the offset within the section.
        IMAGE_SYM_CLASS_EXTERNAL = 2,
        ///The offset of the symbol within the section. If the Value field is zero, then the symbol represents a section name.
        IMAGE_SYM_CLASS_STATIC = 3,
        ///A register variable. The Value field specifies the register number.
        IMAGE_SYM_CLASS_REGISTER = 4,
        ///A symbol that is defined externally.
        IMAGE_SYM_CLASS_EXTERNAL_DEF = 5,
        ///A code label that is defined within the module. The Value field specifies the offset of the symbol within the section.
        IMAGE_SYM_CLASS_LABEL = 6,
        ///A reference to a code label that is not defined.
        IMAGE_SYM_CLASS_UNDEFINED_LABEL = 7,
        ///The structure member. The Value field specifies the n th member.
        IMAGE_SYM_CLASS_MEMBER_OF_STRUCT = 8,
        ///A formal argument (parameter) of a function. The Value field specifies the n th argument.
        IMAGE_SYM_CLASS_ARGUMENT = 9,
        ///The structure tag-name entry.
        IMAGE_SYM_CLASS_STRUCT_TAG = 10,
        ///A union member. The Value field specifies the n th member.
        IMAGE_SYM_CLASS_MEMBER_OF_UNION = 11,
        ///The Union tag-name entry.
        IMAGE_SYM_CLASS_UNION_TAG = 12,
        ///A Typedef entry.
        IMAGE_SYM_CLASS_TYPE_DEFINITION = 13,
        ///A static data declaration.
        IMAGE_SYM_CLASS_UNDEFINED_STATIC = 14,
        ///An enumerated type tagname entry.
        IMAGE_SYM_CLASS_ENUM_TAG = 15,
        ///A member of an enumeration. The Value field specifies the n th member.
        IMAGE_SYM_CLASS_MEMBER_OF_ENUM = 16,
        ///A register parameter.
        IMAGE_SYM_CLASS_REGISTER_PARAM = 17,
        ///A bit-field reference. The Value field specifies the n th bit in the bit field.
        IMAGE_SYM_CLASS_BIT_FIELD = 18,
        ///A .bb (beginning of block) or .eb (end of block) record. The Value field is the relocatable address of the code location.
        IMAGE_SYM_CLASS_BLOCK = 100,
        ///A value that Microsoft tools use for symbol records that define the extent of a function: begin function (.bf ), end function ( .ef ), and lines in function ( .lf ). For .lf records, the Value field gives the number of source lines in the function. For .ef records, the Value field gives the size of the function code.
        IMAGE_SYM_CLASS_FUNCTION = 101,
        ///An end-of-structure entry.
        IMAGE_SYM_CLASS_END_OF_STRUCT = 102,
        ///A value that Microsoft tools, as well as traditional COFF format, use for the source-file symbol record. The symbol is followed by auxiliary records that name the file.
        IMAGE_SYM_CLASS_FILE = 103,
        ///A definition of a section (Microsoft tools use STATIC storage class instead).
        IMAGE_SYM_CLASS_SECTION = 104,
        ///A weak external. For more information, see Auxiliary Format 3: Weak Externals.
        IMAGE_SYM_CLASS_WEAK_EXTERNAL = 105,
        ///A CLR token symbol. The name is an ASCII string that consists of the hexadecimal value of the token. For more information, see CLR Token Definition (Object Only).
        IMAGE_SYM_CLASS_CLR_TOKEN = 107,
        //A special symbol that represents the end of function, for debugging purposes.
        IMAGE_SYM_CLASS_END_OF_FUNCTION = 0xFF,
    };
};

pub const SectionHeader = struct {
    name: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32,
    pointer_to_line_numbers: u32,
    number_of_relocations: u16,
    number_of_line_numbers: u16,
    characteristics: u32,

    pub fn getName(header: SectionHeader, coff: *const Coff) []const u8 {
        // when name starts with a slash '/', the name of the section
        // contains a long name. The following bytes contain the offset into
        // the string table
        if (header.name[0] == '/') {
            const offset_len = std.mem.indexOfScalar(u8, header.name[1..], 0) orelse 7;
            const offset = std.fmt.parseInt(u32, header.name[1..][0..offset_len], 10) catch return "";
            return coff.getString(offset);
        }
        return std.mem.sliceTo(&header.name, 0);
    }

    /// Returns the alignment for the section in bytes
    pub fn alignment(header: SectionHeader) u32 {
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

    pub const flags = struct {
        /// The section should not be padded to the next boundary.
        /// This flag is obsolete and is replaced by IMAGE_SCN_ALIGN_1BYTES.
        /// This is valid only for object files.
        pub const IMAGE_SCN_TYPE_NO_PAD = 0x00000008;
        /// The section contains executable code.
        pub const IMAGE_SCN_CNT_CODE = 0x00000020;
        /// The section contains initialized data.
        pub const IMAGE_SCN_CNT_INITIALIZED_DATA = 0x00000040;
        /// The section contains uninitialized data.
        pub const IMAGE_SCN_CNT_UNINITIALIZED_DATA = 0x00000080;
        /// Reserved for future use.
        pub const IMAGE_SCN_LNK_OTHER = 0x00000100;
        /// The section contains comments or other information. The .drectve section has this type. This is valid for object files only.
        pub const IMAGE_SCN_LNK_INFO = 0x00000200;
        /// The section will not become part of the image. This is valid only for object files.
        pub const IMAGE_SCN_LNK_REMOVE = 0x00000800;
        /// The section contains COMDAT data. For more information, see COMDAT Sections (Object Only). This is valid only for object files.
        pub const IMAGE_SCN_LNK_COMDAT = 0x00001000;
        /// The section contains data referenced through the global pointer (GP).
        pub const IMAGE_SCN_GPREL = 0x00008000;
        /// Reserved for future use.
        pub const IMAGE_SCN_MEM_PURGEABLE = 0x00020000;
        /// Reserved for future use.
        pub const IMAGE_SCN_MEM_16BIT = 0x00020000;
        /// Reserved for future use.
        pub const IMAGE_SCN_MEM_LOCKED = 0x00040000;
        /// Reserved for future use.
        pub const IMAGE_SCN_MEM_PRELOAD = 0x00080000;
        /// Align data on a 1-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_1BYTES = 0x00100000;
        /// Align data on a 2-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_2BYTES = 0x00200000;
        /// Align data on a 4-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_4BYTES = 0x00300000;
        /// Align data on an 8-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_8BYTES = 0x00400000;
        /// Align data on a 16-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_16BYTES = 0x00500000;
        /// Align data on a 32-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_32BYTES = 0x00600000;
        /// Align data on a 64-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_64BYTES = 0x00700000;
        /// Align data on a 128-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_128BYTES = 0x00800000;
        /// Align data on a 256-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_256BYTES = 0x00900000;
        /// Align data on a 512-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_512BYTES = 0x00A00000;
        /// Align data on a 1024-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_1024BYTES = 0x00B00000;
        /// Align data on a 2048-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_2048BYTES = 0x00C00000;
        /// Align data on a 4096-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_4096BYTES = 0x00D00000;
        /// Align data on an 8192-byte boundary. Valid only for object files.
        pub const IMAGE_SCN_ALIGN_8192BYTES = 0x00E00000;
        /// The section contains extended relocations.
        pub const IMAGE_SCN_LNK_NRELOC_OVFL = 0x01000000;
        /// The section can be discarded as needed.
        pub const IMAGE_SCN_MEM_DISCARDABLE = 0x02000000;
        /// The section cannot be cached.
        pub const IMAGE_SCN_MEM_NOT_CACHED = 0x04000000;
        /// The section is not pageable.
        pub const IMAGE_SCN_MEM_NOT_PAGED = 0x08000000;
        /// The section can be shared in memory.
        pub const IMAGE_SCN_MEM_SHARED = 0x10000000;
        /// The section can be executed as code.
        pub const IMAGE_SCN_MEM_EXECUTE = 0x20000000;
        /// The section can be read.
        pub const IMAGE_SCN_MEM_READ = 0x40000000;
        /// The section can be written to.
        pub const IMAGE_SCN_MEM_WRITE = 0x80000000;
    };

    /// When a section name contains the symbol `$`, it is considered
    /// a grouped section. e.g. a section named `.text$X` contributes
    /// to the `.text` section within the image.
    /// The character after the dollar sign, indicates the order when
    /// multiple (same prefix) sections were found.
    pub fn isGrouped(header: SectionHeader) bool {
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
        .string_table = undefined,
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

    try parseStringTable(coff);
    try parseSectionTable(coff);
    try parseSectionData(coff);
    try parseRelocations(coff);
    try parseSymbolTable(coff);
}

fn parseStringTable(coff: *Coff) !void {
    const reader = coff.file.reader();
    const current_pos = try coff.file.getPos();
    try coff.file.seekTo(coff.stringTableOffset());
    const size = try reader.readIntLittle(u32);
    const buffer = try coff.allocator.alloc(u8, size - 4); // account for 4 bytes of size field itself
    errdefer coff.allocator.free(buffer);
    try reader.readNoEof(buffer);
    coff.string_table = buffer;
    try coff.file.seekTo(current_pos);
}

fn getString(coff: *const Coff, offset: u32) []const u8 {
    const str = @ptrCast([*:0]const u8, coff.string_table.ptr + offset);
    return std.mem.sliceTo(str, 0);
}

fn parseSectionTable(coff: *Coff) !void {
    if (coff.header.number_of_sections == 0) return;
    try coff.section_table.ensureUnusedCapacity(coff.allocator, coff.header.number_of_sections);
    const reader = coff.file.reader();

    var index: u16 = 0;
    while (index < coff.header.number_of_sections) : (index += 1) {
        const sec_header = coff.section_table.addOneAssumeCapacity();

        var name: [8]u8 = undefined;
        try reader.readNoEof(&name);
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

fn parseSymbolTable(coff: *Coff) !void {
    if (coff.header.number_of_symbols == 0) return;

    try coff.symbols.ensureUnusedCapacity(coff.allocator, coff.header.number_of_symbols);
    try coff.file.seekTo(coff.header.pointer_to_symbol_table);
    const reader = coff.file.reader();

    var index: u32 = 0;
    while (index < coff.header.number_of_symbols) : (index += 1) {
        var name: [8]u8 = undefined;
        try reader.readNoEof(&name);
        const sym: Symbol = .{
            .name = name,
            .value = try reader.readIntLittle(u32),
            .section_number = try reader.readIntLittle(i16),
            .sym_type = try reader.readIntLittle(u16),
            .storage_class = @intToEnum(Symbol.Class, try reader.readByte()),
            .number_aux_symbols = try reader.readByte(),
        };
        coff.symbols.appendAssumeCapacity(sym);
    }
}
