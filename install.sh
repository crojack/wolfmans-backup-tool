#!/bin/bash

#######################################################################
# Wolfmans Backup Tool - Simple Installation Script
# For Ubuntu/Debian/Mint Linux distributions
# Author: Zeljko Vukman (CroJack)
#######################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Wolfmans Backup Tool"
SOURCE_SCRIPT="wolfmans-backup-tool.pl"
INSTALL_NAME="wolfmans-backup-tool"

# Installation directories
BIN_DIR="$HOME/.local/bin"
ICONS_DIR="$HOME/.local/share/wolfmans-backup-tool/icons"
CONFIG_DIR="$HOME/.config/wolfmans-backup-tool"

#######################################################################
# Helper Functions
#######################################################################

print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check if running as root
check_not_root() {
    if [ "$EUID" -eq 0 ]; then 
        print_error "Please do not run this script as root or with sudo."
        print_info "The script will ask for sudo password when needed."
        exit 1
    fi
}

# Check if running on Debian-based system
check_debian_based() {
    if [ ! -f /etc/debian_version ]; then
        print_error "This script is designed for Debian-based systems (Ubuntu/Debian/Mint)."
        print_info "Your system does not appear to be Debian-based."
        exit 1
    fi
}

# Check for required commands
check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Install package with apt
install_package() {
    local package=$1
    local description=$2
    
    if dpkg -l | grep -q "^ii  $package "; then
        print_success "$description is already installed"
    else
        print_info "Installing $description..."
        if sudo apt-get install -y "$package" > /dev/null 2>&1; then
            print_success "$description installed successfully"
        else
            print_error "Failed to install $description"
            return 1
        fi
    fi
}

# Check if Perl module is installed
check_perl_module() {
    local module=$1
    perl -M"$module" -e 'exit 0' 2>/dev/null
}

#######################################################################
# Main Installation Steps
#######################################################################

install_dependencies() {
    print_header "Installing Dependencies"
    
    print_info "Updating package lists..."
    sudo apt-get update > /dev/null 2>&1
    print_success "Package lists updated"
    
    # Core Perl
    install_package "perl" "Perl"
    
    # GTK3 and Glib
    install_package "libgtk3-perl" "GTK3 Perl bindings"
    install_package "libglib-perl" "GLib Perl bindings"
    
    # JSON support
    install_package "libjson-perl" "JSON Perl module"
    
    # Additional Perl modules
    install_package "libfile-copy-recursive-perl" "File::Copy::Recursive"
    install_package "libtime-hires-perl" "Time::HiRes"
    
    # System utilities
    install_package "rsync" "rsync"
    install_package "tar" "tar"
    install_package "gzip" "gzip"
    install_package "gnupg" "GnuPG (encryption support)"
    
    # Build tools (for any additional Perl modules)
    install_package "build-essential" "Build essentials"
    install_package "cpanminus" "CPAN minus"
    
    print_success "All dependencies installed"
}

check_perl_modules() {
    print_header "Verifying Perl Modules"
    
    local modules=(
        "Gtk3"
        "Glib"
        "File::Path"
        "File::Find"
        "File::Copy::Recursive"
        "File::Copy"
        "File::Basename"
        "File::Temp"
        "Cwd"
        "POSIX"
        "Time::HiRes"
        "JSON"
        "Data::UUID"
        "Scalar::Util"
        "Encode"
    )
    
    local missing_modules=()
    
    for module in "${modules[@]}"; do
        if check_perl_module "$module"; then
            print_success "$module is available"
        else
            print_warning "$module is missing"
            missing_modules+=("$module")
        fi
    done
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        print_info "Installing missing Perl modules..."
        for module in "${missing_modules[@]}"; do
            print_info "Installing $module..."
            sudo cpanm --quiet --notest "$module" 2>/dev/null || true
        done
    fi
    
    print_success "Perl modules verified"
}

install_application() {
    print_header "Installing Application"
    
    # Check if source script exists
    if [ ! -f "$SCRIPT_DIR/$SOURCE_SCRIPT" ]; then
        print_error "Cannot find $SOURCE_SCRIPT in $SCRIPT_DIR"
        print_info "Please run this script from the application directory"
        exit 1
    fi
    
    # Create bin directory
    mkdir -p "$BIN_DIR"
    print_success "Created directory: $BIN_DIR"
    
    # Copy and rename the application
    cp "$SCRIPT_DIR/$SOURCE_SCRIPT" "$BIN_DIR/$INSTALL_NAME"
    chmod +x "$BIN_DIR/$INSTALL_NAME"
    print_success "Installed: $BIN_DIR/$INSTALL_NAME"
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        print_warning "~/.local/bin is not in your PATH"
        print_info "Add this line to your ~/.bashrc:"
        echo -e "${YELLOW}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    else
        print_success "You can run: $INSTALL_NAME"
    fi
}

