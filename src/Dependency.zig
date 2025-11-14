const std = @import("std");
const Writer = std.Io.Writer;
const Dependency = @This();

url: []const u8,
rev: ?[]const u8,
nix_hash: ?[]const u8,
done: bool,

pub fn deinit(self: Dependency, alloc: std.mem.Allocator) void {
    alloc.free(self.url);
    if (self.rev) |rev| alloc.free(rev);
    if (self.nix_hash) |nix_hash| alloc.free(nix_hash);
}

pub fn format(self: Dependency, writer: *Writer) Writer.Error!void {
    try writer.print("Dependency{{ .url = {s}, .rev = {?s}, .nix_hash = {?s}, .done = {} }}", .{self.url, self.rev, self.nix_hash, self.done});
}
