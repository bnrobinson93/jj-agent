# jj-agent

Shell tool for spawning and managing AI agent workspaces against JJ repos. Wraps `_jj_workspace_jump` into a first-class interface with task injection, state visibility, and cleanup.

## The Problem

Current `ai1`/`ai2` functions: create workspace, open tmux window. That's it. No task context written to the workspace, no way to see what agents are doing at a glance, no cleanup path, hardcoded to 2 slots.

`jj-agent` fills those gaps without changing the underlying model (JJ workspaces + tmux windows).

---

## Interface

```fish
jj-agent spawn <slot> "<task>"          # create workspace, inject task, launch agent
jj-agent done <slot>                    # cleanup: forget workspace, rm dir, kill window
jj-agent list                           # show all active agent slots for this repo
jj-agent status                         # show all slots across all sessions (multi-repo)
```

Slot is a number or short name: `1`, `2`, `rbac`, `auth`. Becomes the workspace suffix and tmux window name.

```fish
# examples
jj-agent spawn 1 "implement RBAC types in src/types/rbac.ts and src/api/rbac.ts"
jj-agent spawn auth "add JWT refresh token endpoint — see types in @abc123"
jj-agent done 1
jj-agent list
```

---

## Spawn Flow

```
jj-agent spawn 1 "implement RBAC types"
```

1. Capture current `@` change_id from main workspace
2. `jj workspace add <repo>-1` (create workspace dir)
3. `cd <repo>-1 && jj new <change_id>` (fork from current change)
4. `jj describe -m "implement RBAC types"` (name the change)
5. Write `CLAUDE.md` to workspace root (see template below)
6. Write slot entry to `.jj/agent-state.toml` (see state model)
7. Open tmux window `1` in `<repo>-1/` with `GIT_DIR` set
8. Run agent command in that window (default: `claude`)

Return to original window immediately after step 7. Agent runs in parallel.

---

## CLAUDE.md Template

Written to `<workspace>/CLAUDE.md` at spawn time. Parameterized from the task description and repo context.

```markdown
# Task: {task_description}

## Context
- Repo: {repo_name}
- Forked from change: {parent_change_id} ({parent_description})
- Spawned: {timestamp}

## Scope
Work in this directory only (`{workspace_path}`).

## Files You Own
{file_patterns — derived from task description if detectable, else left blank for agent to fill}

## Do Not Touch
- Files not mentioned above
- `CLAUDE.md` (this file)

## Definition of Done
{blank — agent should not guess; either filled by user before spawn or left for agent to clarify}

## Related Changes
{populated if jj log shows sibling agent changes — e.g., "ai2 is implementing the UI component for these types"}
```

Template location (override order):
1. `<repo>/.jj/agent-template.md` — per-repo custom template
2. `~/.config/jj-agent/template.md` — user global template
3. Built-in default (above)

---

## State Model

`.jj/agent-state.toml` in the main repo root (not in the workspace):

```toml
[slots.1]
task        = "implement RBAC types in src/types/rbac.ts"
change_id   = "abc123def456"   # the change jj new created
workspace   = "/home/brad/Documents/code/myrepo-1"
spawned_at  = "2026-06-16T14:32:00Z"
agent       = "claude"

[slots.auth]
task        = "add JWT refresh token endpoint"
change_id   = "xyz789ghi012"
workspace   = "/home/brad/Documents/code/myrepo-auth"
spawned_at  = "2026-06-16T14:45:00Z"
agent       = "claude"
```

State is updated on spawn and cleared on `done`. Source of truth for `list` and `status` commands.

**Why TOML not JSON:** Human-readable in `jj diff`. If you run `jj describe` after spawning, the state file shows up as a modified file and you can see what changed.

**Why `.jj/`:** Stays out of the working copy diff (JJ ignores `.jj/` directory). Doesn't appear in `jj status` or `jj diff`.

---

## Done Flow

```
jj-agent done 1
```

1. Read slot entry from `.jj/agent-state.toml`
2. Confirm: `"Abandon change abc123def456 (implement RBAC types)? [y/N]"`
3. `jj workspace forget <workspace_path>`
4. `rm -rf <workspace_dir>`
5. `tmux kill-window -t 1` (if window exists in current session)
6. Remove slot from `.jj/agent-state.toml`

Does NOT automatically `jj abandon` the change — the change stays in the graph after the workspace is cleaned up. You've already reviewed and composed it by the time you call `done`. If you want to discard: `jj abandon <change_id>` separately.

---

## List / Status

```
$ jj-agent list

SLOT   CHANGE    TASK
1      abc123d   implement RBAC types in src/types/rbac.ts
auth   xyz789g   add JWT refresh token endpoint

2 active agents in myrepo
```

```
$ jj-agent status   # cross-repo, reads all agent-state.toml files found in ~/Documents/code/**/.jj/

REPO            SLOT   CHANGE    TASK
myrepo          1      abc123d   implement RBAC types
myrepo          auth   xyz789g   add JWT refresh token endpoint
control-center  1      mno345p   integrate admin RBAC panel
```

`status` is the shell equivalent of the Obsidian feature note's change graph section.

---

## Agent Configuration

Default agent: `claude` (Claude Code CLI).

Override per-spawn:
```fish
jj-agent spawn 1 "implement types" --agent aider
jj-agent spawn 2 "write tests" --agent "goose session start"
```

Override globally in `~/.config/jj-agent/config.toml`:
```toml
default_agent = "claude"
```

The agent command runs in the tmux window after workspace setup. Any CLI that reads `CLAUDE.md` or equivalent context works.

---

## Completion Signal

No automatic detection yet. The workspace CLAUDE.md tells the agent to signal completion by writing a `.done` marker:

```markdown
## When Finished
Write an empty file `.agent-done` to the workspace root. This signals the spawner.
```

Future: a tmux bell hook watching for `.agent-done` creation. Until then: watch `jj-agent list` — when an agent is done it tends to stop changing the graph.

---

## Relationship to Existing Functions

`ai1.fish` and `ai2.fish` stay as thin wrappers:

```fish
function ai1 --argument-names task
    jj-agent spawn 1 $task
end

function ai2 --argument-names task
    jj-agent spawn 2 $task
end
```

Existing behavior preserved. New capability: pass a task description. `ai1` with no args → old behavior (workspace jump, no CLAUDE.md injection). `ai1 "do X"` → full spawn with injection.

---

## What This Is Not

- Not a process supervisor (tmux handles that)
- Not an agent itself (it spawns and manages workspaces; the agent is a separate tool)
- Not a replacement for Obsidian feature notes (those hold the design intent; this holds operational state)
- Not multi-machine (state is local to the machine)

---

## Size Estimate

| Component | ~Lines |
|-----------|--------|
| `jj-agent` main dispatch | 30 |
| `spawn` subcommand | 80 |
| `done` subcommand | 40 |
| `list` / `status` | 50 |
| CLAUDE.md template rendering | 40 |
| State file read/write (TOML via fish) | 50 |
| `ai1`/`ai2` shim update | 10 |
| **Total** | **~300** |

Fish doesn't have a native TOML parser — either use `python3 -c "import tomllib..."` (stdlib in Python 3.11+) for reads or treat the file as append-only and use `grep`/`sed` for simple key lookups. Alternative: use a plain key=value format instead of TOML.

---

## Publish Consideration

The core pattern (workspace + tmux window + scoped context file) is agent-agnostic and shell-agnostic. After working in fish, consider a POSIX sh port for broader reach. The only hard dependencies are: `jj`, `tmux`, and whatever agent CLI is configured.
