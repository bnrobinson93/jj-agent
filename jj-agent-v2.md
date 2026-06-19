# jj-agent v2

> v1 spec: `jj-agent.md`. v1 implementation: `functions/jj-agent.fish`.  
> v2 changes: orchestrator-first framing, FEATURE.md integration, completion signal promoted to first-class.

---

## Terminology

**slot** — a named agent seat. The identifier passed to `jj-agent spawn`. Becomes the workspace directory suffix (`repo-{slot}`), the tmux window name, and the key in `agent-state.toml`. Examples: `1`, `auth`, `orch-user-roles`.

**task** — the description of work for a slot. Passed as part of the opening prompt and used as the JJ change description (`jj describe`). Free-form string.

**workspace** — a JJ workspace: a sibling directory sharing the change graph with the main repo. Each slot gets one. Isolated filesystem, shared history.

**change** — a JJ change (analogous to a commit) created inside a workspace. The worker's output lives here until composed.

**worker** — an agent spawned into a slot to execute a task. Reports done via `.agent-done`.

**orchestrator** — an agent that manages workers: reads `FEATURE.md`, spawns slots, polls, composes results, updates state. Runs in its own `orch-{feature}` slot.

Note: `## Changes` in FEATURE.md refers to the task list section — distinct from a JJ change (the VCS object).

---

## Role Shift from v1

v1 framing: human-facing tool for managing agent workspaces.  
v2 framing: primary tool used BY an orchestrator agent, also usable directly by humans.

The orchestrator agent runs in its own tmux window. It calls `jj-agent spawn/done/list` as shell commands, reads `.jj/agent-state.toml` to track what's running, and polls worker `.agent-done` files to know when work completes. Humans interact with the orchestrator via conversation — not by watching logs or running `jj-agent list` themselves.

---

## Interface (unchanged from v1)

```fish
jj-agent spawn <slot> "<task>"   [--agent <cmd>] [--prompt-file <path>]
jj-agent done <slot>
jj-agent list
jj-agent status
jj-agent poll [<slot>] [--timeout <secs>]
```

`--agent` accepts: `claude` (default), `codex`, `opencode`, `none` (workspace only, no agent launched).  
`--prompt-file` overrides the built-in template — content is piped to the agent, file is not written to the workspace.

The orchestrator uses the same commands a human would. That's the point — one tool, two callers.

---

## FEATURE.md Integration (new in v2)

If `FEATURE.md` exists in the main repo root, `jj-agent spawn` appends to its `## Agents` table and `jj-agent done` marks the slot as cleaned up.

```markdown
## Agents
| slot | task | change_id | status |
|------|------|-----------|--------|
| 1 | implement RBAC types | abc123de | in-progress |
| 2 | role list component | xyz789gh | done |
```

FEATURE.md is the human-readable record. `.jj/agent-state.toml` is the machine-readable state. Both stay in sync via `jj-agent` — neither is source of truth over the other; they serve different consumers.

If no FEATURE.md exists: `jj-agent` works exactly as v1. FEATURE.md integration is opt-in by presence.

### FEATURE.md Structure

```markdown
# Feature: {name}

## Goal
One paragraph. What changes for the user.

## Changes
<!-- filled in by orchestrator after asking human; each entry = one JJ change = one PR -->
- [ ] task description (repo/files) — unassigned
- [x] completed task — change: abc123de, bookmark: feat/name
- [ ] blocked task — unassigned  [needs: completed task]

## Subtasks
<!-- filled in by orchestrator after asking human; each entry squashed into parent change, no PR -->
- [ ] unit tests for X — unassigned  [squash-into: task description]

## Agents
| slot | task | change_id | bookmark | status |
|------|------|-----------|----------|--------|

## Decisions
<!-- orchestrator writes decisions here after human answers in conversation -->

## PRs
- [ ] feat/name → main
```

The scaffold ships with `## Changes` and `## Subtasks` empty. The orchestrator's first action is to ask the human to define both sections, explaining the distinction, then write the answers into FEATURE.md and confirm before executing anything.

After that: orchestrator reads `## Changes` and `## Subtasks` to find work, writes `## Agents` as it assigns, marks items `[x]` as they're composed. When blocked on a decision, it asks in conversation directly — no file parking. The answer gets recorded in `## Decisions`.

---

## Completion Signal (first-class in v2)

v1 treated `.agent-done` as "future work." In v2 it's the primary mechanism.

The opening prompt piped to the agent includes:

```markdown
## When Finished
Write an empty file `.agent-done` to this workspace root.
Do not exit. Wait for the orchestrator or human to review and call `jj-agent done <slot>`.
```

