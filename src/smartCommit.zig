const std = @import("std");

pub const CommitErr = error{
    GitFailed,
    OutOfMemory,
    NoUpstream,
    InputOutput,
    SystemResources,
    OperationAborted,
    BrokenPipe,
    Unexpected,
};

const Allocator = std.mem.Allocator;

//
// COLOR HELPERS
//
const Color = struct {
    code: []const u8,

    pub fn apply(self: Color, text: []const u8) void {
        const stdout = std.io.getStdOut().writer();
        _ = stdout.print("{s}{s}\x1b[0m", .{ self.code, text }) catch {};
    }
};

const RED = Color{ .code = "\x1b[31m" };
const GREEN = Color{ .code = "\x1b[32m" };
const YELLOW = Color{ .code = "\x1b[33m" };

fn info(text: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    _ = stdout.print("{s}\n", .{text}) catch {};
}

//
// RUN GIT COMMAND
//
const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn run(alloc: Allocator, args: []const []const u8) CommitErr!RunResult {
    var child = std.process.Child.init(args, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return CommitErr.GitFailed;

    const stdout = child.stdout.?.reader();
    const stderr = child.stderr.?.reader();

    const stdout_buf = stdout.readAllAlloc(alloc, 1024 * 1024) catch return CommitErr.GitFailed;
    const stderr_buf = stderr.readAllAlloc(alloc, 1024 * 1024) catch return CommitErr.GitFailed;

    const term = child.wait() catch return CommitErr.GitFailed;

    return RunResult{
        .term = term,
        .stdout = stdout_buf,
        .stderr = stderr_buf,
    };
}

fn requireZeroExit(res: RunResult) CommitErr!void {
    switch (res.term) {
        .Exited => |code| {
            if (code != 0) return CommitErr.GitFailed;
        },
        else => return CommitErr.GitFailed,
    }
}

//
// PROMPT USER FOR MESSAGE
//
fn promptForCommitMessage(alloc: std.mem.Allocator) CommitErr![]u8 {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    stdout.print("Enter commit message: ", .{}) catch return CommitErr.InputOutput;

    var buf: [4096]u8 = undefined;
    const maybe_line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return CommitErr.InputOutput;

    const line = maybe_line orelse "";
    const trimmed = std.mem.trimRight(u8, line, "\r\n");

    return alloc.dupe(u8, trimmed) catch return CommitErr.OutOfMemory;
}

//
// CHECK STAGED
//
fn hasStagedChanges(alloc: Allocator, repo_path: []const u8) CommitErr!bool {
    const res = try run(alloc, &[_][]const u8{
        "git", "-C", repo_path, "diff", "--cached", "--name-only", "--ignore-submodules", "--",
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    try requireZeroExit(res);
    return std.mem.trimRight(u8, res.stdout, "\r\n").len != 0;
}

//
// CHECK CONFLICTS
//
fn hasConflictsInIndex(alloc: Allocator, repo_path: []const u8) CommitErr!bool {
    const res = try run(alloc, &[_][]const u8{
        "git", "-C", repo_path, "diff", "--cached", "--name-only", "--diff-filter=U",
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    try requireZeroExit(res);
    return std.mem.trimRight(u8, res.stdout, "\r\n").len != 0;
}

//
// UPSTREAM DETECTION (NoUpstream is NOT fatal)
//
fn getUpstreamOrDefault(alloc: Allocator, repo_path: []const u8) CommitErr![]u8 {
    const res = try run(alloc, &[_][]const u8{
        "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}",
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    switch (res.term) {
        .Exited => |code| {
            if (code != 0) {
                if (std.mem.indexOf(u8, res.stderr, "no upstream") != null) {
                    RED.apply("WARNING: NO UPSTREAM TO GITHUB SET\n");
                    return CommitErr.NoUpstream;
                }
                return CommitErr.GitFailed;
            }
        },
        else => return CommitErr.GitFailed,
    }

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    return alloc.dupe(u8, trimmed) catch return CommitErr.OutOfMemory;
}

//
// SIMPLE AHEAD/BEHIND (returns 0,0 if no upstream)
//
const AheadBehind = struct { ahead: usize, behind: usize };

fn aheadBehind(alloc: Allocator, repo_path: []const u8) CommitErr!AheadBehind {
    const upstream = getUpstreamOrDefault(alloc, repo_path) catch |err| switch (err) {
        CommitErr.NoUpstream => return AheadBehind{ .ahead = 0, .behind = 0 },
        else => return err,
    };
    defer alloc.free(upstream);

    const cmd = std.fmt.allocPrint(alloc, "{s}...HEAD", .{upstream}) catch return CommitErr.OutOfMemory;
    defer alloc.free(cmd);

    const res = try run(alloc, &[_][]const u8{
        "git", "-C", repo_path, "rev-list", "--left-right", "--count", cmd,
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    try requireZeroExit(res);

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    var it = std.mem.splitAny(u8, trimmed, " \t");

    const behind = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch return CommitErr.GitFailed;
    const ahead = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch return CommitErr.GitFailed;

    return AheadBehind{ .ahead = ahead, .behind = behind };
}

//
// DO THE COMMIT
//
fn ensureCommit(
    alloc: Allocator,
    repo_path: []const u8,
    msg: []const u8,
) CommitErr!void {
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();

    try argv.appendSlice(&.{ "git", "-C", repo_path, "commit", "-m", msg });

    const res = try run(alloc, argv.items);
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    try requireZeroExit(res);

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    if (trimmed.len != 0) info(trimmed);
}

//
// MAIN ENTRY POINT
//
pub fn commit(
    alloc: Allocator,
    repo_path: []const u8,
    msg: ?[]const u8,
) CommitErr!void {
    // Refresh index
    {
        const res = try run(alloc, &[_][]const u8{
            "git", "-C", repo_path, "update-index", "-q", "--refresh",
        });
        defer {
            alloc.free(res.stdout);
            alloc.free(res.stderr);
        }
        try requireZeroExit(res);
    }

    // Check staged
    if (!try hasStagedChanges(alloc, repo_path)) {
        YELLOW.apply("Nothing staged to commit.\n");
        return;
    }

    // Check conflicts
    if (try hasConflictsInIndex(alloc, repo_path)) {
        RED.apply("Resolve conflicts in index before committing.\n");
        return;
    }

    // Acquire commit message
    var final_msg = msg;
    var allocated_msg = false;
    if (final_msg == null) {
        final_msg = try promptForCommitMessage(alloc);
        allocated_msg = true;
    }
    defer {
        if (allocated_msg) {
            alloc.free(final_msg.?);
        }
    }

    // Commit (even with no upstream!)
    try ensureCommit(alloc, repo_path, final_msg.?);

    // After-commit status
    const ab = aheadBehind(alloc, repo_path) catch {
        GREEN.apply("Commit created.\n");
        return;
    };

    if (ab.behind == 0 and ab.ahead == 0) {
        GREEN.apply("Committed on top of up-to-date upstream.\n");
    } else if (ab.ahead > 0 and ab.behind == 0) {
        GREEN.apply("Committed; branch ahead of upstream.\n");
    } else if (ab.behind > 0 and ab.ahead == 0) {
        YELLOW.apply("Committed; branch behind upstream.\n");
    } else {
        YELLOW.apply("Committed; branch diverged from upstream.\n");
    }
}
