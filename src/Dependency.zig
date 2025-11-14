const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;

const resolveRedirects = @import("http.zig").resolveRedirects;

const Dependency = @This();

url: []const u8,
parameters: ?Parameters,
nix_hash: ?[]const u8,
done: bool,

/// Additional parameters of the Dependency
pub const Parameters = union(enum) {
    rev: []const u8,
    ref: []const u8,
};

/// Parse the Dependeny from the given URL. It is created with `nix_hash == null` and `done == false`. The
/// caller owns the instance.
pub fn fromUrl(alloc: Allocator, io: Io, url: []const u8) !Dependency {
    const parseResult = try DependencyUrlParseResult.parseUrl(alloc, io, url, .{});
    switch (parseResult) {
        .url => |u| return Dependency{ .url = u, .parameters = null, .nix_hash = null, .done = false },
        .urlRef => |u| return Dependency{ .url = u.url, .parameters = .{ .ref = u.ref }, .nix_hash = null, .done = false },
        .urlRev => |u| return Dependency{ .url = u.url, .parameters = .{ .rev = u.rev }, .nix_hash = null, .done = false },
    }
}

pub fn deinit(self: Dependency, alloc: Allocator) void {
    alloc.free(self.url);
    if (self.parameters) |parameters| switch (parameters) {
        .rev => |rev| alloc.free(rev),
        .ref => |ref| alloc.free(ref),
    };
    if (self.nix_hash) |nix_hash| alloc.free(nix_hash);
}

pub fn format(self: Dependency, writer: *Writer) Writer.Error!void {
    try writer.print("Dependency{{ .url = {s}, .parameters = ", .{self.url});
    if (self.parameters) |parameters| {
        switch (parameters) {
            .rev => |r| try writer.print(".{{ .rev = {s} }}", .{r}),
            .ref => |r| try writer.print(".{{ .ref = {s} }}", .{r}),
        }
    } else {
        try writer.print("null", .{});
    }
    try writer.print(", .nix_hash = {?s}, .done = {} }}", .{ self.nix_hash, self.done });
}

