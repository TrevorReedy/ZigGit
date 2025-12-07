const std = @import("std");
const COLOR = @import("./COLOR.zig");
const git = @import("./git.zig");

const Allocator = std.mem.Allocator;
pub const CommitErr = git.GitErr;

fn info(text: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    _ = stdout.print("{s}\n", .{text}) catch {};
}

fn promptForCommitMessage(alloc: Allocator) CommitErr![]u8 {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    stdout.print("Enter commit message: ", .{}) catch return CommitErr.InputOutput;

    var buf: [4096]u8 = undefined;
    const maybe_line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return CommitErr.InputOutput;
    const line = maybe_line orelse "";
    const trimmed = std.mem.trimRight(u8, line, "\r\n");

    return alloc.dupe(u8, trimmed) catch return CommitErr.OutOfMemory;
}

fn hasStagedChanges(alloc: Allocator, repo_path: []const u8) CommitErr!bool {
    const out = try git.diffCachedNameOnly(alloc, repo_path);
    defer alloc.free(out);

    const trimmed = std.mem.trimRight(u8, out, "\r\n");
    return trimmed.len != 0;
}

fn hasConflictsInIndex(alloc: Allocator, repo_path: []const u8) CommitErr!bool {
    const out = try git.diffCachedConflicts(alloc, repo_path);
    defer alloc.free(out);

    const trimmed = std.mem.trimRight(u8, out, "\r\n");
    return trimmed.len != 0;
}

fn ensureCommit(
    alloc: Allocator,
    repo_path: []const u8,
    msg: []const u8,
) CommitErr!void {
    try git.commitWithMessage(alloc, repo_path, msg);
}

/// Main entry: perform commit with optional message.
/// If msg is null, prompt interactively.
pub fn commit(
    alloc: Allocator,
    repo_path: []const u8,
    msg: ?[]const u8,
) CommitErr!void {
    // 0) prove repo
    try git.ensureRepo(alloc, repo_path);

    // 1) refresh index
    try git.updateIndex(alloc, repo_path);

    // 2) staged?
    if (!try hasStagedChanges(alloc, repo_path)) {
        COLOR.YELLOW.apply("Nothing staged to commit.\n");
        return;
    }

    // 3) conflicts?
    if (try hasConflictsInIndex(alloc, repo_path)) {
        COLOR.RED.apply("Resolve conflicts in index before committing.\n");
        return;
    }

    // 4) acquire commit message
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

    // 5) commit
    try ensureCommit(alloc, repo_path, final_msg.?);

    // 6) ahead/behind vs upstream
    const ab = git.aheadBehind(alloc, repo_path) catch |err| switch (err) {
        CommitErr.NoUpstream => {
            COLOR.RED.apply("WARNING: NO UPSTREAM TO GITHUB SET\n");
            COLOR.GREEN.apply("Commit created.\n");
            return;
        },
        else => {
            COLOR.GREEN.apply("Commit created.\n");
            return;
        },
    };

    if (ab.behind == 0 and ab.ahead == 0) {
        COLOR.GREEN.apply("Committed on top of up-to-date upstream.\n");
    } else if (ab.ahead > 0 and ab.behind == 0) {
        COLOR.GREEN.apply("Committed; branch ahead of upstream.\n");
    } else if (ab.behind > 0 and ab.ahead == 0) {
        COLOR.YELLOW.apply("Committed; branch behind upstream.\n");
    } else {
        COLOR.YELLOW.apply("Committed; branch diverged from upstream.\n");
    }
}
