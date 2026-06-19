# jj-agent

Fish shell plugin for spawning and managing AI agent workspaces in [Jujutsu](https://github.com/martinvonz/jj) repositories. Install with [Fisher](https://github.com/jorgebucaran/fisher).

```fish
fisher install bnrobinson93/jj-agent
```

---

## How it works

Each agent gets its own JJ workspace — a sibling directory that shares the change graph with your main repo. The agent works in isolation, commits to its own change, then signals done. You compose the result.

Context is piped to the agent as an opening prompt. Your repo's `CLAUDE.md` stays untouched.

### Two entry points

**`jj-orch`** — for features that need an orchestrator. Creates a `.jj/feature-{slug}.md` scaffold, spawns an orchestrator agent that reads the task list and manages workers on your behalf.

**`jj-agent`** — the primitive. Spawn, poll, and clean up individual agent workspaces directly. The orchestrator uses this internally; you can too.

---

## Orchestrated workflow

```
jj-orch "add user roles"
```

1. Creates `.jj/feature-{slug}.md` (if absent) and opens an orchestrator workspace in tmux
2. The orchestrator asks you to define `## Changes` and `## Subtasks`, explaining the distinction, and writes your answers into the feature file
3. Once confirmed, it spawns workers for each task, polls for completion, composes results, and keeps it current
4. When all tasks are checked off, it stops and asks you to review

The orchestrator asks before making architectural decisions. Final diff review is yours.

### Feature file (.jj/feature-{slug}.md)

The coordination document. You write the goal and task list; the orchestrator tracks progress.

```markdown
# Feature: add user roles

## Goal
Users can be assigned roles that gate access to specific resources.

## Changes
<!-- filled in by orchestrator after asking you -->
- [ ] define Role type and database schema
- [ ] add role check middleware
- [ ] role assignment endpoint

## Subtasks
<!-- filled in by orchestrator after asking you -->
- [ ] unit tests for role check  [squash-into: add role check middleware]

## Agents
| slot | task | change_id | bookmark | status |

## Decisions

## PRs
- [ ] feat/user-roles → main
```

`## Changes` = separate JJ changes, each becomes a PR.
`## Subtasks` = squashed into a parent change, no separate PR.
`## Decisions` = answers the orchestrator records after asking you in conversation.

---

## Manual workflow

```fish
# Spawn a worker
jj-agent spawn auth "add JWT refresh token endpoint"

# Check what's running
jj-agent list

# Wait for completion
jj-agent poll auth

# Review and clean up
jj diff -r (jj-agent list | awk '/auth/ {print $2}')
jj-agent done auth
```

---

## Commands

```
jj-agent spawn <slot> "<task>" [--agent <cmd>] [--prompt-file <path>]
jj-agent done <slot> [--keep-change]
jj-agent list
jj-agent status
jj-agent poll [<slot>] [--timeout <secs>]

jj-orch [feature_name] [--agent <cmd>]
```

`--agent`: `claude` (default), `codex`, `opencode`, `none` (workspace only, no agent).

Run any command with `--help` for details.

---

## Completion signal

Workers signal completion by writing `.agent-done` to their workspace root. The orchestrator (or `jj-agent poll`) watches for this file. Workers should not exit until `jj-agent done <slot>` is called — that forgets the workspace and cleans up.

---

## Customizing the opening prompt

The built-in task prompt template can be overridden at two levels:

- **Repo-level**: `.jj/agent-template.md`
- **User-level**: `~/.config/jj-agent/template.md`

Template variables: `{task}`, `{repo_name}`, `{parent_change_id}`, `{workspace_path}`, `{timestamp}`, `{slot}`, `{related_changes}`.

Pass `--prompt-file <path>` to `jj-agent spawn` to supply a one-off prompt directly.

---

## State

`.jj/agent-state.toml` — machine-readable record of active slots. Written by `spawn`, cleaned by `done`. The orchestrator reads it to build sibling context into worker prompts.
