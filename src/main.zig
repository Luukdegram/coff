const std = @import("std");
const Coff = @import("Coff.zig");
const mem = std.mem;

const io = std.io;

var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_allocator.allocator();

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@import("build_flags").enable_logging) {
        std.log.defaultLog(level, scope, format, args);
    }
}

const usage =
    \\Usage: coff [options] [files...]
    \\
    \\Options:
    \\-H, --help                         Print this help and exit
    \\-h, --headers-only                 Print the file headers of the object file
;

pub fn main() !void {
    defer if (@import("builtin").mode == .Debug) {
        _ = gpa_allocator.deinit();
    };

    // we use arena for the arguments and its parsing
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const process_args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, process_args);

    const args = process_args[1..]; // exclude 'coff' binary
    if (args.len == 0) {
        printHelpAndExit();
    }

    var positionals = std.ArrayList([]const u8).init(arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "-H") or mem.eql(u8, arg, "--help")) {
            printHelpAndExit();
        }
        if (mem.startsWith(u8, arg, "--")) {
            printErrorAndExit("Unknown argument '{s}'", .{arg});
        }
        try positionals.append(arg);
    }

    if (positionals.items.len == 0) {
        printErrorAndExit("Expected one or more object files, none were given", .{});
    }

    for (positionals.items) |path| {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var coff = Coff.init(arena, file, path);
        defer coff.deinit();
        try coff.parse();
    }
}

fn printHelpAndExit() noreturn {
    io.getStdOut().writer().print("{s}\n", .{usage}) catch {};
    std.process.exit(0);
}

fn printErrorAndExit(comptime fmt: []const u8, args: anytype) noreturn {
    const writer = io.getStdErr().writer();
    writer.print(fmt, args) catch {};
    writer.writeByte('\n') catch {};
    std.process.exit(1);
}
