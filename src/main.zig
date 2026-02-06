const builtin = @import("builtin");
const std = @import("std");
const StringHashMap = std.StringHashMap;
const fs = std.fs;
const heap = std.heap;
const Io = std.Io;
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const dir = std.Io.Dir.cwd();

    const file = try if (args.next()) |path|
        if ((try dir.statFile(io, path, .{})).kind == .directory)
            (try dir.openDir(io, path, .{})).openFile(io, "build.zig.zon", .{})
        else
            dir.openFile(io, path, .{})
    else
        dir.openFile(io, "build.zig.zon", .{});
    defer file.close(io);

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

    try parse(gpa, io, &deps, file);
    try fetch(gpa, io, &deps);

    var buffer: [4096]u8 = undefined;
    var stdoutWriter = Io.File.stdout().writer(io, &buffer);
    const stdout = &stdoutWriter.interface;

    try write(gpa, stdout, deps);
    try stdout.flush();
}

comptime {
    std.testing.refAllDecls(@This());
}
