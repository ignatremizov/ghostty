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

These actions share one implementation module in `src/cli/workspace.zig`.
General `ghostty +help` output is driven by the `Action` enum in
`src/cli/ghostty.zig`, and help extraction for the workspace commands now reads
the corresponding `run*` doc comments from that shared module rather than thin
per-command wrapper files.

## Updating documentation

Each cli action is defined in it's own file. Documentation for each action is defined
in the doc comment associated with the `run` function. For example the `run` function
in `list_keybinds.zig` contains the help text for `ghostty +list-keybinds`.
