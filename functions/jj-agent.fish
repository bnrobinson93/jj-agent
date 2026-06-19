function jj-agent
    set -l subcmd $argv[1]
    switch $subcmd
        case spawn
            _jj_agent_spawn $argv[2..]
        case done
            _jj_agent_done $argv[2..]
        case list
            _jj_agent_list
        case status
            _jj_agent_status
        case poll
            _jj_agent_poll $argv[2..]
        case --help -h help ''
            echo "usage: jj-agent <subcommand> [args]"
            echo ""
            echo "subcommands:"
            echo "  spawn <slot> \"<task>\" [--agent <cmd>] [--prompt-file <path>]"
            echo "      create workspace, inject task, launch agent"
            echo "  done <slot> [--keep-change]"
            echo "      clean up workspace and kill tmux window"
            echo "  list"
            echo "      show active agents for current repo"
            echo "  status"
            echo "      show all agents across all repos"
            echo "  poll [<slot>] [--timeout <secs>]"
            echo "      block until a slot writes .agent-done"
            echo ""
            echo "  --agent: claude (default), codex, opencode, none"
        case '*'
            echo "unknown subcommand: $subcmd" >&2
            echo "run 'jj-agent --help' for usage" >&2
            return 1
    end
end

# --- Helpers ---

function _jj_agent_main_root
    set -l root (jj workspace root 2>/dev/null)
    or begin
        echo "not in a jj repository" >&2
        return 1
    end
    set -l base (basename $root)
    set -l workspace_suffix_re '-(ai[0-9]*|exp|explore)$'
    if string match -qr -- "$workspace_suffix_re" $base
        set base (string replace -r -- "$workspace_suffix_re" '' $base)
    end
    echo (dirname $root)/$base
end

function _jj_agent_state_file
    echo "$argv[1]/.jj/agent-state.toml"
end

function _jj_agent_state_write
    set -l state_file $argv[1]
    set -l slot $argv[2]
    set -l task $argv[3]
    set -l change_id $argv[4]
    set -l workspace $argv[5]
    set -l agent $argv[6]
    set -l spawned_at (date -u +"%Y-%m-%dT%H:%M:%SZ")

    env STATE_FILE="$state_file" SLOT="$slot" TASK="$task" \
        CHANGE_ID="$change_id" WORKSPACE="$workspace" \
        AGENT="$agent" SPAWNED_AT="$spawned_at" \
        python3 -c "
import os, tomllib, pathlib

path = pathlib.Path(os.environ['STATE_FILE'])
data = {}
if path.exists():
    data = tomllib.loads(path.read_text())
slots = data.get('slots', {})

slots[os.environ['SLOT']] = {
    'task':       os.environ['TASK'],
    'change_id':  os.environ['CHANGE_ID'],
    'workspace':  os.environ['WORKSPACE'],
    'spawned_at': os.environ['SPAWNED_AT'],
    'agent':      os.environ['AGENT'],
}

lines = []
for s, v in slots.items():
    lines.append(f'[slots.{s}]')
    lines.append(f'task        = {repr(v[\"task\"])}')
    lines.append(f'change_id   = {repr(v[\"change_id\"])}')
    lines.append(f'workspace   = {repr(v[\"workspace\"])}')
    lines.append(f'spawned_at  = {repr(v[\"spawned_at\"])}')
    lines.append(f'agent       = {repr(v[\"agent\"])}')
    lines.append('')

path.write_text('\n'.join(lines))
"
end

function _jj_agent_state_remove
    set -l state_file $argv[1]
    set -l slot $argv[2]
    test -f "$state_file" || return 0

    env STATE_FILE="$state_file" SLOT="$slot" python3 -c "
import os, tomllib, pathlib

path = pathlib.Path(os.environ['STATE_FILE'])
data = tomllib.loads(path.read_text())
slots = data.get('slots', {})
slots.pop(os.environ['SLOT'], None)

lines = []
for s, v in slots.items():
    lines.append(f'[slots.{s}]')
    lines.append(f'task        = {repr(v[\"task\"])}')
    lines.append(f'change_id   = {repr(v[\"change_id\"])}')
    lines.append(f'workspace   = {repr(v[\"workspace\"])}')
    lines.append(f'spawned_at  = {repr(v[\"spawned_at\"])}')
    lines.append(f'agent       = {repr(v[\"agent\"])}')
    lines.append('')

