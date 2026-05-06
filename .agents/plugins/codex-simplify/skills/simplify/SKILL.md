---
name: simplify
description: Review changed code in the current workspace for reuse, quality, and efficiency, then directly fix cleanup issues found. Use when the user asks to simplify, clean up, or review changed files before finalizing work.
---

# Simplify: Code Review and Cleanup

Review all changed files for reuse, quality, and efficiency. Fix any issues found.

## Phase 1: Identify Changes

Run `git status --short` to understand the change set.

Run `git diff` to review unstaged tracked changes. If there are staged changes, run `git diff HEAD` so the review includes both staged and unstaged tracked changes. If there are relevant untracked files, read them directly and include them in the review context.

If there are no git changes, review the most recently modified files that the user mentioned or that you edited earlier in the conversation.

Use plain diffs for agent input. When showing diffs to the user, use `git diff --color=always`.

## Phase 2: Launch Three Review Agents in Parallel

An explicit invocation of this skill requests the delegated review workflow. If the current environment exposes subagents and permits delegation, launch all three review agents concurrently in one tool batch where possible. Prefer read-only `explorer` agents when available, such as Codex `spawn_agent` calls with the `explorer` role. Pass each agent the full diff and any relevant untracked file contents so each has complete context.

If subagents are not available or delegation is not permitted, perform the same three review passes locally.

### Agent 1: Code Reuse Review

For each change:

1. Search for existing utilities and helpers that could replace newly written code. Look for similar patterns elsewhere in the codebase, especially utility directories, shared modules, and files adjacent to the changed ones.
2. Flag any new function that duplicates existing functionality. Suggest the existing function to use instead.
3. Flag any inline logic that could use an existing utility, such as hand-rolled string manipulation, manual path handling, custom environment checks, ad-hoc type guards, and similar patterns.

### Agent 2: Code Quality Review

Review the same changes for hacky patterns:

1. Redundant state: state that duplicates existing state, cached values that could be derived, observers/effects that could be direct calls.
2. Parameter sprawl: adding new parameters to a function instead of generalizing or restructuring existing ones.
3. Copy-paste with slight variation: near-duplicate code blocks that should be unified with a shared abstraction.
4. Leaky abstractions: exposing internal details that should be encapsulated, or breaking existing abstraction boundaries.
5. Stringly-typed code: using raw strings where constants, enums, string unions, or branded types already exist in the codebase.
6. Unnecessary JSX nesting: wrapper boxes/elements that add no layout value. Check whether inner component props such as `flexShrink` and `alignItems` already provide the needed behavior.
7. Unnecessary comments: comments explaining what the code does, narrating the change, or referencing the task/caller. Delete those comments; keep only non-obvious why comments for hidden constraints, subtle invariants, or workarounds.

### Agent 3: Efficiency Review

Review the same changes for efficiency:

1. Unnecessary work: redundant computations, repeated file reads, duplicate network/API calls, and N+1 patterns.
2. Missed concurrency: independent operations run sequentially when they could run in parallel.
3. Hot-path bloat: new blocking work added to startup or per-request/per-render hot paths.
4. Recurring no-op updates: state/store updates inside polling loops, intervals, or event handlers that fire unconditionally. Add a change-detection guard so downstream consumers are not notified when nothing changed. If a wrapper function takes an updater/reducer callback, verify it honors same-reference returns or the codebase's equivalent "no change" signal.
5. Unnecessary existence checks: pre-checking file/resource existence before operating. Prefer operating directly and handling the error to avoid TOCTOU issues.
6. Memory: unbounded data structures, missing cleanup, and event listener leaks.
7. Overly broad operations: reading entire files when only a portion is needed, or loading all items when filtering for one.

## Phase 3: Fix Issues

Wait for all review agents to complete when agents were launched. Aggregate their findings and fix each real issue directly.

If a finding is a false positive or not worth addressing, note it and move on. Do not argue with the finding.

When done, briefly summarize what was fixed, or confirm the code was already clean.
