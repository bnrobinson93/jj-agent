function jj-orch
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
    set -l slot "orch-$slug"
    set -l feature_md "$root/FEATURE.md"
    set -l timestamp (date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create FEATURE.md scaffold if absent
    if not test -f "$feature_md"
        printf '# Feature: %s\nstarted: %s\n\n## Goal\n\n\n## Tasks\n- [ ] \n\n## Agents\n| slot | task | change_id | status |\n|------|------|-----------|--------|\n\n## Decisions\n\n## Needs Human\n\n## PRs\n' \
            "$feature_name" "$timestamp" > "$feature_md"
        echo "created $feature_md — fill in ## Tasks before the orchestrator starts"
    else
        echo "using existing $feature_md"
    end

    # Build orchestrator CLAUDE.md in a temp file; spawn copies it into the workspace
    set -l tmpfile (mktemp /tmp/jj-orch-XXXXXX.md)
    printf '# Orchestrator: %s\n\nRead FEATURE.md. Execute the ## Tasks list end to end.\n\n## Loop\n1. Read ## Tasks — find unblocked, unassigned items\n2. `jj-agent spawn <slot> "<task>"` — spawn worker\n3. `jj-agent poll` — wait for .agent-done\n4. `jj diff -r <change_id>` — review worker output\n5. If good: compose (`jj squash`/`jj rebase`); mark task [x]; `jj-agent done <slot>`\n6. If needs iteration: give worker feedback in its tmux window, re-poll\n7. If blocked on decision: write to FEATURE.md ## Needs Human, ask human in this conversation, wait for answer, record in ## Decisions, continue\n8. Repeat until no unchecked tasks remain\n\n## You Do Not Own\n- Architecture decisions → ask human\n- Final review before PR creation → human does this\n- Cross-repo dependency order changes → ask human\n\n## When a Decision Reveals a Codebase Pattern\nWrite the pattern to memory.md (if present). Write the feature choice to FEATURE.md ## Decisions.\n\n## When Done\nTell human: "All tasks complete. Ready for final review." Then stop.\n' \
        "$feature_name" > "$tmpfile"

    jj-agent spawn "$slot" "$feature_name" --agent "$agent" --claude-md-file "$tmpfile"
    set -l spawn_status $status

    rm -f "$tmpfile"
    return $spawn_status
end
