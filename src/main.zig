const builtin = @import("builtin");
const std = @import("std");
const StringHashMap = std.StringHashMap;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const process = std.process;

const Dependency = @import("Dependency.zig");
const fetch = @import("fetch.zig").fetch;
const parse = @import("parse.zig").parse;
const write = @import("codegen.zig").write;

const zig_legacy_version = (std.SemanticVersion{
    .major = builtin.zig_version.major,
    .minor = builtin.zig_version.minor,
    .patch = builtin.zig_version.patch,
}).order(.{
    .major = 0,
    .minor = 14,
    .patch = 0,
}) == .lt;

const DebugAllocator = @field(std.heap, if (zig_legacy_version) "GeneralPurposeAllocator" else "DebugAllocator");

var debug_allocator: DebugAllocator(.{}) = if (zig_legacy_version) .{} else .init;

pub fn main() !void {
    var args = process.args();
    _ = args.skip();
    const dir = fs.cwd();

    const file = try if (args.next()) |path|
        if ((try dir.statFile(path)).kind == .directory)
            (try dir.openDir(path, .{})).openFile("build.zig.zon", .{})
        else
            dir.openFile(path, .{})
    else
        dir.openFile("build.zig.zon", .{});
    defer file.close();

    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var deps = StringHashMap(Dependency).init(gpa);
    defer {
        var iter = deps.iterator();
        while (iter.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        deps.deinit();
    }

    try parse(gpa, &deps, file);
    try fetch(gpa, &deps);

    var out = io.bufferedWriter(io.getStdOut().writer());
    try write(gpa, out.writer(), deps);
    try out.flush();
}

comptime {
    std.testing.refAllDecls(@This());
}
