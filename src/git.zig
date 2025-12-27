const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = std.mem.Allocator;

pub const GitErr = anyerror;
/// Options for running git
pub const GitOptions = struct {
    /// If true, print the underlying `git -C ...` command before running.
    show_calls: bool = false,
};

pub fn runGit(
    comptime WantOut: bool,
    alloc: Allocator,
    repo_path: []const u8,
    tail_argv: []const []const u8,
    opts: GitOptions,
) GitErr!if (WantOut) []u8 else void {
    // Optional debug print for the git command
    if (opts.show_calls) {
        std.debug.print("CALL: git -C '{s}'", .{repo_path});
        for (tail_argv) |a| {
            std.debug.print(" '{s}'", .{a});
        }
        std.debug.print("\n", .{});
    }

    // Build argv = ["git", "-C", repo_path] ++ tail_argv
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();

    try argv.ensureTotalCapacity(3 + tail_argv.len);
    try argv.appendSlice(&[_][]const u8{ "git", "-C", repo_path });
    try argv.appendSlice(tail_argv);

    // Exec
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = argv.items,
        .max_output_bytes = 1 << 20,
        // stdout/stderr default to .Pipe, which is what we want
    });
    defer alloc.free(res.stderr);

    switch (res.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print(
                "GitFailed: argv={any}\nexit={d}\nstderr:\n{s}\n",
                .{ argv.items, code, res.stderr },
            );
            alloc.free(res.stdout);
            return GitErr.GitFailed;
        },
        else => {
            std.debug.print(
                "GitFailed: abnormal termination. argv={any}\n",
                .{argv.items},
            );
            alloc.free(res.stdout);
            return GitErr.GitFailed;
        },
    }

    if (WantOut) {
        return res.stdout;
    }

    alloc.free(res.stdout);
}

/// Verify that `path` is inside a git work tree.
pub fn ensureRepo(alloc: Allocator, path: []const u8) GitErr!void {
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{ "git", "-C", path, "rev-parse", "--is-inside-work-tree" },
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    var ok = false;
    switch (res.term) {
        .Exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
                ok = std.mem.eql(u8, trimmed, "true");
            }
        },
        else => {},
    }
    if (!ok) return GitErr.NoGit;
}

/// Refresh the index: `git update-index -q --refresh`
pub fn updateIndex(alloc: Allocator, repo_path: []const u8) GitErr!void {
    // Best-effort: if this fails, log and continue.
    _ = runGit(false, alloc, repo_path, &[_][]const u8{
        "update-index", "-q", "--refresh",
    }, .{}) catch |err| {
        // Debug-only; you can comment this out later.
        std.debug.print("update-index ignored failure: {s}\n", .{@errorName(err)});
        return;
    };
}

/// `git status --porcelain -z`
pub fn statusPorcelainZ(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    return runGit(true, alloc, repo_path, &[_][]const u8{
        "status", "--porcelain", "-z",
    }, .{});
}

/// Unstaged diff: `git diff`
pub fn diffUnstaged(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    return runGit(true, alloc, repo_path, &[_][]const u8{
        "diff",
    }, .{});
}

/// Staged files: `git diff --cached --name-only --ignore-submodules --`
pub fn diffCachedNameOnly(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    return runGit(true, alloc, repo_path, &[_][]const u8{
        "diff", "--cached", "--name-only", "--ignore-submodules", "--",
    }, .{});
}

/// Staged conflicts: `git diff --cached --name-only --diff-filter=U`
pub fn diffCachedConflicts(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    return runGit(true, alloc, repo_path, &[_][]const u8{
        "diff", "--cached", "--name-only", "--diff-filter=U",
    }, .{});
}

/// `git add -A`
pub fn addAll(alloc: Allocator, repo_path: []const u8) GitErr!void {
    try runGit(false, alloc, repo_path, &[_][]const u8{
        "add", "-A",
    }, .{});
}

/// `git commit -m <msg>`
pub fn commitWithMessage(
    alloc: Allocator,
    repo_path: []const u8,
    msg: []const u8,
) GitErr!void {
    try runGit(false, alloc, repo_path, &[_][]const u8{
        "commit", "-m", msg,
    }, .{});
}

pub fn pushDirect(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    try runGit(false, alloc, repo_path, &[_][]const u8{
        "push",
    }, .{});
}

pub const AheadBehind = struct { ahead: usize, behind: usize };

/// Get upstream ref (may error with NoUpstream).
pub fn getUpstream(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{
            "git",       "-C",           repo_path,
            "rev-parse", "--abbrev-ref", "--symbolic-full-name",
            "@{u}",
        },
        .max_output_bytes = 1 << 16,
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    switch (res.term) {
        .Exited => |code| {
            if (code != 0) {
                if (std.mem.indexOf(u8, res.stderr, "no upstream") != null)
                    return GitErr.NoUpstream;
                return GitErr.GitFailed;
            }
        },
        else => return GitErr.GitFailed,
    }

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    return alloc.dupe(u8, trimmed) catch return GitErr.OutOfMemory;
}

/// ahead/behind vs upstream
pub fn aheadBehind(alloc: Allocator, repo_path: []const u8) GitErr!AheadBehind {
    const upstream = try getUpstream(alloc, repo_path);
    defer alloc.free(upstream);

    const spec = std.fmt.allocPrint(alloc, "{s}...HEAD", .{upstream}) catch return GitErr.OutOfMemory;
    defer alloc.free(spec);

    const out = try runGit(true, alloc, repo_path, &[_][]const u8{
        "rev-list", "--left-right", "--count", spec,
    }, .{});
    defer alloc.free(out);

    const trimmed = std.mem.trimRight(u8, out, "\r\n");
    var it = std.mem.splitAny(u8, trimmed, " \t");

    const behind = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch return GitErr.GitFailed;
    const ahead = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch return GitErr.GitFailed;

    return AheadBehind{ .ahead = ahead, .behind = behind };
}
/// Get canonical repo root: `git rev-parse --show-toplevel`
pub fn getRepoRoot(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{
            "git", "-C", repo_path, "rev-parse", "--show-toplevel",
        },
        .max_output_bytes = 1 << 16,
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    switch (res.term) {
        .Exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    return alloc.dupe(u8, trimmed) catch return error.OutOfMemory;
}

/// Get current branch: `git rev-parse --abbrev-ref HEAD`
/// If HEAD is detached, this returns "HEAD".
pub fn getCurrentBranch(alloc: Allocator, repo_path: []const u8) GitErr![]u8 {
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{
            "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD",
        },
        .max_output_bytes = 1 << 16,
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    switch (res.term) {
        .Exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    return alloc.dupe(u8, trimmed) catch return error.OutOfMemory;
}
// pub fn os_check() []const u8 {
//     return switch (builtin.target.os.tag) {
//         .windows => "Target OS: Windows\n",
//         .linux => "Target OS: Linux\n",
//         .macos => "Target OS: MacOS\n",
//         else => "Target OS: Unknown or unsupported\n",
//     };
// }
