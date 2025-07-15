const std = @import("std");
const builtin = @import("builtin");
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

const options = @import("options");

const Dependency = @import("Dependency.zig");
const parse = @import("parse.zig").parse;
const narser = @import("narser/src/root.zig");
const git = @import("zig/src/Package/Fetch/git.zig");

const Prefetch = struct {
    hash: []const u8,
    storePath: []const u8,
};

const Worker = struct {
    child: *ChildProcess,
    dep: *Dependency,
};

pub const fetch = if (options.no_nix) fetchNarser else fetchNix;

fn fetchNix(alloc: Allocator, deps: *StringHashMap(Dependency)) !void {
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
            const argv = &[_][]const u8{ options.nix, "flake", "prefetch", "--json", "--extra-experimental-features", "flakes nix-command", ref };
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

fn fetchNarser(alloc: Allocator, deps: *StringHashMap(Dependency)) !void {
    comptime std.debug.assert(builtin.target.os.tag != .windows);
    var iter = deps.valueIterator();

    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });

    while (iter.next()) |dep| {
        const url = url: {
            if (dep.rev) |rev| {
                const stripped = if (mem.indexOfScalar(u8, dep.url, '?')) |index| dep.url[0..index] else dep.url;
                break :url try fmt.allocPrint(alloc, "{s}?rev={s}", .{ stripped, rev });
            } else {
                break :url try alloc.dupe(u8, dep.url);
            }
        };
        defer alloc.free(url);

        var archive_bytes: std.ArrayList(u8) = .init(alloc);
        defer archive_bytes.deinit();

        var sha256_hash: [32]u8 = undefined;

        const val: u32 = @truncate(rng.next());
        var tmp_dir_path: [19]u8 = "/tmp/zon2nix-XXXXXX".*;
        _ = std.fs.base64_encoder.encode(tmp_dir_path[13..], std.mem.asBytes(&val));

        try std.fs.makeDirAbsolute(&tmp_dir_path);
        var tmp_dir = try std.fs.openDirAbsolute(&tmp_dir_path, .{ .iterate = true });
        defer tmp_dir.close();

        var nar_dir: ?std.fs.Dir = null;
        defer if (nar_dir) |*d| d.close();
        defer std.fs.deleteTreeAbsolute(&tmp_dir_path) catch log.err("failed to delete temp dir {s}", .{tmp_dir_path});

        log.debug("fetching {s}", .{url});
        fetch_write_fs: {
            {
                const read_bytes = blk: {
                    const uri = try std.Uri.parse(url);

                    var client: std.http.Client = .{ .allocator = alloc };
                    defer client.deinit();

                    var header_buffer: [8192]u8 = undefined;
                    var second_header_buffer: [8192]u8 = undefined;

                    if (dep.rev) |rev| {
                        var session: git.Session = try .init(alloc, &client, uri, &header_buffer);
                        defer session.deinit();

                        const oid: git.Oid = try .parseAny(rev);

                        var formatted_oid: [git.Oid.max_formatted_length]u8 = undefined;
                        _ = std.fmt.bufPrint(&formatted_oid, "{}", .{oid}) catch unreachable;

                        var fetch_stream = try session.fetch(&.{&formatted_oid}, &second_header_buffer);
                        defer fetch_stream.deinit();

                        var resource: Resource = .{
                            .session = session,
                            .fetch_stream = fetch_stream,
                            .want_oid = oid,
                        };

                        try unpackGitPack(alloc, tmp_dir, &resource);

                        break :fetch_write_fs;
                    } else {
                        var request = try client.open(.GET, uri, .{
                            .keep_alive = false,
                            .server_header_buffer = &header_buffer,
                        });
                        defer request.deinit();

                        try request.send();
                        try request.wait();
                        break :blk try request.reader().readAllAlloc(alloc, std.math.maxInt(usize));
                    }
                };
                defer alloc.free(read_bytes);

                var fbs = std.io.fixedBufferStream(read_bytes);

                // try zstd, xz, gzip, then fall back to none
                var window: [4096]u8 = undefined;

                const State = enum { zstd, xz, gzip, none };
                state: switch (State.zstd) {
                    .zstd => {
                        var decompressor = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = &window });
                        decompressor.reader().readAllArrayList(&archive_bytes, std.math.maxInt(usize)) catch |e|
                            switch (e) {
                                error.OutOfMemory => |err| return err,
                                error.StreamTooLong => unreachable,
                                else => continue :state .xz,
                            };
                        log.debug("compression method is zstd", .{});
                    },
                    .xz => {
                        archive_bytes.clearRetainingCapacity();
                        fbs.reset();
                        var decompressor = std.compress.xz.decompress(alloc, fbs.reader()) catch |e|
                            switch (e) {
                                error.BadHeader => continue :state .gzip,
                                else => return e,
                            };
                        defer decompressor.deinit();

                        decompressor.reader().readAllArrayList(&archive_bytes, std.math.maxInt(usize)) catch |e|
                            switch (e) {
                                error.OutOfMemory => return e,
                                error.StreamTooLong => unreachable,
                                else => continue :state .gzip,
                            };
                        log.debug("compression method is xz", .{});
                    },
                    .gzip => {
                        archive_bytes.clearRetainingCapacity();
                        fbs.reset();
                        var decompressor = std.compress.gzip.decompressor(fbs.reader());
                        decompressor.reader().readAllArrayList(&archive_bytes, std.math.maxInt(usize)) catch |e|
                            switch (e) {
                                error.OutOfMemory => |err| return err,
                                error.StreamTooLong => unreachable,
                                else => continue :state .none,
                            };
                        log.debug("compression method is gzip", .{});
                    },
                    .none => {
                        archive_bytes.clearRetainingCapacity();
                        try archive_bytes.appendSlice(read_bytes);
                        log.debug("no compression", .{});
                    },
                }
            }

            {
                var archive_fbs = std.io.fixedBufferStream(archive_bytes.items);
                std.tar.pipeToFileSystem(tmp_dir, archive_fbs.reader(), .{}) catch |e| switch (e) {
                    error.TarHeader => {
                        archive_fbs.reset();
                        try std.zip.extract(tmp_dir, archive_fbs.seekableStream(), .{});
                    },
                    else => return e,
                };

                var dir_iter = tmp_dir.iterate();
                const entry = try dir_iter.next();

                nar_dir = try tmp_dir.openDir(entry.?.name, .{ .iterate = true });
            }
        }
        {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            try narser.dumpDirectory(alloc, nar_dir orelse tmp_dir, hasher.writer());

            hasher.final(&sha256_hash);
            log.debug("sha256 hash is {s}", .{std.fmt.bytesToHex(sha256_hash, .lower)});
        }

        {
            var base64_hash: [44]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&base64_hash, &sha256_hash);

            const sri_hash = try std.fmt.allocPrint(alloc, "sha256-{s}", .{base64_hash});

            log.debug("SRI hash is {s}\n", .{sri_hash});
            dep.nix_hash = sri_hash;
            dep.done = true;
        }
    }
}

