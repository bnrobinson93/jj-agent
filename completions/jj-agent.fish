set -l subcommands spawn done list status poll watch

complete -c jj-agent -f

# Help
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -l help -s h -d 'Show help'

# Subcommands
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -a spawn -d 'Create workspace, inject task, launch agent'
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -a done -d 'Clean up workspace and kill tmux window'
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -a list -d 'Show active agents for current repo'
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -a status -d 'Show all agents across all repos'

# spawn --agent flag
complete -c jj-agent -n '__fish_seen_subcommand_from spawn' \
    -l agent -d 'Agent CLI to run (default: claude)' -a 'claude codex opencode none'

# done --keep-change flag
complete -c jj-agent -n '__fish_seen_subcommand_from done' \
    -l keep-change -d 'Skip confirmation, preserve the JJ change'

# poll --timeout flag
complete -c jj-agent -n '__fish_seen_subcommand_from poll' \
    -l timeout -d 'Bail after N seconds'

# subcommand descriptions
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -a poll -d 'Block until any active slot writes .agent-done'
complete -c jj-agent -n "not __fish_seen_subcommand_from $subcommands" \
    -a watch -d 'Background watcher; auto-closes tmux windows on completion'

# watch --interval flag
complete -c jj-agent -n '__fish_seen_subcommand_from watch' \
    -l interval -d 'Poll interval in seconds (default: 5)'
