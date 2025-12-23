#!/bin/bash

#######################################################################
# Wolfmans Backup Tool - Uninstall Script
#######################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="Wolfmans Backup Tool"
INSTALL_NAME="wolfmans-backup-tool"
BIN_DIR="$HOME/.local/bin"
ICONS_DIR="$HOME/.local/share/wolfmans-backup-tool"
CONFIG_DIR="$HOME/.config/wolfmans-backup-tool"
DESKTOP_FILE="$HOME/.local/share/applications/wolfmans-backup-tool.desktop"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  $APP_NAME - Uninstaller${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "This will remove:"
echo "  • Application: $BIN_DIR/$INSTALL_NAME"
echo "  • Desktop entry"
echo ""
echo -e "${YELLOW}Optional removal:${NC}"
echo "  • Icons: $ICONS_DIR"
echo "  • Config: $CONFIG_DIR"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled"
    exit 0
fi

echo ""

# Remove application
if [ -f "$BIN_DIR/$INSTALL_NAME" ]; then
    rm "$BIN_DIR/$INSTALL_NAME"
    echo -e "${GREEN}✓${NC} Removed application"
else
    echo -e "${YELLOW}⚠${NC} Application not found"
fi

# Remove desktop entry
if [ -f "$DESKTOP_FILE" ]; then
    rm "$DESKTOP_FILE"
    echo -e "${GREEN}✓${NC} Removed desktop entry"
    
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
else
    echo -e "${YELLOW}⚠${NC} Desktop entry not found"
fi

# Ask about data directories
echo ""
read -p "Remove icons and config? (y/N) " -n 1 -r
echo ""
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -d "$ICONS_DIR" ]; then
        rm -rf "$ICONS_DIR"
        echo -e "${GREEN}✓${NC} Removed icons directory"
    fi
    
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}✓${NC} Removed config directory"
    fi
else
    echo -e "${BLUE}ℹ${NC} Kept: $ICONS_DIR"
    echo -e "${BLUE}ℹ${NC} Kept: $CONFIG_DIR"
fi

echo ""
echo -e "${GREEN}Uninstall complete!${NC}"
echo ""