path.write_text('\n'.join(lines))
"
end

function _jj_agent_state_get
    set -l state_file $argv[1]
    set -l slot $argv[2]
    set -l field $argv[3]
    test -f "$state_file" || return 1

    env STATE_FILE="$state_file" SLOT="$slot" FIELD="$field" python3 -c "
import os, tomllib, pathlib, sys
data = tomllib.loads(pathlib.Path(os.environ['STATE_FILE']).read_text())
val = data.get('slots', {}).get(os.environ['SLOT'], {}).get(os.environ['FIELD'], '')
print(val)
sys.exit(0 if val else 1)
"
end

# Returns "slot<TAB>task<TAB>change_id<TAB>workspace" lines for all active slots
function _jj_agent_state_all
    set -l state_file $argv[1]
    test -f "$state_file" || return 0

    env STATE_FILE="$state_file" python3 -c "
import os, tomllib, pathlib
data = tomllib.loads(pathlib.Path(os.environ['STATE_FILE']).read_text())
for name, v in data.get('slots', {}).items():
    print('\t'.join([name, v.get('task',''), v.get('change_id',''), v.get('workspace','')]))
"
end

# Returns sibling context markdown block (empty string if no siblings)
function _jj_agent_sibling_context
    set -l state_file $argv[1]
    set -l current_slot $argv[2]
    test -f "$state_file" || return 0

    env STATE_FILE="$state_file" CURRENT_SLOT="$current_slot" python3 -c "
import os, tomllib, pathlib

data = tomllib.loads(pathlib.Path(os.environ['STATE_FILE']).read_text())
current = os.environ['CURRENT_SLOT']
siblings = [(n, v) for n, v in data.get('slots', {}).items() if n != current]
if not siblings:
    raise SystemExit(0)

print('## Related Changes')
for name, v in siblings:
    task = v.get('task', '(no description)')
    cid = v.get('change_id', '')[:8]
    print(f'- slot {name}: {task} (change: {cid})')
" 2>/dev/null
end

function _jj_agent_context_template
    set -l repo_template "$argv[1]/.jj/agent-template.md"
    set -l user_template "$HOME/.config/jj-agent/template.md"
    if test -f "$repo_template"
        cat "$repo_template"
    else if test -f "$user_template"
        cat "$user_template"
    else
        printf '# Task: {task}\n\n## Context\n- Repo: {repo_name}\n- Forked from: {parent_change_id}\n- Spawned: {timestamp}\n\n## Scope\nWork in this workspace only (`{workspace_path}`).\n\n{related_changes}\n## When Finished\nWrite an empty file `.agent-done` to this workspace root.\nDo not exit — wait for the orchestrator or human to review and call `jj-agent done {slot}`.\n'
    end
end

# Update FEATURE.md Agents table on spawn (no-op if file absent)
function _jj_agent_feature_spawn
    set -l feature_md $argv[1]
    set -l slot $argv[2]
    set -l task $argv[3]
    set -l change_id $argv[4]
    test -f "$feature_md" || return 0

    env FEATURE_MD="$feature_md" SLOT="$slot" TASK="$task" CHANGE_ID="$change_id" python3 -c "
import os, pathlib, re

path = pathlib.Path(os.environ['FEATURE_MD'])
content = path.read_text()
slot = os.environ['SLOT']
task = os.environ['TASK']
cid = os.environ['CHANGE_ID'][:8]

new_row = f'| {slot} | {task} | {cid} | in-progress |\n'

# Update existing row or append to ## Agents section
slot_re = re.compile(rf'^\| {re.escape(slot)} \|[^\n]*\n', re.MULTILINE)
if slot_re.search(content):
    content = slot_re.sub(new_row, content)
else:
    agents_match = re.search(r'(## Agents\n(?:\|[^\n]*\n)*)', content)
    if agents_match:
        content = content[:agents_match.end()] + new_row + content[agents_match.end():]

path.write_text(content)
"
end

