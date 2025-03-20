const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ChildProcess = std.process.Child;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const json = std.json;
const log = std.log;

const nix = @import("options").nix;

const Dependency = @import("Dependency.zig");
const parse = @import("parse.zig").parse;

const Prefetch = struct {
    hash: []const u8,
    storePath: []const u8,
};

const Worker = struct {
    child: *ChildProcess,
    dep: *Dependency,
};

pub fn fetch(alloc: Allocator, deps: *StringHashMap(Dependency)) !void {
    var workers = try ArrayList(Worker).initCapacity(alloc, deps.count());
    defer workers.deinit();
    var done = false;

    while (!done) {
        var iter = deps.valueIterator();
        while (iter.next()) |dep| {
            if (dep.done) {
                continue;
            }

            var child = try alloc.create(ChildProcess);
            const ref = ref: {
                const base = base: {
                    if (dep.rev) |rev| {
                        break :base try fmt.allocPrint(alloc, "git+{s}?rev={s}", .{ dep.url, rev });
                    } else {
                        break :base try fmt.allocPrint(alloc, "tarball+{s}", .{dep.url});
                    }
                };

                const revi = mem.lastIndexOf(u8, base, "rev=") orelse break :ref base;
                const refi = mem.lastIndexOf(u8, base, "ref=") orelse break :ref base;

                defer alloc.free(base);

                const i = @min(revi, refi);
                break :ref try alloc.dupe(u8, base[0..(i - 1)]);
            };
            defer alloc.free(ref);

            log.debug("running \"nix flake prefetch --json --extra-experimental-features 'flakes nix-command' {s}\"", .{ref});
            const argv = &[_][]const u8{ nix, "flake", "prefetch", "--json", "--extra-experimental-features", "flakes nix-command", ref };
            child.* = ChildProcess.init(argv, alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            try child.spawn();
            try workers.append(.{ .child = child, .dep = dep });
        }

        const len_before = deps.count();
        done = true;

        for (workers.items) |worker| {
            const child = worker.child;
            const dep = worker.dep;

            defer alloc.destroy(child);

            const buf = try child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize));
            defer alloc.free(buf);

            log.debug("nix prefetch for \"{s}\" returned: {s}", .{ dep.url, buf });

            const res = try json.parseFromSlice(Prefetch, alloc, buf, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            defer res.deinit();

            switch (try child.wait()) {
                .Exited => |code| if (code != 0) {
                    log.err("{s} exited with code {}", .{ child.argv, code });
                    return error.NixError;
                },
                .Signal => |signal| {
                    log.err("{s} terminated with signal {}", .{ child.argv, signal });
                    return error.NixError;
                },
                .Stopped, .Unknown => {
                    log.err("{s} finished unsuccessfully", .{child.argv});
                    return error.NixError;
                },
            }

            assert(res.value.hash.len != 0);
            log.debug("hash for \"{s}\" is {s}", .{ dep.url, res.value.hash });

            dep.nix_hash = try alloc.dupe(u8, res.value.hash);
            dep.done = true;

            const path = try fmt.allocPrint(alloc, "{s}" ++ fs.path.sep_str ++ "build.zig.zon", .{res.value.storePath});
            defer alloc.free(path);

            const file = fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close();

            try parse(alloc, deps, file);
            if (deps.count() > len_before) {
                done = false;
            }
        }

        workers.clearRetainingCapacity();
    }
}
