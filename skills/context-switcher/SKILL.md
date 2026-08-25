---
name: context-switcher
description: >
  Understand and manage the Context Switcher plugin: per-context workspaces,
  slots, and Chrome profiles on Omarchy/Hyprland. Use when handling contexts
  (personal, work, ...), context switching, workspace slots, "Move to
  context", context menus, per-context Chrome profiles, context keybindings
  (SUPER+ALT shortcuts, SUPER+1..0 slots), the context bar widget, editing
  ~/.config/context-switcher/config.json, or the generated
  context-bindings.lua / omarchy-menu.jsonc Contexts section.
---

# Context Switcher Skill

The Context Switcher is a Quickshell plugin that partitions the user's
workspaces into named **contexts**. Each context owns a contiguous range of
workspace **slots** and can pin its own **Chrome profile**; the focused
monitor always belongs to exactly one context, shown in the bar.

Use this skill whenever a request involves contexts, workspace slots,
context-aware switching, or the context menus/keybindings. NEVER hand-edit
the generated files — the config is the source of truth.

## Key Concepts

- **Context** — a named workspace block, e.g. `personal`, `work`, `zippy`.
  Fields: `id`, `name`, `icon`, `shortcut`, `chrome_profile`, `menu`.
- **Slots** — each context owns `slots` (default 10) workspaces:
  context at index 0 → workspaces 1-10, index 1 → 11-20, etc. `goto`/`move`
  address workspaces by slot number within the active context.
- **Monitor binding** — the state tracks which context each monitor is in.
  `switch <ctx>` moves the monitor's current workspace into the target
  context's first empty slot, then restores that context's last workspace.
- **chrome_profile** — Chrome profile used by web/remote menu items; browser
  launch binds force the config's `default_chrome_profile` (not the
  last-used profile).
- **Menu items** — web, remote (JSON type `mosh` or `ssh`, one "Remote" UI
  row), terminal, script, and submenu (nested folder).

## Files

| Path | Role |
|------|------|
| `~/.config/context-switcher/config.json` | **Source of truth** (`version`, `slots`, `default_chrome_profile`, `contexts[]`) |
| `~/.local/state/context-switcher/context.json` | State: `monitor_context`, `last_workspace`. Regenerable — never hand-edit |
| `~/.config/hypr/context-bindings.lua` | **Generated** keybindings — do not edit |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | **Generated** launcher "Contexts" section — do not edit |
| `~/.config/omarchy/plugins/context-switcher/` | Plugin code (QML service/panel/bar + `skills/`) |

The first time the plugin runs with no config it bootstraps default contexts
(**Personal**, **Work**); the service also re-enforces the bar layout and
regenerates missing generated files on start.

## Query First (read-only)

```bash
omarchy-context-switcher status        # JSON: configLoaded, stateLoaded, focusedMonitor, currentContext, contexts, error
omarchy-context-switcher list          # id<TAB>name<TAB>shortcut per context
omarchy-context-switcher current       # active context on the focused monitor
omarchy-context-switcher validate      # config validation
cat ~/.config/context-switcher/config.json    # full item tree (read-only)
```

Always start with `status` and read the config before mutating anything.

## Managing Contexts (use the CLI — mutations go through the service)

```bash
omarchy-context-switcher switch <ctx>       # Move this monitor into context <ctx>, restoring its last workspace
omarchy-context-switcher move-workspace <ctx>  # Move the ACTIVE workspace to <ctx>'s first empty slot (= launcher "Move to <ctx>")
omarchy-context-switcher next | prev        # Switch to next/previous context
omarchy-context-switcher goto <slot>        # Jump to slot in the active context
omarchy-context-switcher move <slot>        # Move the active window to a slot (same context)
omarchy-context-switcher cycle next|prev    # Cycle workspaces globally, updating the context
omarchy-context-switcher cycle-monitor [dir] # Move active workspace to the next/prev monitor
omarchy-context-switcher create-context <name> <shortcut> [icon]   # New context; chrome_profile defaults to default_chrome_profile
omarchy-context-switcher rename-context <ctx> <name>
omarchy-context-switcher set-shortcut <ctx> <key>
omarchy-context-switcher set-icon <ctx> <glyph>
omarchy-context-switcher set-profile <ctx> <profile|->
omarchy-context-switcher delete-context <ctx> [target_id]  # Moves its windows out first, then removes it
```

