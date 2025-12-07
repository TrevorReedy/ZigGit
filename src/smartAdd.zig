const std = @import("std");
const COLOR = @import("./COLOR.zig");
const git = @import("./git.zig");

const Allocator = std.mem.Allocator;
pub const AddErr = git.GitErr;

fn hasAnyChanges(alloc: Allocator, repo_path: []const u8) AddErr!bool {
    const raw = try git.statusPorcelainZ(alloc, repo_path);
    defer alloc.free(raw);
    return raw.len != 0;
}

fn askYesNoDefaultNo(prompt: []const u8) bool {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    stdout.print("{s} [y/N]: ", .{prompt}) catch {};

    var buf: [64]u8 = undefined;
    const maybe_line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return false;
    const line = maybe_line orelse return false;
    if (line.len == 0) return false;

    const first = std.ascii.toLower(line[0]);
    return first == 'y';
}

fn printStatusPorcelain(raw: []const u8) void {
    const stdout = std.io.getStdOut().writer();

    // porcelain -z: entries separated by NUL, path(s) follow status
    var i: usize = 0;
    while (i < raw.len) {
        // read until NUL
        var j = i;
        while (j < raw.len and raw[j] != 0) : (j += 1) {}
        if (j == i) {
            i += 1;
            continue;
        }
        const entry = raw[i..j];
        _ = stdout.print("{s}\n", .{entry}) catch {};
        i = j + 1;
    }
}

/// Smart-ish add: preview + confirm, then `git add -A`.
pub fn add(
    alloc: Allocator,
    repo_path: []const u8,
) AddErr!void {
    // 0) Prove this is a repo
    try git.ensureRepo(alloc, repo_path);

    // 1) Refresh index
    try git.updateIndex(alloc, repo_path);

    // 2) Check if anything to add
    if (!try hasAnyChanges(alloc, repo_path)) {
        COLOR.YELLOW.apply("No changes to add.\n");
        return;
    }

    const stdout = std.io.getStdOut().writer();

    // 3) Show diff and status
    COLOR.YELLOW.apply("Git Diff\n");
    const diff = try git.diffUnstaged(alloc, repo_path);
    defer alloc.free(diff);

    const diff_trimmed = std.mem.trimRight(u8, diff, "\r\n");
    if (diff_trimmed.len == 0) {
        COLOR.YELLOW.apply("(No unstaged diff output; changes may be untracked files only.)\n");
    } else {
        _ = stdout.print("{s}\n", .{diff_trimmed}) catch {};
    }

    const status_raw = try git.statusPorcelainZ(alloc, repo_path);
    defer alloc.free(status_raw);

    if (status_raw.len != 0) {
        COLOR.YELLOW.apply("\nStatus (including untracked):\n");
        printStatusPorcelain(status_raw);
    }

    // 4) Ask user
    const yes = askYesNoDefaultNo("Stage ALL these changes with `git add -A`?");
    if (!yes) {
        COLOR.RED.apply("✗ Not staging changes.\n");
        return;
    }

    // 5) Actually stage
    try git.addAll(alloc, repo_path);
    COLOR.GREEN.apply("✓ Changes staged with git add -A.\n");
}
