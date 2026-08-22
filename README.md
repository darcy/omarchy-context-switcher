# omarchy-context-switcher

Per-monitor workspace contexts for Omarchy 4 (Quattro).

A Quickshell plugin (bar-widget + service) that groups workspaces into named
contexts (e.g. Personal, Work, Gaming), one per monitor, each with N slots.
The bar shows the focused monitor's context name and its slot occupancy; keys
and menus switch context, jump to slots, move windows, and cycle workspaces.

## What it provides

- **Bar-widget** — active context name + N slot indicators (active / occupied /
  empty). Click a slot to go to it; click the name to open the system menu's
  "Contexts" section (right-click advances context).
- **Launcher = the system menu** — `omarchy-context-generate --menu` writes an
  `omarchy-menu.jsonc` extension with a searchable "Contexts" section. Each
  context is a submenu of launch items plus management actions (Go to, a
  single "Edit <context>" submenu — Edit details, Add item, Reorder Items,
  then Edit <item> for each item — and Move workspace).
- **Chrome profiles** — a context's `chrome_profile` selects the profile used
  for its web items and its auto-inserted "Browser" item (only present when a
  profile is set). URLs always launch with an explicit profile (the context's,
  or `default_chrome_profile`) so Chromium never falls back to the last-used
  profile. Item types are Web, Mosh, SSH, Terminal, Script — "Browser" is no
  longer a manual item type.
- **Reorder** — "Reorder Items" opens a reorder view: move the cursor with
  Up/Down (or j/k) and reorder with Shift+Up/Down or mouse drag; Esc/Done
  persists the new order.
- **Editor** (`ContextMenuPanel.qml`) — a centered Quickshell overlay used only
  for management forms: add/edit/delete contexts and add/edit/delete items. It
  is summoned by the system menu's management actions, never by the launcher,
  and returns to the system menu on save/cancel.
- **Service** (`context` IPC target) — owns config/state, tracks per-monitor
  context, implements all commands, and persists config edits from the editor.
- **`omarchy-context`** CLI — `switch|goto|move|move-silent|move-workspace|cycle|next|prev|current|list|menu|edit|edit-item|reorder|edit-json|add-context|rename-context|set-shortcut|set-icon|set-profile|delete-context|add-item|rename-item|set-item-icon|delete-item|validate|status`.
- **`omarchy-context-profiles`** — list the default browser's Chrome profiles.
- **`omarchy-context-launch`** — open a URL/browser with a specific profile.
- **`omarchy-context-generate`** — generates the Hyprland keybindings and the
  system-menu extension from the config file.

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
(`~/.config/hypr/context-bindings.lua`) and the menu extension
(`~/.config/omarchy/extensions/omarchy-menu.jsonc`), enables the plugin, places
the bar-widget on the left, and reloads Hyprland.

Or install as a git plugin:

```bash
omarchy plugin add <this-git-url> --enable --yes
omarchy bar put context-switcher --section left
```

## Keybindings (generated)

- `Super+Alt+<shortcut>` — open the system menu at that context's items
- `Super+Alt+.` — open the system menu's Contexts picker
- `Super+1..0` — go to slot N in the active context
- `Super+Shift+1..0` — move window to slot N
- `Super+Shift+Alt+1..0` — move window silently to slot N
- `Super+Tab` / `Super+Shift+Tab` — cycle workspaces within contexts

## Notes

- The `omarchy.*` plugin namespace is reserved for first-party plugins, so the
  plugin id is `context-switcher` (the repo name is `omarchy-context-switcher`).
- `legacy/` holds the original pre-Quattro bash implementation for reference.
