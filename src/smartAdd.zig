pub const Color = struct {
    code: []const u8,

    pub fn apply(self: Color, text: []const u8) void {
        std.debug.print("{s}{s}\x1b[0m", .{ self.code, text });
    }
};

pub const RED = Color{ .code = "\x1b[31m" };
pub const GREEN = Color{ .code = "\x1b[32m" };
pub const YELLOW = Color{ .code = "\x1b[33m" };

const std = @import("std");

const GitErr = error{ NoGit, BadStatus, GitFailed };

pub fn add(
    alloc: std.mem.Allocator,
    repo_path: []const u8,
) !void {
    const VERBOSE = false;

    try ensureGitRepo(alloc, repo_path);
    try runGit(false, alloc, repo_path, &[_][]const u8{
        "update-index", "-q", "--refresh",
    }, .{});

    const raw = try runGit(true, alloc, repo_path, &[_][]const u8{
        "status", "--porcelain", "-z",
    }, .{});
    defer alloc.free(raw);

    var list = try parsePorcelainZ(alloc, raw);
    defer list.deinit();

    // 1) Preview what would be staged (working tree vs index)
    const diff = try runGit(
        true,
        alloc,
        repo_path,
        &[_][]const u8{ "diff", "--minimal", "--color=always" },
        .{},
    );
    defer alloc.free(diff);

    std.debug.print("Git Diff\n{s}\n", .{diff});

    // 2) Ask user
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    _ = stdout;

    YELLOW.apply("\nStage these changes? (y/N): ");

    var buf: [8]u8 = undefined;
    const line = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse "";
    const answer = if (line.len > 0) line[0] else 'n';

    if (answer == 'y' or answer == 'Y') {

        // 3) Actually stage on YES
        const counts = try stageChanges(alloc, repo_path, list.items);
        _ = counts;
        if (VERBOSE) {
            YELLOW.apply("[add] staged: add={d}, rm={d}\n");
        }
        GREEN.apply("✓ Changes staged.\n");
        return;
    } else {
        // Do nothing, no reset needed
        RED.apply("✗ Not staging changes.\n");
        return;
    }
}

// ----- helpers -----

fn isDotEntry(path: []const u8) bool {
    // never treat .git as a candidate
    if (std.mem.startsWith(u8, path, ".git/") or std.mem.eql(u8, path, ".git"))
        return false;

    const base = std.fs.path.basename(path);
    return base.len > 0 and base[0] == '.';
}

fn askYesNoDefaultNo(prompt: []const u8) !bool {
    const out = std.io.getStdOut().writer();
    const inp = std.io.getStdIn().reader();

    try out.print("{s} [y/N]: ", .{prompt});

    var buf: [64]u8 = undefined;
    const n = try inp.readUntilDelimiterOrEof(&buf, '\n');
    if (n == null or n.?.len == 0) return false;

    const first = std.ascii.toLower(n.?[0]);
    return first == 'y';
}
fn filterDotfilesSimple(
    alloc: std.mem.Allocator,
    to_add: *std.ArrayList([]const u8),
    to_rm: *std.ArrayList([]const u8),
) !void {
    // quick scan: any dotfiles at all?
    var found_dot = false;
    for (to_add.items) |p| if (isDotEntry(p)) {
        found_dot = true;
        break;
    };
    if (!found_dot) for (to_rm.items) |p| if (isDotEntry(p)) {
        found_dot = true;
        break;
    };
    if (!found_dot) return;

    const include = try askYesNoDefaultNo("Dotfiles detected (e.g. .env, .vscode). Include them?");
    if (include) return;

    // user said NO → drop them from both lists
    var keep_add = std.ArrayList([]const u8).init(alloc);
    defer keep_add.deinit();
    try keep_add.ensureTotalCapacity(to_add.items.len);
    for (to_add.items) |p| if (!isDotEntry(p)) try keep_add.append(p);
    to_add.clearRetainingCapacity();
    try to_add.appendSlice(keep_add.items);

    var keep_rm = std.ArrayList([]const u8).init(alloc);
    defer keep_rm.deinit();
    try keep_rm.ensureTotalCapacity(to_rm.items.len);
    for (to_rm.items) |p| if (!isDotEntry(p)) try keep_rm.append(p);
    to_rm.clearRetainingCapacity();
    try to_rm.appendSlice(keep_rm.items);
}

