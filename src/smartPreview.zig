const std = @import("std");

const GitErr = error{ NoGit, BadStatus, GitFailed };

fn trimNl(s: []u8) []u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

fn runGit(
    comptime WantOut: bool,
    alloc: std.mem.Allocator,
    repo_path: []const u8,
    args: []const []const u8,
) !if (WantOut) []u8 else void {
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.appendSlice(&[_][]const u8{ "git", "-C", repo_path });
    try argv.appendSlice(args);

    if (WantOut) {
        // Capture mode: return stdout to caller
        const res = try std.ChildProcess.exec(.{
            .allocator = alloc,
            .argv = argv.items,
            .max_output_bytes = 1 << 20,
        });
        defer alloc.free(res.stderr);
        errdefer alloc.free(res.stdout);

        switch (res.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("GitFailed: argv={any}\nexit={d}\nstderr:\n{s}\n", .{ argv.items, code, res.stderr });
                return GitErr.GitFailed;
            },
            else => {
                std.debug.print("GitFailed: abnormal termination. argv={any}\n", .{argv.items});
                return GitErr.GitFailed;
            },
        }
        return res.stdout; // caller frees
    } else {
        // Passthrough path using std.ChildProcess WITHOUT deinit()
        var child = std.ChildProcess.init(argv.items, alloc);

        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit; // stream directly to parent stdout
        child.stderr_behavior = .Pipe; // we’ll read and then close it

        try child.spawn();
        const term = try child.wait();

        // Safely read and close stderr pipe (avoid FD leaks)
        var err_bytes: []u8 = &[_]u8{};
        if (child.stderr) |*pipe| {
            err_bytes = try pipe.reader().readAllAlloc(alloc, 1 << 20);
            pipe.close(); // explicit close since there's no child.deinit()
        }
        defer if (err_bytes.len != 0) alloc.free(err_bytes);

        switch (term) {
            .Exited => |code| if (code != 0) {
                std.debug.print(
                    "GitFailed: argv={any}\nexit={d}\nstderr:\n{s}\n",
                    .{ argv.items, code, err_bytes },
                );
                return GitErr.GitFailed;
            },
            else => {
                std.debug.print("GitFailed: abnormal termination. argv={any}\n", .{argv.items});
                return GitErr.GitFailed;
            },
        }
        return;
    }
}

pub fn previewCommit(
    alloc: std.mem.Allocator,
    repo_path: []const u8,
    message: ?[]const u8,
    show_diffstat: bool,
) ![]u8 {
    // HEAD branch name (optional; detached or unborn HEAD -> null)
    var head_branch_out: ?[]u8 =
        runGit(true, alloc, repo_path, &[_][]const u8{ "symbolic-ref", "-q", "--short", "HEAD" }) catch null;
    defer if (head_branch_out) |buf| alloc.free(buf);

    var head_branch: ?[]u8 = null;
    if (head_branch_out) |buf| head_branch = trimNl(buf);

    // Parent commit SHA (optional; unborn HEAD -> null)
    var old_sha_out: ?[]u8 =
        runGit(true, alloc, repo_path, &[_][]const u8{ "rev-parse", "--verify", "HEAD" }) catch null;
    defer if (old_sha_out) |buf| alloc.free(buf);

    var parent_sha: ?[]u8 = null;
    if (old_sha_out) |buf| parent_sha = trimNl(buf);

    // Current index tree
    var tree_out = try runGit(true, alloc, repo_path, &[_][]const u8{"write-tree"});
    defer alloc.free(tree_out);
    const tree_sha = trimNl(tree_out);

    // Build commit-tree argv
    const msg = message orelse "(no message)";
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.appendSlice(&[_][]const u8{ "commit-tree", tree_sha });
    if (parent_sha) |p| try argv.appendSlice(&[_][]const u8{ "-p", p });
    try argv.appendSlice(&[_][]const u8{ "-m", msg });

    // Create the commit object (not updating refs)
    const commit_out = try runGit(true, alloc, repo_path, argv.items);
    const commit_sha = trimNl(commit_out);

    // Optional diffstat preview
    if (show_diffstat) {
        if (parent_sha != null) {
            // no pager, no color -> clean ASCII
            runGit(false, alloc, repo_path, &[_][]const u8{
                "-c",         "core.pager=cat",
                "-c",         "color.ui=false",
                "diff",       "--stat",
                "--no-color", "HEAD",
                commit_sha,
            }) catch {};
        } else {
            runGit(false, alloc, repo_path, &[_][]const u8{
                "-c",         "core.pager=cat",
                "-c",         "color.ui=false",
                "show",       "--stat",
                "--no-color", commit_sha,
            }) catch {};
        }
    }

    // Friendly short SHA if we had a branch name
    if (head_branch) |_| {
        var short_sha_opt: ?[]u8 =
            runGit(true, alloc, repo_path, &[_][]const u8{ "rev-parse", "--short", commit_sha }) catch null;
        defer if (short_sha_opt) |s| alloc.free(s);

        if (short_sha_opt) |s| {
            std.debug.print("Preview commit {s} for branch {s}\n", .{ trimNl(s), head_branch.? });
            try runGit(false, alloc, repo_path, &[_][]const u8{
                "-c",   "core.pager=cat",
                "-c",   "color.ui=false",
                "diff", "--cached",
                "-p",
            });
        } else {
            const n = if (commit_sha.len >= 7) 7 else commit_sha.len;
            std.debug.print("Preview commit {s} for branch {s}\n", .{ commit_sha[0..n], head_branch.? });
        }
    }

    // Return the raw commit SHA (caller must free)
    return commit_out;
}
