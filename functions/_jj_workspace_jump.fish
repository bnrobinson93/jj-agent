function _jj_workspace_jump --argument-names suffix
    set -l root (jj workspace root 2>/dev/null)
    or begin
        echo "Not in a jj repository" >&2
        return 1
    end

    set -l base (basename $root)
    set -l change_id (jj log -r @ --no-graph -T 'change_id')
    set -l workspace_suffix_re '-(ai[0-9]*|orch[^/]*|exp|explore)$'

    if string match -qr -- "$workspace_suffix_re" $base
        set base (string replace -r -- "$workspace_suffix_re" '' $base)
    end

    set -l main_root (dirname $root)/$base
    set -l target_dir $main_root-$suffix
    set -l has_git_dir false
    set -l supports_update_stale false
    set -l git_dir "$main_root/.git"

    if test -e "$git_dir"
        set has_git_dir true
    end

    if jj workspace update-stale --help >/dev/null 2>&1
        set supports_update_stale true
    end

    if test "$target_dir" = "$root"
        echo "Already in $suffix workspace" >&2
        return 0
    end

    set -l original_dir "$PWD"

    if not test -d "$target_dir"
        jj workspace add "$target_dir"
        or return 1
        cd "$target_dir"
        or begin
            if set -q TMUX
                cd "$original_dir"
            end
            return 1
        end
        jj new $change_id
        or begin
            if set -q TMUX
                cd "$original_dir"
            end
            return 1
        end
    else
        cd "$target_dir"
        or begin
            if set -q TMUX
                cd "$original_dir"
            end
            return 1
        end

        if test "$supports_update_stale" = true
            jj workspace update-stale
            or begin
                if set -q TMUX
                    cd "$original_dir"
                end
                return 1
            end
        end
    end

    # Point git tools (gh, etc.) at the main repo's .git so they work from workspaces
    if set -q TMUX
        cd "$original_dir"
        set -l tmux_args new-window -c "$target_dir" -n $suffix
        if test "$has_git_dir" = true
            set tmux_args $tmux_args -e "GIT_DIR=$git_dir"
        end
        tmux $tmux_args "mise trust 2>/dev/null; $SHELL"
    else
        cd "$target_dir"
        or return 1
        _jj_workspace_sync_git_env
        mise trust 2>/dev/null
    end
end
