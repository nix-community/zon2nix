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

    var arena = heap.ArenaAllocator.init(heap.raw_c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var meta = StringHashMap([]const u8).init(alloc);
    var deps = StringHashMap(Dependency).init(alloc);
    try parse(alloc, &meta, &deps, file);
    try fetch(alloc, &deps);

    var out = io.bufferedWriter(io.getStdOut().writer());
    try write(alloc, out.writer(), meta, deps);
    try out.flush();
}

comptime {
    std.testing.refAllDecls(@This());
}
