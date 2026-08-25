---
name: context-switcher
description: >
  Understand and manage the Context Switcher plugin on Omarchy/Hyprland:
  per-context workspaces, slots, and Chrome profiles. Use when handling
  contexts (personal, work, ...), context switching, "Move to context",
  workspace slots, context menus, per-context Chrome profiles, editing
  ~/.config/context-switcher/config.json, or context keybindings
  (SUPER+ALT shortcuts, SUPER+1..0 slots). The config file is the source of
  truth: read it, edit it, reload.
---

# Context Switcher Skill

The Context Switcher partitions the user's workspaces into named
**contexts**, each owning a contiguous range of workspace **slots** and an
optional **Chrome profile**; the focused monitor belongs to exactly one
context, shown in the bar.

The config file is the source of truth. Almost every task is: **read**
`~/.config/context-switcher/config.json`, **edit** it, **reload**. The
keybindings and launcher menu are generated from it — never edit them.

## The Fast Path (covers most requests)

```bash
# 1. Read the config.
cat ~/.config/context-switcher/config.json

# 2. Edit it in place (plain JSON; the user hand-edits it in nvim, so an
#    agent editing it is fully expected).

# 3. Re-read + regenerate keybindings and the launcher menu.
omarchy-context-switcher reload
```

The workflow for *any* of these: rename a context, add/rename/reorder/delete
a menu item, change an icon, set a Chrome profile, add or remove a whole
context, change slot count, change the default profile. Everything is a
config edit + reload. (Runtime actions like "switch to personal now" or
"go to slot 4" have no config equivalent — use the CLI for those; see the
quick reference at the bottom.)

## Config File Reference

Location: `~/.config/context-switcher/config.json`

### Top level

| Field | Type | Meaning |
|-------|------|---------|
| `version` | int | Schema version (currently `1`). Keep. |
| `slots` | int | Workspaces per context (default `10`). |
| `default_chrome_profile` | string | Chrome profile used by web items / the browser bind when a context doesn't override it. |
| `contexts` | array | The context definitions (order matters — see Workspaces & Slots). |

```json
{
  "version": 1,
  "slots": 10,
  "default_chrome_profile": "Default",
  "contexts": [ ... ]
}
```

### Context object

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | Slug used in commands and menu routes (`personal`, `work`). Unique. |
| `name` | string | Display name (shown in the bar/menus). |
| `icon` | string | Nerd Font glyph character (optional). |
| `shortcut` | string | Single letter bound to `SUPER+ALT+<letter>` for its menu. Unique, non-empty. |
| `chrome_profile` | string\|null | Chrome profile for this context's items; `null`/absent = `default_chrome_profile`. |
| `menu` | array | Menu items (see below). |

```json
{ "id": "work", "name": "Work", "icon": "\uf0b1", "shortcut": "W",
  "chrome_profile": "Profile 1", "menu": [] }
```

### Menu items

Every item: `label` (unique among siblings), optional `icon` (Nerd Font
glyph), and a `type`:

| Type | Extra fields | Runs as |
|------|--------------|---------|
| `web` | `url` | Chrome web app in the context's profile |
| `mosh` / `ssh` | `host`, optional `command`, `workdir` | Remote shell in a new terminal |
| `terminal` | `command` | Command in a new terminal window |
| `script` | `command` | Command run directly, no window |
| `submenu` | `items` (nested items) | A folder in the menu; nests arbitrarily deep |

```json
[
  { "label": "Instagram", "type": "web", "url": "https://instagram.com" },
  { "label": "Server", "type": "ssh", "host": "box.example.com", "command": "htop" },
  { "label": "Weather", "type": "script", "command": "~/.local/bin/outside" },
  { "label": "Financial", "type": "submenu",
    "items": [ { "label": "Bank", "type": "web", "url": "https://bank.com" } ] }
]
```