const Resource = struct {
    session: git.Session,
    fetch_stream: git.Session.FetchStream,
    want_oid: git.Oid,
};

/// Modified from `src/Package/Fetch.zig` under the MIT License
fn unpackGitPack(alloc: std.mem.Allocator, out_dir: fs.Dir, resource: *Resource) !void {
    const object_format: git.Oid.Format = resource.want_oid;

    // The .git directory is used to store the packfile and associated index, but
    // we do not attempt to replicate the exact structure of a real .git
    // directory, since that isn't relevant for fetching a package.
    {
        var pack_dir = try out_dir.makeOpenPath(".git", .{});
        defer pack_dir.close();
        var pack_file = try pack_dir.createFile("pkg.pack", .{ .read = true });
        defer pack_file.close();
        var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
        try fifo.pump(resource.fetch_stream.reader(), pack_file.writer());
        try pack_file.sync();

        var index_file = try pack_dir.createFile("pkg.idx", .{ .read = true });
        defer index_file.close();
        {
            var index_buffered_writer = std.io.bufferedWriter(index_file.writer());
            try git.indexPack(alloc, object_format, pack_file, index_buffered_writer.writer());
            try index_buffered_writer.flush();
            try index_file.sync();
        }

        {
            var repository = try git.Repository.init(alloc, object_format, pack_file, index_file);
            defer repository.deinit();
            var diagnostics: git.Diagnostics = .{ .allocator = alloc };
            defer diagnostics.deinit();
            try repository.checkout(out_dir, resource.want_oid, &diagnostics);
        }
    }

    try out_dir.deleteTree(".git");
}