# Update FEATURE.md Agents table on done (no-op if file absent)
function _jj_agent_feature_done
    set -l feature_md $argv[1]
    set -l slot $argv[2]
    test -f "$feature_md" || return 0

    env FEATURE_MD="$feature_md" SLOT="$slot" python3 -c "
import os, pathlib, re

path = pathlib.Path(os.environ['FEATURE_MD'])
content = path.read_text()
slot = os.environ['SLOT']

# Mark in-progress → done for this slot's row
row_re = re.compile(rf'(\| {re.escape(slot)} \|[^|]*\|[^|]*\|)\s*in-progress\s*\|', re.MULTILINE)
content = row_re.sub(r'\1 done |', content)
path.write_text(content)
"
end

# Read a list or scalar from ~/.config/jj-agent/config.toml
function _jj_agent_config_get
    set -l key $argv[1]
    set -l config_file "$HOME/.config/jj-agent/config.toml"
    test -f "$config_file" || return 1

    env CONFIG_FILE="$config_file" KEY="$key" python3 -c "
import os, tomllib, pathlib, sys
data = tomllib.loads(pathlib.Path(os.environ['CONFIG_FILE']).read_text())
val = data.get(os.environ['KEY'])
if val is None:
    sys.exit(1)
if isinstance(val, list):
    for item in val:
        print(item)
else:
    print(val)
"
end

# --- Subcommands ---

function _jj_agent_spawn
    if contains -- --help $argv; or contains -- -h $argv
        echo "usage: jj-agent spawn <slot> \"<task>\" [--agent <cmd>] [--prompt-file <path>]"
        echo ""
        echo "  slot          name for this workspace (e.g. 1, auth, ui)"
        echo "  task          description passed as opening prompt to the agent"
        echo "  --agent       claude (default), codex, opencode, none"
        echo "  --prompt-file override built-in template; file content piped to agent"
        return 0
    end

    set -l agent claude
    set -l slot
    set -l task
    set -l prompt_file ""

    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case --agent
                set i (math $i + 1)
                set agent $argv[$i]
            case --prompt-file
                set i (math $i + 1)
                set prompt_file $argv[$i]
            case '*'
                if test -z "$slot"
                    set slot $argv[$i]
                else
                    set task $argv[$i]
                end
        end
        set i (math $i + 1)
    end

    if test -z "$slot"
        echo "usage: jj-agent spawn <slot> [--agent <cmd>] [--prompt-file <path>] \"<task>\"" >&2
        return 1
    end

    set -l main_root (_jj_agent_main_root)
    or return 1

    set -l target_dir $main_root-$slot
    set -l repo_name (basename $main_root)
    set -l git_dir "$main_root/.git"
    set -l state_file (_jj_agent_state_file $main_root)
    set -l feature_md "$main_root/FEATURE.md"
    set -l original_dir "$PWD"
    set -l timestamp (date -u +"%Y-%m-%dT%H:%M:%SZ")

    set -l parent_change_id (jj --repository "$main_root" log -r @ --no-graph -T 'change_id' 2>/dev/null)
    if test -z "$parent_change_id"
        set parent_change_id (jj log -r @ --no-graph -T 'change_id')
    end

    if test -d "$target_dir"
        echo "slot $slot already exists at $target_dir — use 'jj-agent done $slot' first" >&2
        return 1
    end

    jj workspace add "$target_dir"
    or return 1

    cd "$target_dir"
    or return 1

    jj new $parent_change_id
    or begin; cd "$original_dir"; return 1; end

    if test -n "$task"
        jj describe -m "$task"
    end

    set -l worker_change_id (jj log -r @ --no-graph -T 'change_id')

    # Build prompt to pipe to agent; written to /tmp (never touches workspace)
    set -l tmp_prompt "/tmp/jj-agent-$repo_name-$slot"
    if test "$agent" != none
        if test -n "$prompt_file" -a -f "$prompt_file"
            cp "$prompt_file" "$tmp_prompt"
        else
            set -l sibling_ctx (_jj_agent_sibling_context "$state_file" "$slot")
            if test -n "$sibling_ctx"
                set sibling_ctx "$sibling_ctx\n\n"
            end
            set -l tmpl (_jj_agent_context_template $main_root)
            printf '%s' "$tmpl" \
                | string replace -a '{task}' "$task" \
                | string replace -a '{repo_name}' "$repo_name" \
                | string replace -a '{parent_change_id}' "$parent_change_id" \
                | string replace -a '{workspace_path}' "$target_dir" \
                | string replace -a '{timestamp}' "$timestamp" \
                | string replace -a '{slot}' "$slot" \
                | string replace -a '{related_changes}' "$sibling_ctx" \
                > "$tmp_prompt"
        end
    end

    # Write state and update FEATURE.md
    _jj_agent_state_write "$state_file" "$slot" "$task" "$worker_change_id" "$target_dir" "$agent"
    _jj_agent_feature_spawn "$feature_md" "$slot" "$task" "$worker_change_id"

    cd "$original_dir"

    if set -q TMUX
        set -l tmux_args new-window -c "$target_dir" -n "$slot"
        if test -e "$git_dir"
            set tmux_args $tmux_args -e "GIT_DIR=$git_dir"
        end
        if test "$agent" = none
            tmux $tmux_args "mise trust 2>/dev/null; $SHELL"
        else
            tmux $tmux_args "mise trust 2>/dev/null; cat '$tmp_prompt' | $agent; rm -f '$tmp_prompt'; $SHELL"
        end
    else
        echo "warning: not in tmux — workspace ready but not opened" >&2
        echo "  workspace: $target_dir"
        if test "$agent" != none
            echo "  run: cd $target_dir && cat '$tmp_prompt' | $agent"
        else
            echo "  run: cd $target_dir"
        end
        if test -f "$feature_md"
            echo "  feature:  $feature_md"
        end
    end

    echo "slot $slot ready → $target_dir"
