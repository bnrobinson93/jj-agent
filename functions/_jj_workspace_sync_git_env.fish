function _jj_workspace_sync_git_env
    set -l workspace_root (jj workspace root 2>/dev/null)
    or begin
        set -e GIT_DIR
        return 0
    end

    set -l workspace_suffix_re '-(ai[0-9]*|exp|explore)$'
    set -l workspace_base (basename "$workspace_root")

    if not string match -qr -- "$workspace_suffix_re" "$workspace_base"
        set -e GIT_DIR
        return 0
    end

    set -l main_base (string replace -r -- "$workspace_suffix_re" '' "$workspace_base")
    set -l main_root (dirname "$workspace_root")/"$main_base"
    set -l git_dir "$main_root/.git"

    if test -e "$git_dir"
        set -gx GIT_DIR "$git_dir"
    else
        set -e GIT_DIR
    end
end
