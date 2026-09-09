---
description: Quick check on origin activity over the last 3 days
argument-hint: "[extra focus, optional]"
model: claude-haiku-4-5-20251001
allowed-tools: Bash(git fetch:*), Bash(git log:*), Bash(git for-each-ref:*), Bash(git rev-list:*), Bash(gh pr list:*)
---

## Pre-fetched context

Fetch: !`git fetch --all --prune 2>&1 | tail -3`

Commits on origin (last 3 days): !`git log --remotes=origin --since="3 days ago" --date=short --pretty=format:"%h %ad %an %d %s"`

Most recent origin branches: !`git for-each-ref --sort=-committerdate --format='%(refname:short) | %(committerdate:short) | %(authorname) | %(subject)' refs/remotes/origin | head -10`

Local main vs origin/main (behind/ahead): !`git rev-list --left-right --count main...origin/main 2>/dev/null || echo "n/a"`

PRs: !`gh pr list --state all --limit 20 --json number,state,updatedAt,title --jq '.[] | "\(.number) \(.state) \(.updatedAt) \(.title)"' 2>/dev/null || echo "gh CLI unavailable"`

## Task

Summarize the above in three bullets: new commits, PRs/MRs, local-vs-origin divergence.
Say "none" for empty sections. Nothing older than 3 days. No preamble, no history dump.
$ARGUMENTS