const GitOptions = struct {
    /// If true, print the underlying `git -C ...` command before running.
    show_calls: bool = false,
};

fn runGit(
    comptime WantOut: bool,
    alloc: std.mem.Allocator,
    repo_path: []const u8,
    tail_argv: []const []const u8,
    opts: GitOptions,
) !if (WantOut) []u8 else void {
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

fn ensureGitRepo(alloc: std.mem.Allocator, path: []const u8) !void {
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

const Change = struct { x: u8, y: u8, path_old: []const u8, path: []const u8 };

fn parsePorcelainZ(alloc: std.mem.Allocator, buf: []const u8) !std.ArrayList(Change) {
    var out = std.ArrayList(Change).init(alloc);
    var i: usize = 0;
    while (i < buf.len) {
        if (i + 2 > buf.len) break;
        const a = buf[i];
        const b = buf[i + 1];
        var j = i + 2;
        while (j < buf.len and buf[j] != ' ') : (j += 1) {}
        if (j >= buf.len) return GitErr.BadStatus;
        i = j + 1;

        const start = i;
        while (i < buf.len and buf[i] != 0) : (i += 1) {}
        if (i >= buf.len) return GitErr.BadStatus;
        const first = buf[start..i];
        i += 1;

        var ch: Change = .{ .x = a, .y = b, .path_old = &[_]u8{}, .path = first };
        if (a == 'R' or a == 'C') {
            const start2 = i;
            while (i < buf.len and buf[i] != 0) : (i += 1) {}
            if (i >= buf.len) return GitErr.BadStatus;
            ch.path_old = first;
            ch.path = buf[start2..i];
            i += 1;
        }
        try out.append(ch);
    }
    return out;
}

const StageCounts = struct { added: usize = 0, removed: usize = 0 };

fn stageChanges(alloc: std.mem.Allocator, repo_path: []const u8, changes: []const Change) !StageCounts {
    var to_add = std.ArrayList([]const u8).init(alloc);
    defer to_add.deinit();
    var to_rm = std.ArrayList([]const u8).init(alloc);
    defer to_rm.deinit();

    for (changes) |c| {
        if (c.x == '?' and c.y == '?') {
            try to_add.append(c.path);
            continue;
        } // untracked
        if (c.y == 'M' or c.x == 'A') {
            try to_add.append(c.path);
            continue;
        } // modified/add
        if (c.y == 'D') {
            try to_rm.append(c.path);
            continue;
        } // deleted in WD
        if (c.x == 'R' or c.x == 'C') {
            try to_add.append(c.path);
            continue;
        } // rename/copy
    }

    try filterDotfilesSimple(alloc, &to_add, &to_rm);

    var counts: StageCounts = .{};

    if (to_add.items.len > 0) {
        var argv = std.ArrayList([]const u8).init(alloc);
        defer argv.deinit();
        try argv.appendSlice(&[_][]const u8{ "add", "--" });
        try argv.appendSlice(to_add.items);
        // try runGitNoOut(alloc, repo_path, argv.items);
        try runGit(false, alloc, repo_path, argv.items, .{});
        counts.added = to_add.items.len;
    }

    if (to_rm.items.len > 0) {
        var argv2 = std.ArrayList([]const u8).init(alloc);
        defer argv2.deinit();
        try argv2.appendSlice(&[_][]const u8{ "rm", "--cached", "--" });
        try argv2.appendSlice(to_rm.items);
        // try runGitNoOut(alloc, repo_path, argv2.items);
        try runGit(false, alloc, repo_path, argv2.items, .{});
        counts.removed = to_rm.items.len;
    }

    return counts;
}
