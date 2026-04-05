# Subcommand Actions

This is the cli specific code. It contains cli actions and tui definitions and
argument parsing.

This README is meant as developer documentation and not as user documentation.
For user documentation, see the main README or [ghostty.org](https://ghostty.org/docs).

## Workspace Actions

The GTK build exposes workspace-control actions through the standard `ghostty +...`
CLI entrypoints. The current workspace actions are:

- `+workspace-list`
- `+workspace-open`
- `+workspace-save`
- `+workspace-restore`
- `+workspace-list-sessions`
- `+workspace-focus-session`
- `+workspace-split`
- `+workspace-close-session`

Each action defines its own `run` function doc comment and options struct in the
matching `src/cli/workspace_*.zig` file. General `ghostty +help` output is driven
by the `Action` enum in `src/cli/ghostty.zig`, so new actions should be added to
that enum and documented in their action file rather than hand-maintained in
`help.zig`.

## Updating documentation

Each cli action is defined in it's own file. Documentation for each action is defined
in the doc comment associated with the `run` function. For example the `run` function
in `list_keybinds.zig` contains the help text for `ghostty +list-keybinds`.
