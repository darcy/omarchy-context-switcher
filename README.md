# omarchy-context-switcher

Per-monitor workspace contexts for Omarchy 4 (Quattro).

A Quickshell plugin (bar-widget + service) that groups workspaces into named
contexts (e.g. Personal, Work, Gaming), one per monitor, each with N slots.
The bar shows the focused monitor's context name and its slot occupancy; keys
and menus switch context, jump to slots, move windows, and cycle workspaces.

## What it provides

- **Bar-widget** — active context name + N slot indicators (active / occupied /
  empty). Click a slot to go to it; click the name to advance context.
- **Service** (`context` IPC target) — owns config/state, tracks per-monitor
  context, implements all commands.
- **`omarchy-context`** CLI — `switch|goto|move|move-silent|move-workspace|cycle|next|prev|current|list|validate`.
- **`omarchy-context-generate`** — generates the Hyprland keybindings and the
  shell-menu extension from the config file.

## Configuration

The plugin reads `~/.config/context-switcher/config.json`:

```json
{
  "version": 1,
  "slots": 10,
  "default_chrome_profile": "Default",
  "contexts": [
    { "id": "personal", "name": "Personal", "icon": "…", "shortcut": "P", "menu": [] },
    { "id": "work",     "name": "Work",     "icon": "…", "shortcut": "W", "menu": [] }
  ]
}
```

Workspace ids are computed as `base = index * slots + 1`; each context owns a
contiguous block of `slots` workspaces.

## Install

```bash
./install.sh
```

This copies the plugin into `~/.config/omarchy/plugins/context-switcher/`,
installs the CLI to `~/.local/bin/`, generates the keybindings
(`~/.config/hypr/context-bindings.lua`) and menu extension, enables the plugin,
places the bar-widget on the left, and reloads Hyprland.

Or install as a git plugin:

```bash
omarchy plugin add <this-git-url> --enable --yes
omarchy bar put context-switcher --section left
```

## Keybindings (generated)

- `Super+Alt+<shortcut>` — open a context's menu
- `Super+Alt+.` — main context menu
- `Super+1..0` — go to slot N in the active context
- `Super+Shift+1..0` — move window to slot N
- `Super+Shift+Alt+1..0` — move window silently to slot N
- `Super+Tab` / `Super+Shift+Tab` — cycle workspaces within contexts

## Notes

- The `omarchy.*` plugin namespace is reserved for first-party plugins, so the
  plugin id is `context-switcher` (the repo name is `omarchy-context-switcher`).
- `legacy/` holds the original pre-Quattro bash implementation for reference.