end

function _jj_agent_done
    if contains -- --help $argv; or contains -- -h $argv
        echo "usage: jj-agent done <slot> [--keep-change]"
        echo ""
        echo "  slot          slot name to clean up"
        echo "  --keep-change skip confirmation; preserve the JJ change in graph"
        return 0
    end

    set -l slot
    set -l keep_change false

    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case --keep-change
                set keep_change true
            case '*'
                if test -z "$slot"
                    set slot $argv[$i]
                end
        end
        set i (math $i + 1)
    end

    if test -z "$slot"
        echo "usage: jj-agent done <slot> [--keep-change]" >&2
        return 1
    end

    set -l main_root (_jj_agent_main_root)
    or return 1
    set -l state_file (_jj_agent_state_file $main_root)
    set -l feature_md "$main_root/FEATURE.md"

    set -l workspace (_jj_agent_state_get "$state_file" "$slot" workspace)
    set -l change_id (_jj_agent_state_get "$state_file" "$slot" change_id)
    set -l task (_jj_agent_state_get "$state_file" "$slot" task)

    if test -z "$workspace"
        echo "no active slot '$slot' in this repo" >&2
        return 1
    end

    if test "$keep_change" = false
        set -l short_id (string sub -l 8 "$change_id")
        read -P "clean up slot $slot ($short_id: $task)? [y/N] " confirm
        if not string match -qi 'y' "$confirm"
            echo "cancelled"
            return 0
        end
    end

    if test -d "$workspace"
        jj workspace forget "$workspace" 2>/dev/null
        rm -rf "$workspace"
    end

    if set -q TMUX
        tmux kill-window -t "$slot" 2>/dev/null
    end

    _jj_agent_state_remove "$state_file" "$slot"
    _jj_agent_feature_done "$feature_md" "$slot"
    set -l repo_name (basename $main_root)
    rm -f "/tmp/jj-agent-$repo_name-$slot"

    echo "slot $slot cleaned up"
end

function _jj_agent_list
    set -l main_root (_jj_agent_main_root)
    or return 1
    set -l state_file (_jj_agent_state_file $main_root)
    set -l repo_name (basename $main_root)

    if not test -f "$state_file"
        echo "no active agents in $repo_name"
        return 0
    end

    env STATE_FILE="$state_file" REPO="$repo_name" python3 -c "
