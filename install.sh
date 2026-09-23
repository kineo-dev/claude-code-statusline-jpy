#!/bin/bash
set -e
cd "$(dirname "$0")"

DEST="$HOME/.claude"
SETTINGS="$DEST/settings.json"

echo "Installing claude-code-statusline..."

if [ ! -f statusline.sh ]; then
    echo "  Error: statusline.sh not found next to install.sh" >&2
    exit 1
fi

mkdir -p "$DEST"

# Copy script
cp statusline.sh "$DEST/statusline.sh"
chmod +x "$DEST/statusline.sh"
echo "  Copied statusline.sh to $DEST/"

# Update settings.json
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

if command -v jq &>/dev/null; then
    cp "$SETTINGS" "${SETTINGS}.bak"
    chmod 600 "${SETTINGS}.bak" 2>/dev/null
    tmp=$(mktemp)
    if jq '. + {"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$SETTINGS"
        echo "  Updated $SETTINGS (backup: ${SETTINGS}.bak)"
    else
        rm -f "$tmp"
        echo ""
        echo "  Could not update $SETTINGS (invalid JSON?). Backup kept at ${SETTINGS}.bak."
        echo "  Please add the following manually:"
        echo '  "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}'
    fi
else
    echo ""
    echo "  jq not found. Please add the following to $SETTINGS manually:"
    echo '  "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}'
fi

echo ""
echo "Done. Restart Claude Code to apply."

# Windows note
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    echo ""
    echo "Windows users: copy statusline.ps1 to %USERPROFILE%\\.claude\\ and"
    echo "set the command to: powershell -NoProfile -File ~/.claude/statusline.ps1"
fi
