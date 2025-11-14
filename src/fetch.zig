const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;
const StringHashMap = std.StringHashMap;
const Io = std.Io;
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
    child: ChildProcess,
    hash: []const u8,
    flakePrefetchRef: []const u8,

    /// Takes ownership of `child` and duplicates `hash` internally.
    pub fn init(alloc: std.mem.Allocator, child: ChildProcess, hash: []const u8, ref: []const u8) !Worker {
        const zigHash = try alloc.dupe(u8, hash);
        return Worker{ .child = child, .hash = zigHash, .flakePrefetchRef = ref };
    }

    pub fn deinit(self: Worker, alloc: std.mem.Allocator) void {
        alloc.free(self.hash);
        alloc.free(self.flakePrefetchRef);
    }
};

pub fn fetch(alloc: Allocator, io: Io, deps: *StringHashMap(Dependency)) !void {
    var workers = try std.array_list.Managed(Worker).initCapacity(alloc, deps.count());
    defer workers.deinit();
    var done = false;

    while (!done) {
        var iter = deps.iterator();
        while (iter.next()) |entry| {
            const dep = entry.value_ptr;
            if (dep.done) {
                continue;
            }

            const ref = try dep.flakePrefetchRef(alloc);

            log.debug("running \"nix flake prefetch --json --extra-experimental-features 'flakes nix-command' {s}\"", .{ref});
            const argv = &[_][]const u8{ nix, "flake", "prefetch", "--json", "--extra-experimental-features", "flakes nix-command", ref };
            const child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
            const worker = try Worker.init(alloc, child, entry.key_ptr.*, ref);
            try workers.append(worker);
        }

        const len_before = deps.count();
        done = true;

        for (workers.items) |worker| {
            var child = worker.child;
            var dep = deps.getPtr(worker.hash).?;

            defer worker.deinit(alloc);

            var multi_reader: Io.File.MultiReader = undefined;
            var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
            multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
            defer multi_reader.deinit();

            while (multi_reader.fill(1024, .none)) |_| {} else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
            }

            try multi_reader.checkAnyError();

            switch (try child.wait(io)) {
                .exited => |code| if (code != 0) {
                    const stderr_slice = try multi_reader.toOwnedSlice(1);
                    defer alloc.free(stderr_slice);
                    log.err("prefetch for {s} exited with code {}\nstderr:\n{s}", .{
                        worker.flakePrefetchRef,
                        code,
                        stderr_slice,
                    });
                    return error.NixError;
                },
                .signal => |signal| {
                    const stderr_slice = try multi_reader.toOwnedSlice(1);
                    defer alloc.free(stderr_slice);
                    log.err("prefetch for {s} terminated with signal {}\nstderr:\n{s}", .{
                        worker.flakePrefetchRef,
                        signal,
                        stderr_slice,
                    });
                    return error.NixError;
                },
                .stopped, .unknown => {
                    const stderr_slice = try multi_reader.toOwnedSlice(1);
                    defer alloc.free(stderr_slice);
                    log.err("prefetch for {s} finished unsucessfully\nstderr:\n{s}", .{
                        worker.flakePrefetchRef,
                        stderr_slice,
                    });
                    return error.NixError;
                },
            }

            const stdout_slice = try multi_reader.toOwnedSlice(0);
            defer alloc.free(stdout_slice);

            const res = json.parseFromSlice(Prefetch, alloc, stdout_slice, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| {
                log.err("Error in JSON parsing of this payload:\n{s}\ndep: {f}\n", .{ stdout_slice, dep });
                return err;
            };
            defer res.deinit();

            assert(res.value.hash.len != 0);
            log.debug("hash for \"{s}\" is {s}", .{ dep.url, res.value.hash });

            dep.nix_hash = try alloc.dupe(u8, res.value.hash);
            dep.done = true;

            const path = try fmt.allocPrint(alloc, "{s}" ++ fs.path.sep_str ++ "build.zig.zon", .{res.value.storePath});
            defer alloc.free(path);

            const file = Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close(io);

            try parse(alloc, io, deps, file);
            if (deps.count() > len_before) {
                done = false;
            }
        }

        workers.clearRetainingCapacity();
    }
}
