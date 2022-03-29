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

const Header = struct {
    machine: std.coff.MachineType,
    number_of_sections: u16,
    timedate_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
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
}
