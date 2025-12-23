# Wolfmans Backup Tool

A comprehensive, feature-rich backup and restore solution for Linux systems with a modern GTK3 graphical interface. Built with Perl, this tool provides flexible backup options including system backups, home directory backups, and custom file selection with support for incremental backups, compression, and encryption.

![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)
![Perl](https://img.shields.io/badge/perl-5.x-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)

## Features

### Core Functionality
- **Multiple Backup Types**
  - System files backup (privileged directories: /bin, /etc, /usr, /var, etc.)
  - Home directory backup
  - Custom file and folder selection with visual file browser
  
- **Incremental Backups**
  - Cumulative incremental backups (all changes from original)
  - Differential incremental backups (changes since last backup)
  - Automatic change detection based on file modification times
  - Incremental restore with full backup + incremental chains

- **Advanced Options**
  - **Compression**: gzip compression to reduce backup size
  - **Encryption**: AES256 symmetric encryption via GPG
  - **Verification**: Optional backup integrity checking
  - **Hidden Files**: Toggle inclusion of hidden files and directories
  - **Progress Tracking**: Real-time progress with speed and time estimates

### User Interface
- Modern GTK3 interface with tabbed navigation
- Backup and Restore modes with context-aware controls
- Real-time progress monitoring with elapsed/remaining time
- Visual feedback with color-coded buttons (suggested-action/destructive-action)
- Responsive design with proper window sizing and layout management

### Technical Features
- **Efficient Operations**: Uses rsync for directory-based backups and tar for archives
- **Smart Progress Calculation**: Dynamic size estimation with accurate percentage tracking
- **Privilege Management**: Secure sudo authentication with timestamp refresh
- **Metadata Tracking**: JSON-based backup metadata for restore intelligence
- **Process Management**: Forked child processes for non-blocking operations
- **Error Handling**: Comprehensive error checking and user-friendly error messages

## Screenshots

*TODO: Add screenshots of the application interface*

## Requirements

### System Requirements
- Linux operating system (tested on Ubuntu 24.04)
- Perl 5.x or higher
- GTK3 libraries
- Sufficient disk space for backups

### Perl Modules
- `Gtk3` - GTK3 bindings for Perl
- `Glib` - GLib event loop integration
- `File::Path` - Directory creation utilities
- `File::Find` - Directory traversal
- `File::Copy::Recursive` - Recursive file operations
- `File::Copy` - Basic file copying
- `File::Basename` - Path manipulation
- `File::Temp` - Temporary file handling
- `Cwd` - Working directory utilities
- `POSIX` - POSIX functions (time formatting, process control)
- `Time::HiRes` - High-resolution time measurements
- `JSON` (optional but recommended) - Metadata storage
- `Data::UUID` - Unique identifier generation
- `Scalar::Util` - Scalar utilities

### System Utilities
- `rsync` - For efficient file synchronization
- `tar` - For archive creation
- `gzip` - For compression
- `gpg` - For encryption (optional)
- `du` - For size calculations
- `find` - For file enumeration
- `sudo` - For privileged operations (system backups)

## Installation

### Install Dependencies

#### Debian/Ubuntu:
```bash
sudo apt-get update
sudo apt-get install perl libgtk3-perl libglib-perl libjson-perl rsync tar gzip gnupg
```

#### Fedora/RHEL:
```bash
sudo dnf install perl perl-Gtk3 perl-Glib perl-JSON rsync tar gzip gnupg2
```

#### Arch Linux:
```bash
sudo pacman -S perl perl-gtk3 perl-json rsync tar gzip gnupg
```

### Install Wolfmans Backup Tool

1. **Clone the repository:**
   ```bash
   git clone https://github.com/crojack/wolfmans-backup-tool.git
   cd wolfmans-backup-tool
   ```

2. **Make the script executable:**
   ```bash
   chmod +x wolfmans-backup-tool.pl
   ```

3. **Create icons directory (optional):**
   ```bash
   mkdir -p ~/.local/share/wolfmans-backup-tool/icons
   ```
   
4. **Add custom icons (optional):**
   - Place your icon files in `~/.local/share/wolfmans-backup-tool/icons/`
   - Required icons: `disc.svg`, `drive.png`

5. **Run the application:**
   ```bash
   ./wolfmans-backup-tool.pl
   ```

### Desktop Integration (Optional)

Create a desktop entry for easy access:

```bash
cat > ~/.local/share/applications/wolfmans-backup-tool.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Wolfmans Backup Tool
Comment=Comprehensive backup and restore solution
Exec=/path/to/wolfmans-backup-tool.pl
Icon=drive-harddisk
Terminal=false
Categories=System;Utility;Archiving;
EOF
```

Replace `/path/to/wolfmans-backup-tool.pl` with the actual path to the script.

## Usage

### Basic Backup Workflow

1. **Select Backup Type**
   - Choose between System, Home, or Custom backup
   - Custom backup allows selecting specific files/folders

2. **Configure Options**
   - Enable/disable hidden files inclusion
   - Enable compression to reduce backup size
   - Enable encryption for secure backups
   - Enable verification to check backup integrity

3. **Choose Destination**
   - Click "Select backup destination"
   - Choose where to save the backup
   - Optionally customize the backup name

4. **Start Backup**
   - Click "Start Backup"
   - For system backups, enter your password when prompted
   - For encrypted backups, enter and confirm encryption password
   - Monitor progress in real-time

### Incremental Backup Workflow

1. **Select Incremental Mode**
   - Choose "Cumulative" or "Differential" under Incremental Backup section
   
2. **Select Previous Backup**
   - Click "Select previous backup location"
   - Choose the folder containing your original backup
   - Tool will verify backup metadata

3. **Start Incremental Backup**
   - Click "Start Incremental Backup"
   - Only changed files since last backup will be copied
   - Creates timestamped incremental directory

### Restore Workflow

1. **Switch to Restore Tab**
   - Click "Restore" tab in the interface

2. **Select Backup Type**
   - Choose the type of backup you want to restore
   - Must match the original backup type

3. **Select Backup to Restore**
   - Click "Select backup to restore"
   - Choose the backup folder
   - For encrypted backups, enter decryption password

4. **Handle Incremental Backups**
   - If backup has incrementals, choose restoration option:
     - Restore full backup only
     - Restore full backup + all incrementals (recommended)

5. **Choose Restore Destination**
   - Select "Restore to original location" (recommended)
   - Or choose custom destination
   - Configure restore options (merge mode, backup existing files)

6. **Start Restore**
   - Click "Start restore"
   - Monitor progress
   - Verify restored files

## Configuration

### Settings File

Configuration is stored in: `~/.config/wolfmans-backup-tool/settings.conf`

Default settings:
```
window_width = "900"
window_height = "700"
border_width = "3"
last_backup_location = ""
```

### Backup Metadata

Each backup includes a `.backup_info.json` file with:
- Backup type and creation timestamp
- Source paths and original user information
- Compression and encryption settings
- Incremental backup history
- Suggested restore paths

Example metadata:
```json
{
   "version": "1.0",
   "created": 1703347200,
   "created_readable": "2024-12-23 14:30:00",
   "backup_type": "home",
   "compression_enabled": 1,
   "encryption_enabled": 0,
   "original_home": "/home/username",
   "incremental_backups": []
}
```

## Advanced Features

### System Backup

System backups require administrator privileges and include:
- `/bin` - Essential command binaries
- `/boot` - Boot loader files
- `/etc` - System configuration
- `/lib` - Shared libraries
- `/opt` - Optional software
- `/root` - Root user home
- `/sbin` - System binaries
- `/usr` - User programs
- `/var` - Variable data

Automatically excludes: `/proc`, `/sys`, `/dev`, `/tmp`, `/run`, `/mnt`, `/media`

### Incremental Backup Types

**Cumulative Incremental:**
- Backs up all changes since the original full backup
- Each incremental contains all changes from the beginning
- Restore requires: Full backup + Latest cumulative incremental
- Larger incremental size but simpler restore

**Differential Incremental:**
- Backs up only changes since the last backup (full or incremental)
- Each incremental contains only recent changes
- Restore requires: Full backup + All differential incrementals in sequence
- Smaller incremental size but more complex restore

### Encryption

Wolfmans Backup Tool uses GPG symmetric encryption with AES256:
- Password-based encryption (no key pairs needed)
- Secure password file handling with restricted permissions
- Automatic cleanup of sensitive data
- Compatible with standard GPG tools for manual decryption

To manually decrypt a backup:
```bash
gpg --decrypt backup_file.tar.gz.gpg > backup_file.tar.gz
```

### Progress Tracking

The tool provides accurate progress tracking:
- **Size-based calculation**: Uses `du` for fast directory size estimation
- **Dynamic adjustment**: Adjusts estimates if transfer exceeds initial calculation
- **Transfer speed**: Real-time MB/s or KB/s display
- **Time remaining**: Estimates based on current transfer rate
- **Percentage capping**: Caps at 95% during transfer, 99% during cache flush

## Troubleshooting

### Common Issues

**"Sudo authentication failed"**
- Ensure you enter the correct password
- Check that your user has sudo privileges
- Verify sudo is installed and configured

**"JSON module not available"**
- Install JSON module: `sudo apt-get install libjson-perl`
- Metadata will not be created, but backups will still work

**"Could not calculate total size"**
- Size calculation timed out (normal for very large directories)
- Backup will continue but without percentage display
- Progress shown as data transferred instead

**"Backup file not created or tar failed"**
- Check disk space on destination
- Verify write permissions to destination folder
- Review console output for specific tar errors

**Restore fails with "wrong password"**
- Ensure you're using the correct decryption password
- Verify the backup file is not corrupted
- Try decrypting manually with GPG to isolate the issue

### Debug Mode

Enable detailed logging by checking console output:
```bash
./wolmans-backup-tool.pl 2>&1 | tee backup.log
```

Debug log includes:
- Operation mode and backup type selections
- Size calculations and file counts
- Rsync/tar command execution
- Progress file updates
- Metadata operations
- Error messages with context

### Performance Tips

**For faster backups:**
- Disable compression if backing up already-compressed files
- Exclude unnecessary directories (cache, thumbnails, etc.)
- Use rsync-based backups (no compression) for speed
- Backup to fast storage (SSD, local disk) instead of network drives

**For smaller backups:**
- Enable compression (reduces size by ~50-70% for text files)
- Exclude cache directories and temporary files
- Use incremental backups for regular backups
- Consider excluding large media files

## Project Structure

```
wolfmans-backup-tool/
├── wolfmans-backup-tool.pl          # Main application script
├── README.md                     # This file
├── LICENSE                       # GPL-3.0 license
└── icons/                        # Optional custom icons
    ├── disc.svg                  # Progress display icon
    └── drive.png                 # Fallback drive icon
```

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

### Development Guidelines

1. **Code Style**: Follow Perl best practices
2. **Comments**: Add meaningful comments for complex logic
3. **Testing**: Test on multiple Linux distributions
4. **Documentation**: Update README for new features
5. **Subroutines**: Include 3-sentence documentation (Why/What/How)

### Reporting Bugs

When reporting bugs, please include:
- Linux distribution and version
- Perl version (`perl --version`)
- GTK version
- Steps to reproduce
- Error messages from console
- Debug log if available

## Roadmap

Planned features for future releases:
- [ ] Cloud storage integration (S3, Google Drive, Dropbox)
- [ ] Scheduled backups with cron integration
- [ ] Email notifications for backup completion/failure
- [ ] Backup rotation policies (keep last N backups)
- [ ] Network backup support (SSH/SFTP destinations)
- [ ] Backup comparison and diff viewer
- [ ] Multi-threaded compression for faster backups
- [ ] GUI improvements (dark mode, custom themes)
- [ ] Backup verification through checksums
- [ ] Smart backup suggestions based on usage patterns

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Author

**Zeljko Vukman** (CroJack)
- GitHub: [@crojack](https://github.com/crojack)
- Project: [https://github.com/crojack/wolfmans-backup-tool](https://github.com/crojack/wolfmans-backup-tool)

## Acknowledgments

- Perl community
- GTK community
- rsync and tar community

## Support

If you find this tool useful, please consider:
- Starring the repository
- Reporting bugs and issues
- Suggesting new features
- Contributing code improvements
- Improving documentation

## Changelog

### Version 1.0 (Current)
- Initial release
- System, home, and custom backup types
- Incremental backup support (cumulative and differential)
- Compression and encryption options
- GTK3 graphical interface
- Real-time progress monitoring
- Restore functionality with incremental support
- Metadata-based backup tracking

---