Nested items are addressed by dot-joined indices from the context's `menu`,
e.g. the item above is `0` (Web), the Bank item is `3.0`; editor routes use
the same paths (`edit-item <ctx> 3.0`).

Icon glyphs: paste any Nerd Font codepoint character (`\uf0b1` style). The
icon picker's glyph DB lives at `~/.cache/context-switcher/nerd-icons.json`
(name/hex entries from nerdfonts.com).

## Workspaces & Slots

The context at index `N` (in `contexts[]`) owns workspaces
`N*slots+1 .. (N+1)*slots` (default: 1-10, 11-20, ...). Consequences:

- Reordering `contexts[]` re-homes every context's workspaces — keep edits
  to append/remove at the end unless the user asks to renumber.
- Adding a context appends it after the last one (workspaces continue where
  the previous context ended).
- Deleting a context should use the CLI (`delete-context`) so its windows
  are moved out first; a bare config edit leaves its workspaces orphaned.

## Edit → Verify Checklist

1. Follow the schema above; JSON must parse (no trailing commas, quoted keys,
   unique `id`/`shortcut`/item labels per scope).
2. `omarchy-context-switcher validate` — config sanity check.
3. `omarchy-context-switcher reload` — re-reads config + state and
   regenerates `~/.config/hypr/context-bindings.lua` and the launcher menu
   extension (menu hot-reloads; binds reload via Hyprland).
4. `omarchy-context-switcher status` — expect `error: ""` and the expected
   context count.
5. Spot-check the launcher ("Contexts" section) and, for binds,
   `hyprctl binds` (letter keys print without a modifier prefix — expect
   `key: P`, `key: PERIOD`).
6. If the first run had no config at all, the service bootstraps default
   contexts (`Personal`, `Work`) automatically.

## Rules

- **Never** edit the generated files: `~/.config/hypr/context-bindings.lua`
  and `~/.config/omarchy/extensions/omarchy-menu.jsonc` — they are
  overwritten by every reload.
- **Never** mutate workspaces directly with `hyprctl` dispatches; the
  plugin tracks monitor-context and last-workspace state that a raw dispatch
  desyncs. Prefer `switch`/`goto`/`move`/`move-workspace` — or a config edit
  where the change is structural.
- Don't run `disable`/`teardown` for routine changes — they consolidate all
  open workspaces to 1..N and strip the plugin's binds + menu.

## CLI Quick Reference (runtime + when a config edit is riskier)

```bash
omarchy-context-switcher status                 # JSON health/state
omarchy-context-switcher list | current        # contexts / active context
omarchy-context-switcher switch <ctx>          # move this monitor into <ctx>, restore its last ws
omarchy-context-switcher move-workspace <ctx>  # move the ACTIVE workspace into <ctx> ("Move to <ctx>")
omarchy-context-switcher goto <slot> | move <slot> | cycle next|prev
omarchy-context-switcher delete-context <ctx> [target]   # safe context removal (moves windows out)
omarchy-context-switcher reload                # re-read config + regenerate (THE post-edit step)
omarchy-context-switcher validate
omarchy-context-switcher edit <ctx> | edit-item <ctx> <path> | reorder <ctx> [path]   # editor UI
```

`create-context`, `rename-context`, `set-shortcut`, `set-icon`,
`set-profile`, `add-item`, `rename-item`, `set-item-icon`, `delete-item`
exist but are all config edits under the hood — the direct edit + `reload`
is equivalent and often faster for an agent.

## Troubleshooting

- Reload ran but the menu looks stale → re-check `status`; the menu regenerates
  from the CURRENT config (make sure the edit saved; the file is parsed as
  strict JSON).
- "Move to context" did nothing → the helper must be executable
  (`~/.local/bin/omarchy-context-switcher-move-workspace`); check `status`
  for `error`.
- A shortcut doesn't fire → another bind owns the key or `shortcut` is
  duplicated; `hyprctl binds` shows the loaded set.