install_icons() {
    print_header "Installing Icons"
    
    # Create icons directory
    mkdir -p "$ICONS_DIR"
    print_success "Created directory: $ICONS_DIR"
    
    # Copy icons if they exist
    local icons_copied=0
    
    if [ -d "$SCRIPT_DIR/icons" ]; then
        # Copy SVG files
        for icon_file in "$SCRIPT_DIR/icons"/*.svg; do
            if [ -f "$icon_file" ]; then
                cp "$icon_file" "$ICONS_DIR/"
                local icon_name=$(basename "$icon_file")
                print_success "Installed: $icon_name"
                icons_copied=$((icons_copied + 1))
            fi
        done
        
        # Copy PNG files
        for icon_file in "$SCRIPT_DIR/icons"/*.png; do
            if [ -f "$icon_file" ]; then
                cp "$icon_file" "$ICONS_DIR/"
                local icon_name=$(basename "$icon_file")
                print_success "Installed: $icon_name"
                icons_copied=$((icons_copied + 1))
            fi
        done
    fi
    
    if [ $icons_copied -eq 0 ]; then
        print_warning "No icons found in $SCRIPT_DIR/icons"
        print_info "You can add icons to $ICONS_DIR manually"
    fi
}

create_config_directory() {
    print_header "Creating Config Directory"
    
    mkdir -p "$CONFIG_DIR"
    print_success "Created directory: $CONFIG_DIR"
    print_info "Application settings will be stored here"
}

create_desktop_entry() {
    print_header "Creating Desktop Entry"
    
    local desktop_dir="$HOME/.local/share/applications"
    local desktop_file="$desktop_dir/wolfmans-backup-tool.desktop"
    local icon_path="$ICONS_DIR/wolfmans-backup-tool.svg"
    
    mkdir -p "$desktop_dir"
    
    # Determine icon to use
    local icon_line
    if [ -f "$icon_path" ]; then
        icon_line="Icon=$icon_path"
    else
        icon_line="Icon=drive-harddisk"
    fi
    
    # Create desktop entry
    cat > "$desktop_file" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Wolfmans Backup Tool
Comment=Comprehensive backup and restore solution for Linux
Exec=$BIN_DIR/$INSTALL_NAME
$icon_line
Terminal=false
Categories=System;Utility;Archiving;
Keywords=backup;restore;archive;incremental;wolfman;
StartupNotify=true
EOF
    
    chmod +x "$desktop_file"
    
    # Update desktop database
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi
    
    print_success "Desktop entry created"
    print_info "Launch from application menu: $APP_NAME"
}

verify_installation() {
    print_header "Verifying Installation"
    
    local all_good=true
    
    # Check if application was installed
    if [ -f "$BIN_DIR/$INSTALL_NAME" ] && [ -x "$BIN_DIR/$INSTALL_NAME" ]; then
        print_success "Application installed: $BIN_DIR/$INSTALL_NAME"
    else
        print_error "Application not found or not executable"
        all_good=false
    fi
    
    # Check directories
    if [ -d "$ICONS_DIR" ]; then
        print_success "Icons directory: $ICONS_DIR"
    else
        print_error "Icons directory missing"
        all_good=false
    fi
    
    if [ -d "$CONFIG_DIR" ]; then
        print_success "Config directory: $CONFIG_DIR"
    else
        print_error "Config directory missing"
        all_good=false
    fi
    
    # Check Perl
    if check_command perl; then
        print_success "Perl is installed"
    else
        print_error "Perl not found"
        all_good=false
    fi
    
    # Check critical modules
    if check_perl_module "Gtk3"; then
        print_success "Gtk3 module available"
    else
        print_error "Gtk3 module missing"
        all_good=false
    fi
    
    # Check system utilities
    local utils=("rsync" "tar" "gzip")
    for util in "${utils[@]}"; do
        if check_command "$util"; then
            print_success "$util is installed"
        else
            print_error "$util not found"
            all_good=false
        fi
    done
    
    if [ "$all_good" = true ]; then
        print_success "Installation verification passed!"
        return 0
    else
        print_error "Installation verification found issues"
        return 1
    fi
}

print_completion() {
    echo ""
    print_header "Installation Complete!"
    echo ""
    print_success "$APP_NAME has been installed successfully!"
    echo ""
    print_info "Installation locations:"
    echo "  • Application: $BIN_DIR/$INSTALL_NAME"
    echo "  • Icons: $ICONS_DIR"
    echo "  • Config: $CONFIG_DIR"
    echo ""
    print_info "How to run:"
    
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        echo "  1. Command line: $INSTALL_NAME"
        echo "  2. Application menu: $APP_NAME"
    else
        echo "  1. Full path: $BIN_DIR/$INSTALL_NAME"
        echo "  2. Application menu: $APP_NAME"
        echo ""
        print_warning "Add ~/.local/bin to PATH for command-line access:"
        echo -e "${YELLOW}  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc${NC}"
        echo -e "${YELLOW}  source ~/.bashrc${NC}"
    fi
    
    echo ""
    print_warning "System backups require administrator privileges"
    echo ""
}

#######################################################################
# Main Execution
#######################################################################

main() {
    echo ""
    print_header "$APP_NAME - Installation"
    echo ""
    
    # Pre-flight checks
    check_not_root
    check_debian_based
    
    # Confirm installation
    echo -e "${YELLOW}This will install:${NC}"
    echo "  • Dependencies (Perl, GTK3, rsync, tar, gzip, gnupg)"
    echo "  • Application to: $BIN_DIR"
    echo "  • Icons to: $ICONS_DIR"
    echo "  • Config directory: $CONFIG_DIR"
    echo "  • Desktop menu entry"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Installation cancelled"
        exit 0
    fi
    
    echo ""
    
    # Installation steps
    install_dependencies
    echo ""
    
    check_perl_modules
    echo ""
    
    install_application
    echo ""
    
    install_icons
    echo ""
    
    create_config_directory
    echo ""
    
    # Ask about desktop entry
    read -p "Create desktop menu entry? (Y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo ""
        create_desktop_entry
    fi
    
    echo ""
    
    # Verify and complete
    if verify_installation; then
        print_completion
        exit 0
    else
        echo ""
        print_error "Installation completed with errors"
        exit 1
    fi
}

# Run main
main "$@"