Every context mutation regenerates bindings/menu automatically.

## Managing Menu Items

CLI (top-level items):

```bash
omarchy-context-switcher add-item <ctx> "<title>" "<url>" [icon]
omarchy-context-switcher rename-item <ctx> "<old>" "<new>"
omarchy-context-switcher set-item-icon <ctx> "<title>" <glyph>
omarchy-context-switcher delete-item <ctx> "<title>"
```

Editor UI (contexts and nested submenus):

```bash
omarchy-context-switcher edit <ctx>            # Edit the context (name/icon/shortcut)
omarchy-context-switcher edit <ctx> add        # Add a context
omarchy-context-switcher edit-item <ctx> add   # Add an item (top level)
omarchy-context-switcher edit-item <ctx> <path>     # Edit item at index path ("2", "2.1", ...)
omarchy-context-switcher edit-item <ctx> <path>.add # Add an item inside submenu at <path>
omarchy-context-switcher reorder <ctx> [path]  # Reorder/move items (Move/Edit Items screen)
```

## Hand-Editing the Config (users do this in nvim)

1. The config keeps a `contexts[]` array — each context: `id` (slug),
   `name`, `icon` (Nerd Font glyph), `shortcut` (single key), optional
   `chrome_profile`, `menu[]` (items: `type` web|mosh|ssh|terminal|script|submenu;
   submenus carry nested `items`).
2. After editing, `omarchy-context-switcher reload` — it re-reads config +
   state and regenerates bindings + menu. Editing generated files directly is
   pointless; they are overwritten.
3. Verify: `omarchy-context-switcher validate` then `status`; for keybindings,
   `hyprctl binds` shows loaded keys (letter keys print without modifier
   prefix — expect `key: P`, `key: PERIOD` for the context binds).

## Safety Rules

- **Never** move/delete workspaces directly with `hyprctl` dispatches —
  use the CLI so monitor-context state and per-context last-workspace stay in
  sync.
- **Never** edit `context-bindings.lua` or the menu extension directly.
- Prefer the CLI/service over config edits for mutations; a hand edit is fine
  but must be followed by `reload`.
- `disable`/`teardown` consolidate ALL open workspaces back to 1..N and strip
  the plugin's binds + menu — do not run them for routine fixes.

## Troubleshooting

- **"Move to context" did nothing** — the helper must be executable
  (`~/.local/bin/omarchy-context-switcher-move-workspace`); check `status`
  for `error`, then rerun the action.
- **Menu/keybindings stale after a config edit** — run `reload` (regenerates
  both); the menu extension hot-reloads, binds need `hyprctl reload` (the
  service does this itself).
- **Shortcut conflict** — context menus bind `SUPER+ALT+<shortcut>`; slots
  use `SUPER+1..0`. `hyprctl binds` prints the loaded set.

## Example Requests

- "Move my current desktop into Work" → `omarchy-context-switcher move-workspace work`
- "Switch to personal" → `omarchy-context-switcher switch personal`
- "Add a Work context" → `omarchy-context-switcher create-context Work W`
- "What context am I in?" → `omarchy-context-switcher current`
- "Rename the Zippy context to Zip" → `omarchy-context-switcher rename-context zippy Zip`
- "Make Infra use chrome Profile 2" → `omarchy-context-switcher set-profile infra "Profile 2"`
- "Open the launcher menu for personal" → `omarchy-context-switcher menu personal`