/// Return the URL to be used with `nix flake prefetch`. The returned string is allocated with `alloc` and owned by the caller,
/// i.e. the caller needs to `free` it with `alloc`.
pub fn flakePrefetchRef(self: Dependency, alloc: Allocator) ![]const u8 {
    const base = base: {
        if (self.parameters) |parameters| {
            switch (parameters) {
                .rev => |rev| {
                    // in case we have a query part, replace it by `?rev=...` since we do have a rev.
                    if (mem.lastIndexOf(u8, self.url, "?")) |idx| {
                        return try fmt.allocPrint(alloc, "git+{s}?rev={s}", .{ self.url[0..idx], rev });
                    }
                    break :base try fmt.allocPrint(alloc, "git+{s}?rev={s}", .{ self.url, rev });
                },
                .ref => |ref| {
                    // in case we have a query part, replace it by `?ref=...` since we do have a rev.
                    // The `refs/tags` prefix is required to have older versions of `nix` still understand the
                    // url, see https://github.com/NixOS/nix/issues/5291.
                    if (mem.lastIndexOf(u8, self.url, "?")) |idx| {
                        return try fmt.allocPrint(alloc, "git+{s}?ref=refs/tags/{s}", .{ self.url[0..idx], ref });
                    }
                    break :base try fmt.allocPrint(alloc, "git+{s}?ref=refs/tags/{s}", .{ self.url, ref });
                },
            }
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
    const allocator = testing.allocator;

    const testCases = .{
        .{ .dep = Dependency{
            .url = "https://github.com/allyourcodebase/harfbuzz",
            .parameters = .{ .rev = "6bb522d22cee0ce1d1446bd59fa5b0417f25303e" },
            .nix_hash = null,
            .done = false,
        }, .expected = "git+https://github.com/allyourcodebase/harfbuzz?rev=6bb522d22cee0ce1d1446bd59fa5b0417f25303e" },
        .{
            .dep = Dependency{
                .url = "https://codeload.github.com/harfbuzz/harfbuzz/tar.gz/refs/tags/8.5.0",
                .parameters = null,
                .nix_hash = null,
                .done = false,
            },
            .expected = "tarball+https://codeload.github.com/harfbuzz/harfbuzz/tar.gz/refs/tags/8.5.0",
        },
        .{ .dep = Dependency{
            .url = "https://codeberg.org/7Games/zig-sdl3?ref=v0.1.6",
            .parameters = .{ .rev = "9c1842246c59f03f87ba59b160ca7e3d5e5ce972" },
            .nix_hash = null,
            .done = false,
        }, .expected = "git+https://codeberg.org/7Games/zig-sdl3?rev=9c1842246c59f03f87ba59b160ca7e3d5e5ce972" },
        .{ .dep = Dependency{
            .url = "https://github.com/libsdl-org/SDL_ttf",
            .parameters = .{ .ref = "release-3.2.2" },
            .nix_hash = null,
            .done = false,
        }, .expected = "git+https://github.com/libsdl-org/SDL_ttf?ref=refs/tags/release-3.2.2" },
    };

    inline for (testCases) |testcase| {
        const ref = try testcase.dep.flakePrefetchRef(allocator);
        defer allocator.free(ref);

        try testing.expectEqualStrings(testcase.expected, ref);
    }
}

/// This is a helper struct for parsing a dependency's URL from a build.zig.zon. It
/// Handles the cases where the URL contains optional hashes and refs.
const DependencyUrlParseResult = union(enum) {
    /// Represents a plain URL
    url: []const u8,

    /// Represents an URL with a rev
    urlRev: struct { url: []const u8, rev: []const u8 },

    /// Represents an URL with a ref
    urlRef: struct { url: []const u8, ref: []const u8 },

    pub const ParseOptions = struct {
        /// Wether to resolve redirects. Turning this to `false` is usually only useful for tests.
        resolveUrl: bool = true,
    };

    // Performs the parsing. The caller owns the memory and must free the field inside the returned struct.
    fn parseUrl(alloc: Allocator, io: Io, dependencyUrl: []const u8, options: ParseOptions) !DependencyUrlParseResult {
        if (std.mem.startsWith(u8, dependencyUrl, "https://")) {
            const url = if (options.resolveUrl)
                try resolveRedirects(alloc, io, dependencyUrl)
            else
                try alloc.dupe(u8, dependencyUrl);
            return .{ .url = url };
        } else if (std.mem.startsWith(u8, dependencyUrl, "git+https://")) {
            const url_end = std.mem.indexOf(u8, dependencyUrl[0..], "#").?;
            const raw_url = dependencyUrl[4..url_end];

            const url = if (options.resolveUrl)
                try resolveRedirects(alloc, io, raw_url)
            else
                try alloc.dupe(u8, raw_url);

            const fragment_start = url_end + 1; // +1 to skip the '#'
            const fragment = dependencyUrl[fragment_start..];

            const fragment_copy = try alloc.dupe(u8, fragment);
            // We try to guess if the fragment is a commit or a branch/tag name. This may be a bit brittle, I don't know
            // a better why yet.
            if (std.mem.findLastNone(u8, fragment, "0123456789abcdef")) |_| {
                // It appears to be ref
                return .{ .urlRef = .{ .url = url, .ref = fragment_copy } };
            } else {
                // It appears to be a sha1/sha256 hash
                return .{ .urlRev = .{ .url = url, .rev = fragment_copy } };
            }
        }

        return error.DependencyUrlParseError;
    }
};

test "DependencyUrlParseResult.parseUrl" {
    const alloc = testing.allocator;
    const io = testing.io;

    const testCases = .{
        .{
            // Note that we habe both a `ref` and a SHA1. The SHA1 wins in the sense that this creates a result
            // with a `rev` but no `ref`. This is intended.
            .inputUrl = "git+https://codeberg.org/7Games/zig-sdl3?ref=v0.1.6#9c1842246c59f03f87ba59b160ca7e3d5e5ce972",
            .expected = DependencyUrlParseResult{ .urlRev = .{
                .url = "https://codeberg.org/7Games/zig-sdl3?ref=v0.1.6",
                .rev = "9c1842246c59f03f87ba59b160ca7e3d5e5ce972",
            } },
        },
        .{
            .inputUrl = "git+https://github.com/castholm/SDL.git?ref=v0.4.0%2B3.4.0#ae5deb068787bd71d9aadbc054ff1af54f5d058c",
            .expected = DependencyUrlParseResult{ .urlRev = .{
                .url = "https://github.com/castholm/SDL.git?ref=v0.4.0%2B3.4.0",
                .rev = "ae5deb068787bd71d9aadbc054ff1af54f5d058c",
            } },
        },
        .{ .inputUrl = "https://foo.com/bar/baz.tar.gz", .expected = DependencyUrlParseResult{ .url = "https://foo.com/bar/baz.tar.gz" } },
        .{
            .inputUrl = "git+https://github.com/libsdl-org/SDL_ttf#release-3.2.2",
            .expected = DependencyUrlParseResult{ .urlRef = .{
                .url = "https://github.com/libsdl-org/SDL_ttf",
                .ref = "release-3.2.2",
            } },
        },
    };

    inline for (testCases) |testcase| {
        const result = try DependencyUrlParseResult.parseUrl(alloc, io, testcase.inputUrl, .{ .resolveUrl = false });
        try testing.expect(std.meta.activeTag(testcase.expected) == std.meta.activeTag(result));
        switch (testcase.expected) {
            .url => |u| {
                defer alloc.free(result.url);
                try testing.expectEqualStrings(u, result.url);
            },
            .urlRev => |v| {
                defer alloc.free(result.urlRev.url);
                defer alloc.free(result.urlRev.rev);
                try testing.expectEqualStrings(v.url, result.urlRev.url);
                try testing.expectEqualStrings(v.rev, result.urlRev.rev);
            },
            .urlRef => |v| {
                defer alloc.free(result.urlRef.url);
                defer alloc.free(result.urlRef.ref);
                try testing.expectEqualStrings(v.url, result.urlRef.url);
                try testing.expectEqualStrings(v.ref, result.urlRef.ref);
            },
        }
    }
}
