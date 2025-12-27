# ZigGit — A Zig-Powered Git Wrapper That Makes Git Safer
**By Trevor Reedy**

---

## Why ZigGit Exists

Git is essential to modern software development, but it is also one of the most error-prone tools for newer developers. Many common workflows assume a deep understanding of staging, upstream tracking, rebasing, and branch state—knowledge that is often learned through mistakes rather than documentation.

ZigGit is a **small, opinionated Git wrapper written in Zig** designed to reduce accidental misuse while preserving transparency. It does not replace Git. Instead, it runs real Git commands while adding **guardrails, clearer output, and guided workflows** around common operations.

The goal is simple: make it harder to do the wrong thing, without hiding what Git is actually doing.

---

## Architecture Overview

ZigGit is structured around a few core principles:

- Explicit command routing instead of reflection or magic
- Centralized Git execution logic
- Conservative defaults over clever automation
- Treating many Git “errors” as valid states
- Platform-aware terminal output

The codebase is intentionally small and readable, with each command implemented as a focused module.

---

## Command Routing and CLI Structure

ZigGit exposes a single CLI entry point with subcommands such as:

- `zigit add`
- `zigit commit`
- `zigit preview` **in devlopment**
- `zigit push`

Rather than relying on a generic argument parser, the CLI routes commands through an explicit dispatcher in `main.zig`. This keeps control flow predictable and makes debugging straightforward.

Each command receives a resolved repository path and executes within a shared execution model, avoiding duplicated setup logic or inconsistent behavior between commands.

---

## Centralized Git Execution

All Git commands are executed through a single abstraction layer (`git.zig`). This module is responsible for:

- Spawning Git processes
- Capturing stdout and stderr
- Normalizing exit codes
- Returning structured results instead of ad-hoc strings

Centralizing Git execution prevents a common CLI anti-pattern: duplicating process spawning logic across multiple commands with slightly different error handling. This design choice significantly improves maintainability and consistency.

---

## SmartAdd: Safer Staging by Default

Blindly running `git add .` is one of the fastest ways for new developers to commit unintended changes. ZigGit’s SmartAdd command takes a more cautious approach.

SmartAdd:
- Inspects repository state before staging
- Avoids staging when there is nothing to add
- Provides clear feedback instead of silent success
- Uses predictable defaults rather than partial or interactive staging

SmartAdd is intentionally conservative. It does not attempt to be clever with hunk selection or interactive diffs. The goal is safety and clarity, not power-user optimization.

---

## SmartCommit: Guided Commit Creation

Committing is another common friction point. New users often struggle with empty commits, forgotten staging, or unexpected editor prompts.

SmartCommit focuses on:
- Prompting for commit messages when required
- Preventing empty or invalid commits
- Providing clear feedback on failure states

It does not enforce commit linting or complex message schemas. Instead, it ensures that commits happen deliberately and predictably, without surprising the user.

---

## SmartPreview: Understanding Repository State

Before committing or pushing, developers often want a concise snapshot of repository state:

- What has changed?
- What is staged vs unstaged?
- Is an upstream configured?
- Is the branch ahead or behind?

SmartPreview is designed as a **human-readable pre-flight check**. One of its most important design decisions is treating missing upstreams as **informational warnings**, not fatal errors.

Many Git tools crash or exit early when no upstream is configured. ZigGit treats this as a valid state and reports it clearly instead of breaking the workflow.

---

## SmartPush: Push Without Footguns

Pushing introduces another set of assumptions: upstream configuration, authentication, and branch tracking.

SmartPush:
- Detects whether an upstream exists
- Avoids crashing on missing configuration
- Reports next steps clearly instead of failing noisily

The emphasis is on clarity over enforcement. ZigGit avoids forcing configuration changes and instead surfaces the current state so the user can decide how to proceed.

---

## Platform Abstraction and Terminal Safety

ZigGit includes a dedicated platform layer (`platform.zig`) to isolate operating-system-specific behavior. This prevents OS checks and terminal quirks from leaking into command logic.

Terminal output and color formatting are handled through a centralized module (`COLOR.zig`). This allows:

- Consistent color usage across commands
- Easy disabling or adjustment of formatting
- Safer output on terminals with limited capabilities

CLI polish matters, but only if it does not break across environments. ZigGit’s output layer is designed to degrade gracefully.

---

## Zig as an Enforcing Constraint

Zig’s design heavily influences ZigGit’s implementation:

- Errors must be handled explicitly
- Allocation lifetimes are deliberate
- Failure modes are modeled, not ignored

Rather than fighting these constraints, ZigGit embraces them. Many parts of the codebase are shaped by the requirement to acknowledge what can go wrong, resulting in a tool that is more predictable and resilient than a loosely typed script.

---

## What I Would Improve Next

If ZigGit were expanded further, the most valuable next steps would be:

- A clearer installation story (prebuilt binaries per platform)
- Optional configuration files for toggling prompts and verbosity
- An “explain mode” that shows the exact Git commands being executed
- A small test harness for validating Git output parsing

These are intentionally framed as future improvements rather than existing features.

---

## Conclusion

ZigGit is not a replacement for Git. It is a layer of safety and clarity on top of it.

This project required solving real engineering problems:
- Designing a maintainable CLI architecture
- Centralizing process execution
- Parsing Git output deterministically
- Handling non-fatal error states correctly
- Writing portable, terminal-safe code in Zig

More importantly, it addresses a real pain point: Git mistakes are costly, and reducing them—especially for newer developers—is worth building for.

ZigGit reflects my approach to tooling: conservative by default, explicit in behavior, and honest about tradeoffs.
