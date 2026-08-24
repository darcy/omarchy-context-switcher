#!/bin/bash
set -euo pipefail

# context-switcher installer (Quattro / Omarchy 4).
# Installs the Context Switcher Quickshell plugin, its CLI, generated
# keybindings, and shell-menu extension. Idempotent; backs up what it replaces.
#
# The plugin reads ~/.config/context-switcher/config.json at runtime. If the
# file is missing it writes an empty default; supply your own contexts there.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${HOME}/.local/share/context-switcher/backups/$(date +%s)"
PLUGIN_ID="context-switcher"
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
HYPRE_DIR="$HOME/.config/hypr"
CONFIG_FILE="$HOME/.config/context-switcher/config.json"

mkdir -p "$BACKUP_DIR" "$BIN_DIR" "$HYPRE_DIR" "$PLUGIN_DST"
PATH="$HOME/.local/share/omarchy/bin:$PATH"

echo "=== Installing context-switcher ==="

# 1. Plugin files (manifest + QML + JS live at the repo root) ->
#    ~/.config/omarchy/plugins/<id>/
echo "--- Plugin ---"
if [[ -e "$PLUGIN_DST/manifest.json" ]]; then
  cp -a "$PLUGIN_DST/manifest.json" "$BACKUP_DIR/" 2>/dev/null || true
fi
rm -rf "$PLUGIN_DST"
mkdir -p "$PLUGIN_DST"
cp -a "$REPO/manifest.json" "$REPO/ContextService.qml" "$REPO/ContextBarWidget.qml" "$REPO/ContextMenuPanel.qml" "$REPO/ContextModel.js" "$PLUGIN_DST/"
echo "Installed plugin to $PLUGIN_DST"

# 2. CLI + generator scripts -> ~/.local/bin/
echo "--- CLI ---"
for f in omarchy-context omarchy-context-generate omarchy-context-move-workspace omarchy-context-delete-context omarchy-context-launch omarchy-context-profiles omarchy-context-disable omarchy-context-teardown omarchy-context-setup; do
  if [[ -f "$BIN_DIR/$f" ]]; then cp -a "$BIN_DIR/$f" "$BACKUP_DIR/" 2>/dev/null || true; fi
  cp "$REPO/bin/$f" "$BIN_DIR/$f"
  chmod +x "$BIN_DIR/$f"
  echo "Installed $f"
done

# 3. Config must exist for binding/menu generation. Write an empty default if
#    missing; otherwise the user's own config drives generation.
echo "--- Config ---"
if [[ ! -f "$CONFIG_FILE" ]]; then
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'JSON'
{
  "version": 1,
  "slots": 10,
  "default_chrome_profile": "Default",
  "contexts": [
    { "id": "personal", "name": "Personal", "icon": "\uf1d4", "shortcut": "P", "menu": [] },
    { "id": "work", "name": "Work", "icon": "\uf1d4", "shortcut": "W", "menu": [] }
  ]
}
JSON
  echo "Created default config (Personal + Work): $CONFIG_FILE"
fi
  # 4. Generated keybindings -> ~/.config/hypr/context-bindings.lua
  echo "--- Keybindings ---"
  "$BIN_DIR/omarchy-context-generate" --bindings > "$HYPRE_DIR/context-bindings.lua"
  echo "Wrote $HYPRE_DIR/context-bindings.lua"

  # Ensure bindings.lua sources it.
  BINDINGS_LUA="$HYPRE_DIR/bindings.lua"
  if [[ -f "$BINDINGS_LUA" ]] && ! grep -q 'context-bindings' "$BINDINGS_LUA"; then
    cp -a "$BINDINGS_LUA" "$BACKUP_DIR/bindings.lua"
    cat >> "$BINDINGS_LUA" <<'LUA'

-- Context Switcher generated bindings (menus, slots, cycle).
dofile(os.getenv("HOME") .. "/.config/hypr/context-bindings.lua")
LUA
    echo "Appended context-bindings source to bindings.lua"
  else
    echo "bindings.lua already sources context-bindings (or missing)"
  fi

  # 6. Menu extension -> ~/.config/omarchy/extensions/omarchy-menu.jsonc
  #    The launcher is the system menu (fast, searchable); management actions
  #    inside it summon the editor.
  echo "--- Menu extension ---"
  mkdir -p "$HOME/.config/omarchy/extensions"
  "$BIN_DIR/omarchy-context-generate" --menu > "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  echo "Wrote menu extension"
  omarchy menu refresh >/dev/null 2>&1 || true

# 8. Enable the plugin (idempotent).
echo "--- Enable plugin ---"
omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || echo "  (plugin enable reported non-zero; may already be enabled or need a shell rescan)"

# 7. Place the bar-widget in the left section if not already present, and hide
#    the default omarchy.workspaces widget (the context-switcher replaces it).
echo "--- Bar widget ---"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
if [[ -f "$SHELL_JSON" ]]; then
  jq '(.bar.layout.left) = ([.bar.layout.left[] | select(.id != "omarchy.workspaces" and .id != "context-switcher")] + [{"id": "context-switcher"}])' \
    "$SHELL_JSON" > "$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
  echo "Removed default omarchy.workspaces; ensured context-switcher in left section"
else
  omarchy bar put "$PLUGIN_ID" --section left >/dev/null 2>&1 || true
fi

# 8. Reload Hyprland for the new bindings.
echo "--- Reload ---"
hyprctl reload >/dev/null 2>&1 && echo "Hyprland reloaded." || echo "NOTE: hyprctl reload failed (is Hyprland running?)."

echo ""
echo "Done. Backups in: $BACKUP_DIR"
echo "TIP: restart the shell (omarchy-restart-shell) if the bar widget does not appear."
