---
name: git-commit-style-per-feature
description: Create readable Git history by grouping changes into feature-based commits instead of broad file-based commits. Use when the user asks to create commits, add commits, split changes into commits, tidy a worktree into logical history, or organize a branch before pushing. When the user says "commit the changes", review the full worktree, list the proposed feature commits, and get approval before committing. When the user says "commit and push the changes", go ahead with the full commit-and-push flow without waiting for a separate approval step.
---

# Git Commit Style Per Feature

## Default Rule

- Treat requests like "create commits", "add commits", or "commit these changes" as requests for feature-based commits unless the user explicitly asks for a single commit or another grouping strategy.
- Prefer the smallest meaningful commit that represents one feature, fix, refactor, or coherent behavior change.
- Split commits by logical change, not by file boundaries.
- Use partial staging when one file contains changes for multiple features.
- Review the full worktree before deciding what is in or out, including hidden paths, agent-loadable directories, generated metadata, and any remaining untracked files.
- Do not silently leave files behind. If anything will remain uncommitted, call it out explicitly before committing and explain why.
- If the user says `commit the changes`, list the proposed feature commits and the files each one will include, then wait for user approval before committing.
- If the user says `commit and push the changes`, inspect the full worktree, make the feature-based commits, and push them without stopping for a separate approval round.
- Ensure `.gitignore` exists. If it is missing:
  - In commit-only mode, create an empty `.gitignore` and include a suggestion bundle before proposing commits (for example, what to ignore next).
  - In commit-and-push mode, create the empty `.gitignore`, include it in the commit/push flow, and then provide suggestions after completing the push.
- Treat `.agent/` as includable work by default (do not auto-exclude it) unless:
  - `.agent/` is already covered by `.gitignore`, or
  - the user explicitly asks not to add `.agent/`.
- If the user explicitly asks not to add `.agent/`:
  - In non-commit flows, suggest adding `.agent/` to `.gitignore`.
  - In commit or commit-and-push flows, add `.agent/` to `.gitignore` directly as part of the requested work.

## Modes

### Commit Only

1. Inspect the full worktree before staging anything.
2. Identify every tracked, modified, deleted, renamed, and untracked file that may be part of the requested work.
3. If `.gitignore` is missing, create an empty `.gitignore` and prepare a suggestion bundle for likely ignore entries.
4. Propose the logical feature or change boundaries.
5. Present the full commit plan to the user, including anything that would be left uncommitted, and get approval.
6. Stage one feature at a time, including partial hunks when needed.
7. Write a concise imperative commit message that describes the outcome of that feature.
8. Repeat until the approved work is committed.

### Commit And Push

1. Inspect the full worktree before staging anything.
2. Identify every tracked, modified, deleted, renamed, and untracked file that may be part of the requested work.
3. If `.gitignore` is missing, create an empty `.gitignore` and include it in the commit set.
4. Determine the logical feature or change boundaries yourself.
5. Stage one feature at a time, including partial hunks when needed.
6. Write a concise imperative commit message that describes the outcome of that feature.
7. Repeat until the requested work is committed.
8. Push the resulting commits.
9. After pushing, provide suggestions for future `.gitignore` entries if relevant.

## Grouping Heuristics

- Prefer user-visible behavior or feature slices over file-by-file grouping.
- Treat test coverage for a feature as part of that same feature commit when the tests directly support it.
- Separate opportunistic cleanup, formatting, or renames from functional changes unless they are inseparable.
- If a single file contains two unrelated features, split the hunks and commit them separately.
- If the change boundaries are unclear or risky, explain the proposed grouping before committing.
- Treat repository-specific support files as first-class changes when they are part of how the project is loaded or consumed. Do not dismiss them as incidental without checking.
- When a user asks to commit the rest of the changes, interpret that as the full remaining worktree unless they scope it more narrowly.

## Commit Message Guidance

- Use short imperative summaries.
- Describe the change in terms of the feature or outcome.
- Avoid vague messages like `updates`, `misc fixes`, or `cleanup`.

Examples:

- `Add lean skill metadata validation`
- `Archive inactive skills under archive/`
- `Rename vibe guide skill to vibe style lean`

## Overrides

- Follow the user's explicit instruction when they ask for a different strategy such as a single commit, WIP commit, squash commit, or file-based grouping.
- When the user asks for commits but some changes appear unrelated to the request, pause and surface that mismatch before committing them together.
- If the user approves a subset of the proposed commits, commit only that approved subset and restate what is still left in the worktree afterward.
- If the user explicitly asks to push, include the push in the same flow. If the user does not ask to push, do not push.