import os, tomllib, pathlib

data = tomllib.loads(pathlib.Path(os.environ['STATE_FILE']).read_text())
slots = data.get('slots', {})

if not slots:
    print(f'no active agents in {os.environ[\"REPO\"]}')
else:
    print(f'{\"SLOT\":<10} {\"CHANGE\":<10} {\"DONE\":<6} TASK')
    for name, v in slots.items():
        short = v.get('change_id', '')[:8]
        workspace = v.get('workspace', '')
        done = '✓' if (workspace and pathlib.Path(workspace, '.agent-done').exists()) else ' '
        task = v.get('task', '')
        if len(task) > 55:
            task = task[:52] + '...'
        print(f'{name:<10} {short:<10} {done:<6} {task}')
    print()
    print(f'{len(slots)} active agent(s) in {os.environ[\"REPO\"]}')
"
end

function _jj_agent_status
    set -l search_paths (_jj_agent_config_get search_paths 2>/dev/null)
    if test -z "$search_paths"
        set search_paths $HOME
    end

    env SEARCH_PATHS=(string join ':' $search_paths) python3 -c "
import os, tomllib, pathlib

rows = []
for base_str in os.environ['SEARCH_PATHS'].split(':'):
    base = pathlib.Path(base_str).expanduser()
    if not base.exists():
        continue
    for state_file in base.rglob('.jj/agent-state.toml'):
        repo_root = state_file.parent.parent
        repo_name = repo_root.name
        try:
            data = tomllib.loads(state_file.read_text())
            for slot, v in data.get('slots', {}).items():
                short = v.get('change_id', '')[:8]
                workspace = v.get('workspace', '')
                done = '✓' if (workspace and pathlib.Path(workspace, '.agent-done').exists()) else ' '
                task = v.get('task', '')
                if len(task) > 45:
                    task = task[:42] + '...'
                rows.append((repo_name, slot, short, done, task))
        except Exception:
            pass

if not rows:
    print('no active agents')
else:
    print(f'{\"REPO\":<18} {\"SLOT\":<10} {\"CHANGE\":<10} {\"DONE\":<6} TASK')
    for repo, slot, change, done, task in rows:
        print(f'{repo:<18} {slot:<10} {change:<10} {done:<6} {task}')
"
end

function _jj_agent_poll
    if contains -- --help $argv; or contains -- -h $argv
        echo "usage: jj-agent poll [<slot>] [--timeout <secs>]"
        echo ""
        echo "  slot       wait for specific slot (default: any active slot)"
        echo "  --timeout  bail after N seconds (default: wait forever)"
        return 0
    end

    set -l target_slot ""
    set -l timeout_secs 0

    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case --timeout
                set i (math $i + 1)
                set timeout_secs $argv[$i]
            case '*'
                set target_slot $argv[$i]
        end
        set i (math $i + 1)
    end

    set -l main_root (_jj_agent_main_root)
    or return 1
    set -l state_file (_jj_agent_state_file $main_root)

    if not test -f "$state_file"
        echo "no active agents to poll" >&2
        return 1
    end

    if test -n "$target_slot"
        echo "polling slot $target_slot..."
    else
        echo "polling all active slots..."
    end

    env STATE_FILE="$state_file" TARGET_SLOT="$target_slot" TIMEOUT="$timeout_secs" python3 -c "
import os, tomllib, pathlib, time, sys

state_file = pathlib.Path(os.environ['STATE_FILE'])
target = os.environ.get('TARGET_SLOT', '')
timeout = int(os.environ.get('TIMEOUT', '0'))
start = time.time()

while True:
    try:
        data = tomllib.loads(state_file.read_text())
        slots = data.get('slots', {})
        to_check = {target: slots[target]} if (target and target in slots) else slots

        for name, v in to_check.items():
            workspace = v.get('workspace', '')
            if workspace and pathlib.Path(workspace, '.agent-done').exists():
                print(name)
                sys.exit(0)
    except Exception:
        pass

    if timeout > 0 and (time.time() - start) >= timeout:
        print(f'poll timed out after {timeout}s', file=sys.stderr)
        sys.exit(1)

    time.sleep(2)
"
end
