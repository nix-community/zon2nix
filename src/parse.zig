const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const File = std.Io.File;
const Io = std.Io;
const Index = std.zig.Ast.Node.Index;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const string_literal = std.zig.string_literal;
const testing = std.testing;

const Dependency = @import("Dependency.zig");

const zig_legacy_version = (std.SemanticVersion{
    .major = builtin.zig_version.major,
    .minor = builtin.zig_version.minor,
    .patch = builtin.zig_version.patch,
}).order(.{
    .major = 0,
    .minor = 15,
    .patch = 0,
}) == .lt;

pub fn parse(alloc: Allocator, io: Io, deps: *StringHashMap(Dependency), file: File) !void {
    const content = try alloc.allocSentinel(u8, try file.length(io), 0);
    defer alloc.free(content);

    var buffer: [4096]u8 = undefined;

    var reader = file.reader(io, &buffer);
    try reader.interface.readSliceAll(content);

    var ast = try Ast.parse(alloc, content, .zon);
    defer ast.deinit(alloc);

    var root_buf: [2]Index = undefined;
    const root_init = ast.fullStructInit(&root_buf, @field(ast.nodes.items(.data)[0], if (zig_legacy_version) "lhs" else "node")) orelse {
        return error.ParseError;
    };

    for (root_init.ast.fields) |field_idx| {
        const field_name = try parseFieldName(alloc, ast, field_idx);
        defer alloc.free(field_name);

        if (!mem.eql(u8, field_name, "dependencies")) {
            continue;
        }

        var deps_buf: [2]Index = undefined;
        const deps_init = ast.fullStructInit(&deps_buf, field_idx) orelse {
            return error.ParseError;
        };

        for (deps_init.ast.fields) |dep_idx| {
            var hash: ?[]const u8 = null;
            var url: ?[]const u8 = null;

            defer {
                if (url) |u| {
                    alloc.free(u);
                }
            }

            var dep_buf: [2]Index = undefined;
            const dep_init = ast.fullStructInit(&dep_buf, dep_idx) orelse {
                std.log.warn("failed to get dependencies", .{});
                continue;
            };

            for (dep_init.ast.fields) |dep_field_idx| {
                const name = try parseFieldName(alloc, ast, dep_field_idx);
                defer alloc.free(name);

                if (mem.eql(u8, name, "url")) {
                    url = try parseString(alloc, ast, dep_field_idx);
                } else if (mem.eql(u8, name, "hash")) {
                    hash = try parseString(alloc, ast, dep_field_idx);
                }
            }

            if (url != null and hash != null) {
                if (deps.get(hash.?)) |containedDep| {
                    // If this dependency is already known, we don't need to add it again and free new memory right away.
                    defer alloc.free(hash.?);

                    if (comptime @import("builtin").mode == .Debug) {
                        // For safety, we check if the previously known dependency has the same url too.
                        // TODO find a way to get around the creation of a whole new Dependency. This is expensive, i.e. multiple GET requests
                        // for redirect resolution etc
                        const hypotheticalDependency = try Dependency.fromUrl(alloc, io, url.?);
                        defer hypotheticalDependency.deinit(alloc);
                        if (!std.mem.eql(u8, hypotheticalDependency.url, containedDep.url)) {
                            std.log.err("url mismatch for hash {s}, new url: '{s}', contained url: '{s}'", .{
                                hash.?,
                                hypotheticalDependency.url,
                                containedDep.url,
                            });
                            return error.parseError;
                        }
                    }
                } else {
                    const dep = try Dependency.fromUrl(alloc, io, url.?);
                    try deps.put(hash.?, dep);
                }
            } else {
                return error.parseError;
            }
        }
    }
}

fn parseFieldName(alloc: Allocator, ast: Ast, idx: Index) ![]const u8 {
    const name = ast.tokenSlice(ast.firstToken(idx) - 2);
    return if (name[0] == '@') string_literal.parseAlloc(alloc, name[1..]) else alloc.dupe(u8, name);
}

fn parseString(alloc: Allocator, ast: Ast, idx: Index) ![]const u8 {
    return string_literal.parseAlloc(alloc, ast.tokenSlice(ast.nodes.items(.main_token)[if (zig_legacy_version) idx else @intFromEnum(idx)]));
}

test parse {
    const heap = std.heap;
    const io = testing.io;

    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var deps = StringHashMap(Dependency).init(alloc);
    const basic = try Io.Dir.cwd().openFile(io, "fixtures/unittest/basic.zon", .{});
    defer basic.close(io);
    try parse(alloc, io, &deps, basic);

    try testing.expectEqual(deps.count(), 6);
    try testing.expectEqualStrings(deps.get("122048992ca58a78318b6eba4f65c692564be5af3b30fbef50cd4abeda981b2e7fa5").?.url, "https://codeload.github.com/ziglibs/known-folders/tar.gz/fa75e1bc672952efa0cf06160bbd942b47f6d59b");
    try testing.expectEqualStrings(deps.get("122089a8247a693cad53beb161bde6c30f71376cd4298798d45b32740c3581405864").?.url, "https://codeload.github.com/ziglibs/diffz/tar.gz/90353d401c59e2ca5ed0abe5444c29ad3d7489aa");
    try testing.expectEqualStrings(deps.get("1220363c7e27b2d3f39de6ff6e90f9537a0634199860fea237a55ddb1e1717f5d6a5").?.url, "https://codeload.github.com/gist/8372900fcc09e38d7b0b6bbaddad3904/tar.gz/6c3321e0969ff2463f8335da5601986cf2108690");
    const ziggy = deps.get("1220115ff095a3c970cc90fce115294ba67d6fbc4927472dc856abc51e2a1a9364d7").?;
    try testing.expectEqualStrings(ziggy.url, "https://github.com/kristoff-it/ziggy");
    try testing.expectEqualStrings(ziggy.parameters.?.rev, "c66f47bc632c66668d61fa06eda112b41d6e5130");
    const vaxis = deps.get("1220feaa655e14cbb4baf59fe746f09a17fc6949be46ad64dd5044982f4fc1bb57c7").?;
    try testing.expectEqualStrings(vaxis.url, "https://github.com/rockorager/libvaxis");
    try testing.expectEqualStrings(vaxis.parameters.?.rev, "1fd920a7aea1bb040c7c028f4bbf0af2ea58e1d1");
    const zig_tracy = deps.get("122094fc39764bd527269d3721f52fc3b8cbb72bc4cdbd3345cbc2cd941936f3d185").?;
    try testing.expectEqualStrings(zig_tracy.url, "https://github.com/vancluever/zig-tracy?ref=fix-callstack");
    try testing.expectEqualStrings(zig_tracy.parameters.?.rev, "6e123ee26032e49a1a0039524ddf7970692931d9");
}
