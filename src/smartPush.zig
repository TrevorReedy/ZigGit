const std = @import("std");
const git = @import("./git.zig");
const COLOR = @import("./COLOR.zig");

const Allocator = std.mem.Allocator;
pub const PushErr = git.GitErr;

fn askYesNoDefaultNo(prompt: []const u8) bool {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    stdout.print("{s}", .{prompt}) catch {};

    var buf: [32]u8 = undefined;
    const maybe_line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return false;
    const line = maybe_line orelse return false;

    if (line.len == 0) return false;
    const c = std.ascii.toLower(line[0]);
    return c == 'y';
}

fn getCommitsToPush(
    alloc: Allocator,
    repo_path: []const u8,
    upstream: []const u8,
) PushErr![]const []const u8 {
    const spec = try std.fmt.allocPrint(alloc, "{s}..HEAD", .{upstream});
    defer alloc.free(spec);

    const raw = try git.runGit(true, alloc, repo_path, &[_][]const u8{
        "log", "--oneline", spec,
    }, .{});
    defer alloc.free(raw);

    var lines = std.ArrayList([]const u8).init(alloc);

    var it = std.mem.splitAny(u8, raw, "\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len != 0) {
            // copy each line into its own allocation
            const copy = try alloc.dupe(u8, trimmed);
            try lines.append(copy);
        }
    }

    return lines.toOwnedSlice();
}

fn getFilesChanged(
    alloc: Allocator,
    repo_path: []const u8,
    upstream: []const u8,
) PushErr![]const []const u8 {
    const spec = try std.fmt.allocPrint(alloc, "{s}..HEAD", .{upstream});
    defer alloc.free(spec);

    const raw = try git.runGit(true, alloc, repo_path, &[_][]const u8{
        "diff", "--name-only", spec,
    }, .{});
    defer alloc.free(raw);

    var lines = std.ArrayList([]const u8).init(alloc);

    var it = std.mem.splitAny(u8, raw, "\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len != 0) {
            const copy = try alloc.dupe(u8, trimmed);
            try lines.append(copy);
        }
    }

    return lines.toOwnedSlice();
}

fn pushTypeFromAheadBehind(ahead: usize, behind: usize) []const u8 {
    if (behind > 0 and ahead > 0) return "NON-FAST-FORWARD (diverged)";
    if (behind > 0) return "REJECT (remote ahead)";
    if (ahead > 0) return "FAST-FORWARD";
    return "NOTHING TO PUSH";
}

pub fn push(
    alloc: Allocator,
    repo_path: []const u8,
) PushErr!void {
    // 1) Prove repo + normalize path
    try git.ensureRepo(alloc, repo_path);

    const root = try git.getRepoRoot(alloc, repo_path);
    defer alloc.free(root);

    // 2) Current branch
    const branch = try git.getCurrentBranch(alloc, repo_path);
    defer alloc.free(branch);

    if (std.mem.eql(u8, branch, "HEAD")) {
        COLOR.RED.apply("You are in a detached HEAD state; refusing to push.\n");
        return;
    }

    // 3) Upstream (may be missing)
    var has_upstream: bool = true;
    var upstream: []const u8 = "";
    var upstream_is_allocated = false;

    const upstream_res = git.getUpstream(alloc, repo_path) catch |err| switch (err) {
        error.NoUpstream => "",
        else => return err,
    };

    if (upstream_res.len != 0) {
        upstream = upstream_res;
        upstream_is_allocated = true;
    } else {
        has_upstream = false;
    }

    defer {
        if (upstream_is_allocated) {
            // Only free if it actually came from getUpstream
            alloc.free(upstream_res);
        }
    }

    // 4) Ahead/behind (be defensive re: NoUpstream)
    const ab = git.aheadBehind(alloc, repo_path) catch |err| switch (err) {
        error.NoUpstream => git.AheadBehind{ .ahead = 0, .behind = 0 },
        else => return err,
    };
    const push_type = pushTypeFromAheadBehind(ab.ahead, ab.behind);

    // 5) Compute commits/files only if we have a real upstream
    var commits: []const []const u8 = &[_][]const u8{};
    var files: []const []const u8 = &[_][]const u8{};

    if (has_upstream and upstream.len != 0) {
        commits = try getCommitsToPush(alloc, root, upstream);
        files = try getFilesChanged(alloc, root, upstream);
    }

    defer {
        if (commits.len != 0) {
            for (commits) |c| alloc.free(c);
            alloc.free(commits);
        }
        if (files.len != 0) {
            for (files) |f| alloc.free(f);
            alloc.free(files);
        }
    }

    // 6) Display preview
    COLOR.CYAN.apply("You are about to push from branch: ");
    COLOR.YELLOW.apply(branch);
    COLOR.CYAN.apply("\n");

    if (has_upstream and upstream.len != 0) {
        COLOR.CYAN.apply("Upstream: ");
        COLOR.YELLOW.apply(upstream);
        COLOR.CYAN.apply("\n");
    } else {
        COLOR.YELLOW.apply("No upstream configured; will push with -u origin/<branch>.\n");
    }

    COLOR.CYAN.apply("-------------------------------------------------\n");

    COLOR.GREEN.apply("Push type: ");
    COLOR.WHITE.apply(push_type);
    COLOR.WHITE.apply("\n");

    COLOR.GREEN.apply("Local commits to upload");
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " ({d})", .{ab.ahead}) catch " (?)";
        COLOR.WHITE.apply(s);
    }
    COLOR.WHITE.apply(":\n");

    if (commits.len == 0) {
        COLOR.YELLOW.apply("  (No new commits or no upstream to compare.)\n");
    } else {
        for (commits) |c| {
            COLOR.WHITE.apply("  • ");
            COLOR.GREEN.apply(c);
            COLOR.WHITE.apply("\n");
        }
    }

    COLOR.GREEN.apply("\nFiles changed:\n");
    if (files.len == 0) {
        COLOR.YELLOW.apply("  (No file changes or no upstream to compare.)\n");
    } else {
        for (files) |f| {
            COLOR.WHITE.apply("  • ");
            COLOR.YELLOW.apply(f);
            COLOR.WHITE.apply("\n");
        }
    }

    COLOR.WHITE.apply("\nRemote ahead? ");
    COLOR.YELLOW.apply(if (ab.behind > 0) "YES" else "NO");
    COLOR.WHITE.apply("\nLocal behind? ");
    COLOR.YELLOW.apply(if (ab.behind > 0) "YES" else "NO");
    COLOR.WHITE.apply("\n-------------------------------------------------\n");

    // 7) Confirm
    if (!askYesNoDefaultNo("Proceed with push? (y/N): ")) {
        COLOR.RED.apply("Push cancelled.\n");
        return;
    }

    // 8) Actual push
    if (has_upstream and upstream.len != 0) {
        // Upstream configured; let git handle remote/branch
        try git.runGit(false, alloc, root, &[_][]const u8{"push"}, .{});
    } else {
        // First push: set upstream to origin/<branch>
        try git.runGit(false, alloc, root, &[_][]const u8{
            "push", "-u", "origin", branch,
        }, .{});
    }

    COLOR.GREEN.apply("✓ Push completed successfully.\n");
}
