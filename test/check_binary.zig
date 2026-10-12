//! Check what a binary needs from the system it runs on.
//! usage: check-binary <binary> <major.minor>   fail if it needs a newer glibc than that
//!        check-binary <binary> static          fail if it isn't statically linked
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal("usage: {s} <binary> <major.minor|static>", .{args[0]});

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .unlimited);

    if (std.mem.eql(u8, args[2], "static")) {
        // a dynamically linked binary names its dynamic linker in a PT_INTERP program header
        const header = std.mem.bytesAsValue(std.elf.Elf64.Ehdr, bytes[0..@sizeOf(std.elf.Elf64.Ehdr)]);
        for (0..header.phnum) |i| {
            const at: usize = @intCast(header.phoff + i * header.phentsize);
            const segment = std.mem.bytesAsValue(std.elf.Elf64.Phdr, bytes[at..][0..@sizeOf(std.elf.Elf64.Phdr)]);
            if (segment.type == .INTERP) fatal("binary is not statically linked", .{});
        }
        std.debug.print("static: no dynamic linker needed\n", .{});
        return;
    }

    const want = try parse(args[2]);
    // every glibc symbol version the binary needs is named in its dynamic string table
    var have: [2]u32 = .{ 0, 0 };
    var rest = bytes;
    while (std.mem.find(u8, rest, "GLIBC_")) |at| {
        rest = rest[at + "GLIBC_".len ..];
        const len = std.mem.findNone(u8, rest, "0123456789.") orelse rest.len;
        const version = parse(rest[0..len]) catch continue; // e.g. GLIBC_PRIVATE
        if (newer(version, have)) have = version;
    }

    if (newer(have, want))
        fatal("needs glibc {d}.{d}, target is {d}.{d}", .{ have[0], have[1], want[0], want[1] });
    std.debug.print("glibc: needs {d}.{d} (target {d}.{d})\n", .{ have[0], have[1], want[0], want[1] });
}

fn parse(text: []const u8) ![2]u32 {
    var it = std.mem.splitScalar(u8, text, '.');
    return .{ try std.fmt.parseInt(u32, it.first(), 10), try std.fmt.parseInt(u32, it.next() orelse "0", 10) };
}

fn newer(a: [2]u32, b: [2]u32) bool {
    return a[0] > b[0] or (a[0] == b[0] and a[1] > b[1]);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
