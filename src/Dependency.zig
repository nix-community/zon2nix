const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const fmt = std.fmt;

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
    try writer.print("Dependency{{ .url = {s}, .rev = {?s}, .nix_hash = {?s}, .done = {} }}", .{ self.url, self.rev, self.nix_hash, self.done });
}

/// Return the URL to be used with `nix flake prefetch`. The returned string is allocated with `alloc` and owned by the caller,
/// i.e. the caller needs to `free` it with `alloc`.
pub fn flakePrefetchRef(self: Dependency, alloc: Allocator) ![]const u8 {
    const base = base: {
        if (self.rev) |rev| {
            // in case we have a query part, replace it by `?rev=...` since we do have a rev.
            if (mem.lastIndexOf(u8, self.url, "?")) |idx| {
                return try fmt.allocPrint(alloc, "git+{s}?rev={s}", .{ self.url[0..idx], rev });
            }
            break :base try fmt.allocPrint(alloc, "git+{s}?rev={s}", .{ self.url, rev });
        } else {
            break :base try fmt.allocPrint(alloc, "tarball+{s}", .{self.url});
        }
    };

    const revi = mem.lastIndexOf(u8, base, "rev=") orelse return base;
    const refi = mem.lastIndexOf(u8, base, "ref=") orelse return base;

    defer alloc.free(base);

    const i = @min(revi, refi);
    return try alloc.dupe(u8, base[0..(i - 1)]);
}

test flakePrefetchRef {
    const testing = std.testing;
    const allocator = testing.allocator;

    const testCases = .{
        .{ .dep = Dependency{
            .url = "https://github.com/allyourcodebase/harfbuzz",
            .rev = "6bb522d22cee0ce1d1446bd59fa5b0417f25303e",
            .nix_hash = null,
            .done = false,
        }, .expected = "git+https://github.com/allyourcodebase/harfbuzz?rev=6bb522d22cee0ce1d1446bd59fa5b0417f25303e" },
        .{
            .dep = Dependency{
                .url = "https://codeload.github.com/harfbuzz/harfbuzz/tar.gz/refs/tags/8.5.0",
                .rev = null,
                .nix_hash = null,
                .done = false,
            },
            .expected = "tarball+https://codeload.github.com/harfbuzz/harfbuzz/tar.gz/refs/tags/8.5.0",
        },
        .{ .dep = Dependency{
            .url = "https://codeberg.org/7Games/zig-sdl3?ref=v0.1.6",
            .rev = "9c1842246c59f03f87ba59b160ca7e3d5e5ce972",
            .nix_hash = null,
            .done = false,
        }, .expected = "git+https://codeberg.org/7Games/zig-sdl3?rev=9c1842246c59f03f87ba59b160ca7e3d5e5ce972" },
    };

    inline for (testCases) |testcase| {
        const ref = try testcase.dep.flakePrefetchRef(allocator);
        defer allocator.free(ref);

        try testing.expectEqualStrings(testcase.expected, ref);
    }
}
