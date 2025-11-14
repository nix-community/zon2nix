const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Follows any redirects caused by GET requests to `url` and returns the final URL.
/// The caller owns return value and needs to dealloc with alloc.
pub fn resolveRedirects(alloc: Allocator, io: Io, url: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var request = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
    defer request.deinit();

    try request.sendBodiless();

    var redirectBuffer: [4096]u8 = undefined;
    const response = try request.receiveHead(&redirectBuffer);
    const head = response.head;
    const class = head.status.class();

    if (class == .redirect) {
        var headerIterator = head.iterateHeaders();
        while (headerIterator.next()) |header| {
            if (std.mem.eql(u8, header.name, "Location")) {
                return resolveRedirects(alloc, io, header.value);
            }
        }
        return error.RedirectWithoutLocationHeader;
    } else {
        const returnedUrl = try alloc.dupe(u8, url);
        return returnedUrl;
    }
}

test "resolveRedirects smoketest" {
    const testing = std.testing;

    const testCases = .{
        "https://codeload.github.com/ziglibs/diffz/tar.gz/90353d401c59e2ca5ed0abe5444c29ad3d7489aa",
        "https://gist.github.com/antlilja/8372900fcc09e38d7b0b6bbaddad3904/archive/6c3321e0969ff2463f8335da5601986cf2108690.tar.gz",
    };

    inline for (testCases) |testcase| {
        const url = try resolveRedirects(testing.allocator, testing.io, testcase);
        defer testing.allocator.free(url);
    }
}