Orchestrator polls:

```fish
# check if slot 1 is done
test -f "$workspace/.agent-done"
```

Or watch all active slots:

```fish
jj-agent poll   # new subcommand (see below)
```

### New: `jj-agent poll`

Blocks until any active slot writes `.agent-done`, then prints which slot finished:

```fish
jj-agent poll          # wait for any slot
jj-agent poll 1        # wait for specific slot
jj-agent poll --timeout 3600   # bail after 1 hour
```

Orchestrator loop: spawn → poll → review diff → accept/iterate/escalate → done → repeat.

---

## Spawn Flow Changes (v2)

Steps 1-7 identical to v1. Additional steps:

**8.** If `FEATURE.md` exists: append slot row to `## Agents` table, mark item as assigned in `## Changes` or `## Subtasks`.

**9.** Include sibling context in the opening prompt from other active slots in `agent-state.toml`:
```markdown
## Related Changes
- slot 2 is implementing the UI component that will consume these types (change: xyz789gh)
```

This gives workers context about sibling agents without the orchestrator having to manually wire it.

---

## Re-entry Behavior (v1 bug fix)

v1 `_jj_workspace_jump` called `jj new $change_id` on BOTH new and existing workspaces — re-running `ai1` on an existing workspace created a blank change displacing the agent's `@`.

v2 `jj-agent spawn` treats existing workspace as an error:
```
slot 1 already exists at /path/to/repo-1 — use 'jj-agent done 1' first
```

If you genuinely want to re-spawn a slot (agent done, but you haven't cleaned up yet): `jj-agent done 1 --keep-change` then `jj-agent spawn 1 "new task"`.

`--keep-change` on `done`: forgets workspace + deletes dir + kills window, but does NOT abandon the JJ change. Default `done` also doesn't abandon — the change stays in the graph. `--keep-change` just skips the confirmation prompt about the change.

---

## Orchestrator's Opening Prompt

The orchestrator agent receives its context as an opening prompt piped on launch (via `jj-orch`). No file is written to the workspace — the prompt is delivered from `/tmp` and deleted after the agent reads it, leaving the repo's own `CLAUDE.md` untouched.

```markdown
# Orchestrator: {feature_name}

## Your Job
Manage this feature end to end. Your tools: jj-agent, jj, shell.
FEATURE.md is your state. Keep it current.

## First
Read FEATURE.md. If ## Changes or ## Subtasks are empty, ask the human to define them. Explain:
- **## Changes** — each item becomes its own JJ change and PR
- **## Subtasks** — each item squashes into a named parent change; no separate PR

Write answers into FEATURE.md. Confirm with human before executing anything.

## Loop
1. Read FEATURE.md — find unblocked unassigned items in ## Changes and ## Subtasks
2. Spawn workers: `jj-agent spawn <slot> "<task>"`
3. Poll for completion: `jj-agent poll`
4. Review diff: `jj diff -r <change_id>`
5a. ## Changes entry: rebase into stack, assign bookmark, run tests, mark [x]
5b. ## Subtasks entry: squash into named parent change, run tests, mark [x]
6. Update FEATURE.md: update ## Agents, fill in bookmark in ## PRs
7. If blocked on a decision: ask human in conversation, wait for answer, record in ## Decisions
8. Repeat until ## Changes and ## Subtasks have no unchecked items

## You Own
- Spawning, monitoring, composing worker output
- Keeping FEATURE.md current

## You Do Not Own
- Architectural decisions (surface to human)
- Final diff review before PR creation (human does this)
- Cross-repo dependency ordering changes (human decides)

## On Completion
When all tasks checked off: tell human "feature ready for final review" and stop.
```

Worker agents receive the same treatment: task context piped as opening prompt, repo's `CLAUDE.md` preserved unchanged.

---

## `ai1` / `ai2` Shim (unchanged)

```fish
function ai1 --argument-names task
    jj-agent spawn 1 $task
end
```

No-arg call (`ai1`) still works — spawns with empty task, no prompt injection, just workspace + window. Matches v1 behavior for quick manual use.

---

## State Model (unchanged from v1)

`.jj/agent-state.toml` — same schema as v1. Orchestrator reads it directly to build context for sibling agent cross-references.

---

## Size Delta from v1

| Addition | ~Lines |
|----------|--------|
| `jj-agent poll` subcommand | 30 |
| FEATURE.md read/write | 60 |
| Sibling context in opening prompt | 20 |
| Re-entry guard (already partially in v1) | 10 |
| `--keep-change` flag on done | 10 |
| **Total new** | **~130** |

v1 implementation (~350 lines) stays. v2 adds ~130 lines on top.
