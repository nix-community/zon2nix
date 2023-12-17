const std = @import("std");
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

    var buf: [2]Index = undefined;
    const root_init = ast.fullStructInit(&buf, ast.nodes.items(.data)[0].lhs) orelse {
        return error.ParseError;
    };

    for (root_init.ast.fields) |field_idx| {
        if (!mem.eql(u8, try parseFieldName(alloc, ast, field_idx), "dependencies")) {
            continue;
        }

        const deps_init = ast.fullStructInit(&buf, field_idx) orelse {
            return error.ParseError;
        };

        for (deps_init.ast.fields) |dep_idx| {
            var dep: Dependency = .{
                .url = undefined,
                .nix_hash = undefined,
                .done = false,
            };
            var hash: []const u8 = undefined;
            var has_url = false;
            var has_hash = false;
            var has_path = false;

            var buf2: [2]Index = undefined;
            const dep_init = ast.fullStructInit(&buf2, dep_idx) orelse {
                return error.parseError;
            };

            for (dep_init.ast.fields) |dep_field_idx| {
                const name = try parseFieldName(alloc, ast, dep_field_idx);

                if (mem.eql(u8, name, "url")) {
                    dep.url = try parseString(alloc, ast, dep_field_idx);
                    has_url = true;
                } else if (mem.eql(u8, name, "hash")) {
                    hash = try parseString(alloc, ast, dep_field_idx);
                    has_hash = true;
                } else if (mem.eql(u8, name, "path")) {
                    has_path = true;
                }
            }

            if (has_url and has_hash) {
                _ = try deps.getOrPutValue(hash, dep);
            } else if (!has_path) {
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

    try testing.expectEqual(deps.count(), 3);
    try testing.expectEqualStrings(deps.get("122048992ca58a78318b6eba4f65c692564be5af3b30fbef50cd4abeda981b2e7fa5").?.url, "https://github.com/ziglibs/known-folders/archive/fa75e1bc672952efa0cf06160bbd942b47f6d59b.tar.gz");
    try testing.expectEqualStrings(deps.get("122089a8247a693cad53beb161bde6c30f71376cd4298798d45b32740c3581405864").?.url, "https://github.com/ziglibs/diffz/archive/90353d401c59e2ca5ed0abe5444c29ad3d7489aa.tar.gz");
    try testing.expectEqualStrings(deps.get("1220363c7e27b2d3f39de6ff6e90f9537a0634199860fea237a55ddb1e1717f5d6a5").?.url, "https://gist.github.com/antlilja/8372900fcc09e38d7b0b6bbaddad3904/archive/6c3321e0969ff2463f8335da5601986cf2108690.tar.gz");
}
