function jj-orch
    if contains -- --help $argv; or contains -- -h $argv
        echo "usage: jj-orch [feature_name] [--agent <cmd>]"
        echo ""
        echo "  feature_name  name of feature to orchestrate; slugified to orch-<name>"
        echo "                omit to spawn a blank orch workspace with no task context"
        echo "  --agent       claude (default), codex, opencode, none"
        echo ""
        echo "  creates FEATURE.md scaffold if absent, then spawns orchestrator"
        echo "  with task context piped as opening prompt"
        return 0
    end

    set -l agent claude
    set -l feature_name

    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case --agent
                set i (math $i + 1)
                set agent $argv[$i]
            case '*'
                if test -z "$feature_name"
                    set feature_name $argv[$i]
                end
        end
        set i (math $i + 1)
    end

    set -l root (jj workspace root 2>/dev/null)
    or begin
        echo "not in a jj repository" >&2
        return 1
    end

    # No feature name: spawn blank orch workspace (no context injected), like ai1 with no args
    if test -z "$feature_name"
        jj-agent spawn orch --agent "$agent"
        return $status
    end

    set -l slug (string lower "$feature_name" | string replace -ra '[^a-z0-9]+' '-' | string trim -c -)
    set -l slot "orch"
    set -l feature_md "$root/.jj/feature-$slug.md"
    set -l timestamp (date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create feature file scaffold if absent
    if not test -f "$feature_md"
        printf '# Feature: %s\nstarted: %s\n\n## Goal\n\n\n## Changes\n\n## Subtasks\n\n## Agents\n| slot | task | change_id | bookmark | status |\n|------|------|-----------|----------|--------|\n\n## Decisions\n\n## PRs\n- [ ] \n' \
            "$feature_name" "$timestamp" > "$feature_md"
        echo "created $feature_md"
    else
        echo "using existing $feature_md"
    end

    # Build orchestrator opening prompt in a temp file; piped to agent on launch
    set -l tmpfile (mktemp /tmp/jj-orch-XXXXXX.md)
    printf '# Orchestrator: %s\n\nFeature file: `%s`\nAll reads/writes below refer to this file.\n\n## First: Define the Task List\n\nBefore doing anything else, read the feature file and ask the human to fill in ## Changes and ## Subtasks.\n\nExplain the distinction:\n- **## Changes** — each item becomes its own JJ change and pull request\n- **## Subtasks** — each item gets squashed into a named parent change (no separate PR); use for tests, docs, or small follow-ups\n\nWait for the human to confirm the task list before proceeding. Write their answers directly into the feature file.\n\n## Loop (after task list confirmed)\n0. Start background watcher once: `jj-agent watch &` — auto-closes tmux windows when workers finish\n1. Read ## Changes and ## Subtasks — find unblocked, unassigned items\n2. `jj-agent spawn <slot> "<task>"` — spawn worker\n3. `jj-agent poll` — wait for .agent-done (watcher already closed the window; workspace still exists)\n4. `jj diff -r <change_id>` — review worker output\n5a. ## Changes entry:\n    - `jj restore --changes-in <worker_change> -- .claude/` — strip agent settings from worker change\n    - `jj rebase -r <worker_change> -d <stack_tip>` — slot into stack\n    - `jj rebase -r @ -d <worker_change>` — keep your @ at tip so your working tree sees the result\n    - Assign bookmark: `jj bookmark set feat/name -r <worker_change>`\n    - Run tests (your @ is now at tip; file tree reflects composed state)\n    - Mark [x] in ## Changes, update ## PRs\n5b. ## Subtasks entry:\n    - `jj restore --changes-in <worker_change> -- .claude/` — strip agent settings first\n    - `jj squash --from <worker_change> --into <parent_change>` — fold into parent\n    - `jj rebase -r @ -d <parent_change>` — keep your @ at tip\n    - Run tests\n    - Mark [x] in ## Subtasks\n6. Update ## Agents; call `jj-agent done <slot> --keep-change` — skips confirmation prompt\n7. If needs iteration: open worker window with `tmux new-window -c <workspace_path>`, give feedback, re-poll\n8. If blocked on decision: ask human in this conversation, wait for answer, record in ## Decisions, continue\n9. Repeat until ## Changes and ## Subtasks have no unchecked items\n\n## Scope\n- **Files**: read anywhere in the repo; write only inside your own workspace\n- **Network**: read-only calls (GET, curl fetches, API reads) are fine; stop before any call that pushes, posts, or mutates external state — ask human first\n\n## You Do Not Own\n- Architecture decisions → ask human\n- Final review before PR creation → human does this\n- Cross-repo dependency order changes → ask human\n\n## When a Decision Reveals a Codebase Pattern\nWrite the pattern to memory.md (if present). Write the feature choice to the feature file ## Decisions.\n\n## When Done\n1. Call `jj-agent done --all --keep-change` — closes all worker workspaces (skips orch)\n2. Tell human: "All tasks complete. Ready for final review. Run `jj-agent done orch` to close this session."\n3. Stop.\n' \
        "$feature_name" "$feature_md" > "$tmpfile"

    jj-agent spawn "$slot" "$feature_name" --agent "$agent" --prompt-file "$tmpfile"
    set -l spawn_status $status

    rm -f "$tmpfile"
    tmux select-window -t orch
    return $spawn_status
end
