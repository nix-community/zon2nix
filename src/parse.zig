const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const File = std.fs.File;
const Index = std.zig.Ast.Node.Index;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const string_literal = std.zig.string_literal;

const Dependency = @import("Dependency.zig");

pub fn parse(alloc: Allocator, deps: *StringHashMap(Dependency), file: File) !void {
    const content = try alloc.allocSentinel(u8, try file.getEndPos(), 0);
    _ = try file.reader().readAll(content);

    const ast = try Ast.parse(alloc, content, .zon);

    var root_buf: [2]Index = undefined;
    const root_init = ast.fullStructInit(&root_buf, ast.nodes.items(.data)[0].lhs) orelse {
        return error.ParseError;
    };

    for (root_init.ast.fields) |field_idx| {
        if (!mem.eql(u8, try parseFieldName(alloc, ast, field_idx), "dependencies")) {
            continue;
        }

        var deps_buf: [2]Index = undefined;
        const deps_init = ast.fullStructInit(&deps_buf, field_idx) orelse {
            return error.ParseError;
        };

        for (deps_init.ast.fields) |dep_idx| {
            var dep: Dependency = .{
                .url = undefined,
                .rev = undefined,
                .nix_hash = undefined,
                .done = false,
            };
            var hash: []const u8 = undefined;
            var has_url = false;
            var has_hash = false;

            var dep_buf: [2]Index = undefined;
            const dep_init = ast.fullStructInit(&dep_buf, dep_idx) orelse {
                std.log.warn("failed to get dependencies", .{});
                continue;
            };

            for (dep_init.ast.fields) |dep_field_idx| {
                const name = try parseFieldName(alloc, ast, dep_field_idx);

                if (mem.eql(u8, name, "url")) {
                    const url = try parseString(alloc, ast, dep_field_idx);
                    if (std.mem.startsWith(u8, url, "https://")) {
                        dep.url = url;
                    } else if (std.mem.startsWith(u8, url, "git+https://")) {
                        const url_end = std.mem.indexOf(u8, url[0..], "#").?;
                        const raw_url = url[4..url_end];
                        const hash_start = url_end + 1; // +1 to skip the '#'
                        const git_hash = url[hash_start..];
                        dep.url = raw_url;
                        dep.rev = git_hash;
                    }
                    has_url = true;
                } else if (mem.eql(u8, name, "hash")) {
                    hash = try parseString(alloc, ast, dep_field_idx);
                    assert(hash.len != 0);
                    has_hash = true;
                }
            }

            if (has_url and has_hash) {
                _ = try deps.getOrPutValue(hash, dep);
            } else {
                return error.parseError;
            }
        }
    }
}

fn parseFieldName(alloc: Allocator, ast: Ast, idx: Index) ![]const u8 {
    const name = ast.tokenSlice(ast.firstToken(idx) - 2);
    return if (name[0] == '@') string_literal.parseAlloc(alloc, name[1..]) else name;
}

fn parseString(alloc: Allocator, ast: Ast, idx: Index) ![]const u8 {
    return string_literal.parseAlloc(alloc, ast.tokenSlice(ast.nodes.items(.main_token)[idx]));
}

test parse {
    const fs = std.fs;
    const heap = std.heap;
    const testing = std.testing;

    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var deps = StringHashMap(Dependency).init(alloc);
    const basic = try fs.cwd().openFile("fixtures/basic.zon", .{});
    try parse(alloc, &deps, basic);
    basic.close();

    try testing.expectEqual(deps.count(), 5);
    try testing.expectEqualStrings(deps.get("122048992ca58a78318b6eba4f65c692564be5af3b30fbef50cd4abeda981b2e7fa5").?.url, "https://github.com/ziglibs/known-folders/archive/fa75e1bc672952efa0cf06160bbd942b47f6d59b.tar.gz");
    try testing.expectEqualStrings(deps.get("122089a8247a693cad53beb161bde6c30f71376cd4298798d45b32740c3581405864").?.url, "https://github.com/ziglibs/diffz/archive/90353d401c59e2ca5ed0abe5444c29ad3d7489aa.tar.gz");
    try testing.expectEqualStrings(deps.get("1220363c7e27b2d3f39de6ff6e90f9537a0634199860fea237a55ddb1e1717f5d6a5").?.url, "https://gist.github.com/antlilja/8372900fcc09e38d7b0b6bbaddad3904/archive/6c3321e0969ff2463f8335da5601986cf2108690.tar.gz");
    const ziggy = deps.get("1220115ff095a3c970cc90fce115294ba67d6fbc4927472dc856abc51e2a1a9364d7").?;
    try testing.expectEqualStrings(ziggy.url, "https://github.com/kristoff-it/ziggy");
    try testing.expectEqualStrings(ziggy.rev, "c66f47bc632c66668d61fa06eda112b41d6e5130");
    const vaxis = deps.get("1220feaa655e14cbb4baf59fe746f09a17fc6949be46ad64dd5044982f4fc1bb57c7").?;
    try testing.expectEqualStrings(vaxis.url, "https://github.com/rockorager/libvaxis");
    try testing.expectEqualStrings(vaxis.rev, "1fd920a7aea1bb040c7c028f4bbf0af2ea58e1d1");
}
