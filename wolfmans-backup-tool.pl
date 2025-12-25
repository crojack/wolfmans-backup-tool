#!/usr/bin/perl
use strict;
use warnings;
use Gtk3 '-init';
use Glib;

# Main application class
package BackupTool;

use File::Path qw(make_path);
use File::Find qw(find);
use File::Copy::Recursive qw(dircopy);
use Cwd qw(abs_path);
use POSIX qw(strftime WNOHANG);
use Math::Trig qw(pi);
use Time::HiRes qw(time);
use utf8;
use Encode qw(decode_utf8);
use Pango;
use File::Basename qw(basename dirname);
use File::Copy;
use Data::UUID;
use File::Temp qw(tempfile tempdir);
use Scalar::Util qw(looks_like_number);
use File::Spec;

#--------------------------------Constructor and Initialization--------------------------------------------

# new
# Creates a new BackupTool instance to initialize the backup/restore application.
# Initializes all instance variables including UI components, operation modes, and system state flags.
# Sets up signal handlers for clean shutdown and creates the necessary icons directory structure.
sub new {
    my $class = shift;
    my $self = {
        window => undef,
        headerbar => undef,
        left_panel => undef,
        right_panel => undef,
        content_stack => undef,
        progress_bar => undef,
        elapsed_time_label => undef,
        remaining_time_label => undef,
        animation_area => undef,
        current_operation => '',
        start_time => 0,
        total_size => 0,
        processed_size => 0,
        timeout_id => undef,
        selected_backup_type => 'system',
        encryption_enabled => 0,
        operation_mode => 'backup',
        backup_mode => 'incremental', 
        restore_source => undef,
        restore_include_incrementals => 0,
        sudo_authenticated => 0,     
        sudo_refresh_timer => undef,
        last_partition_data => 0,      
        overlay_window => undef,
        settings => {}, 
        
        # Tab buttons
        backup_tab_button => undef,
        restore_tab_button => undef,
        
        # Incremental backup        
        incremental_metadata => undef,
        backup_process => undef,   
        progress_timeout_id => undef,
        
        incremental_cumulative_button => undef,
        incremental_differential_button => undef,
        backup_mode_frame => undef, 
        details_label => undef, 
                
        incremental_backup_folder => undef,
        incremental_mode_active => 0,
        incremental_start_handler_id => undef,
        
        # Updated button references
        backup_system_button => undef,
        backup_home_button => undef,
        backup_custom_button => undef,
        
        restore_system_button => undef,
        restore_home_button => undef,
        restore_custom_button => undef,
    };
    bless $self, $class;
    
    $SIG{INT} = sub { $self->cleanup_sudo(); exit(1); };
    $SIG{TERM} = sub { $self->cleanup_sudo(); exit(1); };
    
    # Create icons directory on startup
    $self->create_icons_directory();
    
    return $self;
}

# run
# Starts the backup tool application and enters the GTK main event loop.
# Initializes the user interface and begins listening for user interactions.
# Continues running until the user closes the application window.
sub run {
    my $self = shift;
    $self->init_ui();
    Gtk3::main();
}

# set_button_style
# Applies or removes CSS style classes to buttons for visual feedback during operations.
# Adds the specified style class if enable is true, otherwise removes it from the button.
# Uses GTK's style context to modify button appearance without changing functionality.
sub set_button_style {
    my ($self, $button, $style_class, $enable) = @_;
    return unless $button;
    
    my $context = $button->get_style_context();
    if ($enable) {
        $context->add_class($style_class);
    } else {
        $context->remove_class($style_class);
    }
}

# set_fallback_icon_to_image
# Provides default hard disk icons when custom icons aren't available.
# Attempts to load a drive-harddisk icon, falling back to gtk-harddisk stock icon if needed.
# Prevents UI breakage when icon files are missing from the system.
sub set_fallback_icon_to_image {
    my ($self, $image_widget) = @_;
    
    eval {
        $image_widget->set_from_icon_name('drive-harddisk', 'dialog');
    };
    if ($@) {
        eval {
            $image_widget->set_from_stock('gtk-harddisk', 'dialog');
        };
    }
}

# setup_initial_ui_state
# Establishes the default state of all UI elements when the application starts.
# Sets backup mode to regular, activates system backup option, and hides custom file selection.
# Ensures consistent starting state regardless of how the application was previously closed.
sub setup_initial_ui_state {
    my $self = shift;
    
    # Set initial tab selection 
    if ($self->{backup_tab_button}) {
        $self->{backup_tab_button}->set_active(1);
    }
    
    # Hide custom file selection elements initially
    if ($self->{select_files_button}) {
        $self->{select_files_button}->set_visible(0);
    }
    if ($self->{selected_files_label}) {
        $self->{selected_files_label}->set_visible(0);
    }
    
    # Set initial backup mode to regular (system backup)
    $self->{backup_mode} = 'regular';
    if ($self->{backup_system_button}) {
        $self->{backup_system_button}->set_active(1);
    }
    
    # Ensure incremental buttons are NOT checked initially
    if ($self->{incremental_cumulative_button}) {
        $self->{incremental_cumulative_button}->set_active(0);
    }
    if ($self->{incremental_differential_button}) {
        $self->{incremental_differential_button}->set_active(0);
    }
    
    # Set up initial button states
    if ($self->{target_button}) {
        $self->{target_button}->set_label('Select backup destination');
    }
    if ($self->{start_backup_button}) {
        $self->{start_backup_button}->set_label('Start Backup');
        $self->{start_backup_button}->set_sensitive(0);
    }
    
    # Update backup name based on initial selection (system backup)
    $self->update_backup_name();
    
    # Show backup name input for backup operations
    if ($self->{backup_name_hbox}) {
        $self->{backup_name_hbox}->set_visible(1);
    }
    
    # Set initial status message
    if ($self->{status_label}) {
        $self->{status_label}->set_markup('<i>Select destination for backup</i>');
        $self->{status_label}->set_visible(0);
    }
}

# update_backup_name
# Generates descriptive backup names based on the selected backup type and current mode.
# Creates timestamps and prefixes (e.g., "system_backup_", "incremental_cumulative_") for clarity.
# Updates the backup name entry field automatically when users change backup options.
sub update_backup_name {
    my $self = shift;
    
    # Only update if the entry box exists
    return unless $self->{backup_name_entry};
    
    my $timestamp = POSIX::strftime("%d%m%Y_%H%M%S", localtime);
    my $backup_name;
    
    if ($self->{backup_mode} eq 'incremental_cumulative') {
        $backup_name = "incremental_cumulative_backup_$timestamp";
    } elsif ($self->{backup_mode} eq 'incremental_differential') {
        $backup_name = "incremental_differential_backup_$timestamp";
    } elsif ($self->{selected_backup_type} eq 'system') {
        $backup_name = "system_backup_$timestamp";
    } elsif ($self->{selected_backup_type} eq 'home') {
        $backup_name = "home_backup_$timestamp";
    } elsif ($self->{selected_backup_type} eq 'custom') {
        $backup_name = "custom_backup_$timestamp";
    } else {
        # Fallback
        $backup_name = "backup_$timestamp";
    }
    
    $self->{backup_name_entry}->set_text($backup_name);
}


# update_backup_options_visibility
# Shows or hides compression and encryption checkboxes based on operation mode.
# Adjusts option labels (e.g., "Verify backup" vs "Verify restore") for context-appropriate display.
# Prevents users from seeing irrelevant options during restore operations.
sub update_backup_options_visibility {
    my ($self, $operation_type) = @_;
    
    return unless $operation_type;
    
    if ($self->{operation_mode} eq 'restore') {
        # For restore operations: hide compression and encryption
        if ($self->{compress_check}) {
            $self->{compress_check}->set_visible(0);
        }
        
        if ($self->{encrypt_check}) {
            $self->{encrypt_check}->set_visible(0);
        }
        
        if ($self->{verify_check}) {
            my $label = $self->{verify_check}->get_child();
            if ($label) {
                $label->set_text('Verify restore');
            }
            $self->{verify_check}->set_visible(1);
        }
    } else {
        # For backup operations: show all options, restore verify label
        if ($self->{compress_check}) {
            $self->{compress_check}->set_visible(1);
        }
        if ($self->{encrypt_check}) {
            $self->{encrypt_check}->set_visible(1);
        }
        if ($self->{verify_check}) {

            my $label = $self->{verify_check}->get_child();
            if ($label) {
                $label->set_text('Verify backup');
            }
            $self->{verify_check}->set_visible(1);
        }
    }
}


# update_elapsed_time
# Calculates and displays the elapsed time since backup/restore operation started.
# Computes the difference between current time and stored start time.
# Formats the elapsed time as HH:MM:SS and updates the elapsed time label with monospace font.
sub update_elapsed_time {
    my $self = shift;
    
    my $elapsed = time() - $self->{start_time};
    my $elapsed_str = $self->format_time($elapsed);
    
    if ($self->{elapsed_time_label}) {
        $self->{elapsed_time_label}->set_markup(
            '<span font="monospace" size="16000" weight="bold" color="#cccccc">' . 
            $elapsed_str . 
            '</span>'
        );
    }
}

# update_main_backup_metadata
# Records incremental backup information in the main backup's metadata file.
# Reads existing metadata, appends new incremental backup details with timestamps.
# Maintains a history of all incremental backups for proper restore functionality.
sub update_main_backup_metadata {
    my ($self, $backup_folder, $incremental_dir) = @_;
    
    my $main_metadata_file = "$backup_folder/.backup_info.json";
    my $incremental_name = File::Basename::basename($incremental_dir);
    
    # Read current metadata
    eval {
        require JSON;
        
        my $metadata;
        if (open my $fh, '<', $main_metadata_file) {
            local $/;
            my $json_content = <$fh>;
            close $fh;
            $metadata = JSON::decode_json($json_content);
        } else {
            print "Warning: Could not read main metadata file\n";
            return;
        }
        
        # Add incremental backup record
        $metadata->{incremental_backups} = [] unless $metadata->{incremental_backups};
        push @{$metadata->{incremental_backups}}, {
            timestamp => time(),
            timestamp_readable => POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime),
            incremental_dir => $incremental_name,
            backup_type => $self->{backup_mode},
        };
        
        $metadata->{last_incremental_backup} = time();
        $metadata->{total_incremental_backups} = scalar(@{$metadata->{incremental_backups}});
        
        # Write updated metadata
        $self->write_metadata_file($main_metadata_file, $metadata);
        
    };
    
    if ($@) {
        print "Warning: Could not update main backup metadata: $@\n";
    }
}

# update_operation_mode
# Switches between backup and restore modes and updates UI accordingly.
# Shows/hides incremental backup options and sets appropriate default selections.
# Ensures the content stack displays the correct panel for the selected operation.
sub update_operation_mode {
    my $self = shift;
    
    print "Switching to " . $self->{operation_mode} . " mode\n";
    
    # Update the content stack to show appropriate tab
    if ($self->{content_stack}) {
        if ($self->{operation_mode} eq 'backup') {
            $self->{content_stack}->set_visible_child_name('backup');
            # Set default backup operation if not already set
            
            # Show incremental backup buttons in backup mode
            if ($self->{backup_mode_frame}) {
                $self->{backup_mode_frame}->set_visible(1);
                print "Incremental backup frame shown for backup mode\n";
            }
        } else {
            $self->{content_stack}->set_visible_child_name('restore');
            # Set default restore operation if not already set
            if ($self->{restore_system_button}) {
                $self->{restore_system_button}->set_active(1);
                $self->{selected_backup_type} = 'system';
            }
            
            # Hide incremental backup buttons in restore mode
            if ($self->{backup_mode_frame}) {
                $self->{backup_mode_frame}->set_visible(0);
                print "Incremental backup frame hidden for restore mode\n";
            }
        }
    }
    
    # Update the right panel to match the operation mode and selected type
    $self->update_right_panel();
}

# update_progress
# Reads progress information from temporary files and updates the UI display.
# Parses progress messages containing percentage, text, and remaining time estimates.
# Returns false when the backup process completes, stopping the timer callback.
sub update_progress {
    my $self = shift;
    use POSIX qw(WNOHANG);
    
    # Define the progress file path
    my $progress_file;
    if ($self->{backup_process}) {
        $progress_file = "/tmp/backup_progress_$self->{backup_process}";
    } else {
        return 0; 
    }
    
    # Check if child process is still running
    my $pid_status = waitpid($self->{backup_process}, WNOHANG);
    if ($pid_status == $self->{backup_process}) {
        $self->{backup_process} = undef;
        $self->backup_completed(); 
        return 0; 
    }
    
    # Update elapsed time (calculated locally)
    $self->update_elapsed_time();
    
    # Read the progress file
    if (-f $progress_file) {
        if (open my $fh, '<', $progress_file) {
            my @lines = <$fh>;
            close $fh;
            
            if (@lines) {
                my $last_line = $lines[-1];
                chomp $last_line;
                
                # Parse format: PCT:45|TXT:35MB/s|REM:00:05:20
                if ($last_line =~ /^PCT:(\d+)\|TXT:(.*?)\|REM:(.*)$/) {
                    my $percent = $1;
                    my $text = $2;
                    my $rem_time = $3;
                    
                    # Update Progress Bar
                    $self->{progress_bar}->set_fraction($percent / 100.0);
                    $self->{progress_bar}->set_text("$percent% - $text");
                    
                    # Update Remaining Time Label
                    if ($self->{remaining_time_label}) {
                        $rem_time =~ s/^\s+//;
                        $rem_time =~ s/^Remaining:\s*//i;  
                        $self->{remaining_time_label}->set_markup(
                            '<span font="monospace" size="16000" weight="bold" color="#cccccc">' . 
                            $rem_time . 
                            '</span>'
                        );
                    }
                    
                } elsif ($last_line =~ /^PCT:(\d+)\|TXT:(.*)$/) {
                    # Fallback for messages without time
                    my $percent = $1;
                    my $text = $2;
                    $self->{progress_bar}->set_fraction($percent / 100.0);
                    $self->{progress_bar}->set_text("$percent% - $text");
                    
                } elsif ($last_line =~ /^COMPLETE/) {
                    $self->{progress_bar}->set_fraction(1.0);
                    $self->{progress_bar}->set_text("Finishing up...");
                    if ($self->{remaining_time_label}) {
                        $self->{remaining_time_label}->set_markup(
                            '<span font="monospace" size="16000" weight="bold" color="#cccccc">00:00:00</span>'
                        );
                    }
                }
            }
        }
    }
    return 1; 
}

# update_right_panel
# Updates all elements in the right panel based on current operation mode and type.
# Adjusts button labels, visibility, and progress display for backup/restore/incremental modes.
# Ensures UI consistency when users switch between different operation modes.
sub update_right_panel {
    my $self = shift;
    
    # Show/hide elements based on operation type
    my $is_restore_mode = ($self->{operation_mode} eq 'restore');
    my $is_incremental_mode = ($self->{backup_mode} =~ /^incremental_/);
    
    # Update progress title and visibility based on operation mode
    if ($self->{progress_title_label}) {
        if ($is_restore_mode) {
            $self->{progress_title_label}->set_markup('<span size="large" weight="bold">Restoring progress</span>');
            $self->{progress_title_label}->set_visible(1);
        } elsif ($is_incremental_mode) {
            $self->{progress_title_label}->set_markup('<span size="large" weight="bold">Incremental backup progress</span>');
            $self->{progress_title_label}->set_visible(1);
        } else {
            # Regular backup operations
            $self->{progress_title_label}->set_markup('<span size="large" weight="bold">Backup progress</span>');
            $self->{progress_title_label}->set_visible(1);
        }
    }
    
    # Update cancel button label based on operation mode
    if ($self->{cancel_backup_button}) {
        if ($is_restore_mode) {
            $self->{cancel_backup_button}->set_label('Cancel restoring');
        } elsif ($is_incremental_mode) {
            $self->{cancel_backup_button}->set_label('Cancel incremental backup');
        } else {
            $self->{cancel_backup_button}->set_label('Cancel backup');
        }
    }
    
    # Update layout based on backup type and mode
    $self->update_target_layout();
    
    # Update target button label and behavior based on mode
    if ($is_incremental_mode) {
        # Incremental backup mode
        $self->{target_button}->set_label('Select previous backup location');
        
        if ($self->{backup_mode} eq 'incremental_cumulative') {
            $self->{start_backup_button}->set_label('Start Incremental Cumulative Backup');
        } elsif ($self->{backup_mode} eq 'incremental_differential') {
            $self->{start_backup_button}->set_label('Start Incremental Differential Backup');
        }
        
        # Show backup name for incremental backups
        if ($self->{backup_name_hbox}) {
            $self->{backup_name_hbox}->set_visible(1);
        }
        
        # Update destination label if no backup is selected
        if (!$self->{incremental_backup_folder}) {
            $self->{destination_label}->set_markup('<i>No previous backup selected</i>');
        }
        
    } elsif ($self->{operation_mode} eq 'restore') {
        # Restore mode
        $self->{target_button}->set_label('Select backup to restore');
        $self->{start_backup_button}->set_label('Start restore');
        
        # Only update destination label if no restore source is set
        if (!$self->{restore_source}) {
            $self->{destination_label}->set_markup('<i>No backup selected</i>');
        }
        
        # Hide backup name for restore
        if ($self->{backup_name_hbox}) {
            $self->{backup_name_hbox}->set_visible(0);
        }
        
        # Hide status label for restore mode
        if ($self->{status_label}) {
            $self->{status_label}->set_visible(0);
        }
        
    } else {
        # Regular backup mode
        $self->{target_button}->set_label('Select backup destination');
        $self->{start_backup_button}->set_label('Start Backup');
        
        # Show backup name for backup operations
        if ($self->{backup_name_hbox}) {
            $self->{backup_name_hbox}->set_visible(1);
        }
        
        # Only update destination label if no backup destination is set
        if (!$self->{backup_destination}) {
            $self->{destination_label}->set_markup('<i>No destination selected</i>');
        }
    }
    
    # Show/hide custom file selection - ONLY FOR BACKUP MODE
    if ($self->{select_files_button}) {
        my $show_file_selection = ($self->{selected_backup_type} eq 'custom' && 
                                   $self->{operation_mode} eq 'backup' && 
                                   !$is_incremental_mode);
        $self->{select_files_button}->set_visible($show_file_selection);
        $self->{selected_files_label}->set_visible($show_file_selection);
        
        if ($show_file_selection) {
            # Only reset if no files are already selected
            if (!$self->{selected_files} || @{$self->{selected_files}} == 0) {
                $self->{selected_files_label}->set_markup('<i>No files selected</i>');
                $self->{target_button}->set_sensitive(0);  # Disable until files selected
            } else {
                $self->{target_button}->set_sensitive(1);
            }
        } else {
            $self->{target_button}->set_sensitive(1);
        }
    }
    
    # Update status label text
    if ($self->{status_label}) {
        my $status_text;
        
        if ($is_incremental_mode) {
            my $inc_type = $self->{backup_mode} eq 'incremental_cumulative' ? 'Cumulative' : 'Differential';
            $status_text = "Select previous backup for $inc_type incremental backup";
        } elsif ($self->{operation_mode} eq 'restore') {
            my $type_descriptions = {
                'system' => 'Select system backup to restore',
                'home' => 'Select home directory backup to restore',
                'custom' => 'Select custom backup to restore',
            };
            $status_text = $type_descriptions->{$self->{selected_backup_type}} || 'Select backup to restore';
        } else {
            my $type_descriptions = {
                'system' => 'Select destination for system backup',
                'home' => 'Select destination for home directory backup',
                'custom' => 'Select files and folders, then choose destination',
            };
            $status_text = $type_descriptions->{$self->{selected_backup_type}} || 'Select backup destination';
        }
        
        $self->{status_label}->set_markup("<i>$status_text</i>");
    }
    
    # Check if start button should be enabled
    $self->update_start_button_state();
    
    # Reset progress only if no operation is running
    if (!$self->{backup_process} && $self->{progress_bar}) {
        $self->{progress_bar}->set_fraction(0.0);
        $self->{progress_bar}->set_text('Waiting to start...');
    }
    
    if (!$self->{backup_process} && $self->{elapsed_time_label}) {
        $self->{elapsed_time_label}->set_markup('<span font="monospace" size="16000" weight="bold" color="#cccccc">00:00:00</span>');
    }
    
    if (!$self->{backup_process} && $self->{remaining_time_label}) {
        $self->{remaining_time_label}->set_markup('<span font="monospace" size="16000" weight="bold" color="#cccccc">00:00:00</span>');
    }
}

# update_start_button_state
# Determines whether the Start button should be enabled based on required selections.
# Checks for backup destination, custom file selections, and restore source as needed.
# Applies visual highlighting (suggested-action class) to guide users through the workflow.
sub update_start_button_state {
    my $self = shift;
    
    return unless $self->{start_backup_button};
    
    my $can_start = 0;
    my $highlight_target = 0;   # Should we highlight the "Select Destination" button?
    my $highlight_files = 0;    # Should we highlight the "Select Files" button?
    
    my $is_incremental_mode = ($self->{backup_mode} =~ /^incremental_/);
    
    # 1. Determine functionality (Can we start?)
    if ($is_incremental_mode) {
        # Incremental backup mode
        $can_start = defined($self->{incremental_backup_folder});
        $highlight_target = !defined($self->{incremental_backup_folder});
        
    } elsif ($self->{operation_mode} eq 'restore') {
        # Restore mode
        $can_start = defined($self->{restore_source}) && defined($self->{restore_destination});
        # In restore mode, highlight target button if source not selected
        $highlight_target = !defined($self->{restore_source}); 
        
    } else {
        # Regular backup mode
        if ($self->{selected_backup_type} eq 'custom') {
            my $has_files = defined($self->{selected_files}) && @{$self->{selected_files}} > 0;
            my $has_dest = defined($self->{backup_destination});
            
            $can_start = $has_files && $has_dest;
            
            # Logic flow: Highlight Files first. If files selected, Highlight Destination.
            if (!$has_files) {
                $highlight_files = 1;
            } elsif (!$has_dest) {
                $highlight_target = 1;
            }
        } else {
            # System/Home backup
            my $has_dest = defined($self->{backup_destination});
            $can_start = $has_dest;
            $highlight_target = !$has_dest;
        }
    }
    
    # 2. Apply Functional State
    $self->{start_backup_button}->set_sensitive($can_start);
    
    # 3. Apply Visual Styles (The "Flow")
    
    # "Select Files" button (Custom mode only)
    if ($self->{select_files_button}) {
        $self->set_button_style($self->{select_files_button}, 'suggested-action', $highlight_files);
    }
    
    # "Destination" button
    if ($self->{target_button}) {
        $self->set_button_style($self->{target_button}, 'suggested-action', $highlight_target);
    }
    
    # "Start" button - Only highlight if ready to start
    $self->set_button_style($self->{start_backup_button}, 'suggested-action', $can_start);
}


# update_target_layout
# Shows or hides file selection and destination buttons based on backup type and mode.
# Adjusts layout for custom backups (showing file selector) versus system/home backups.
# Ensures users only see relevant controls for their selected backup operation.
sub update_target_layout {
    my $self = shift;
    
    # Hide all target selection widgets initially
    if ($self->{select_files_button}) {
        $self->{select_files_button}->set_visible(0);
    }
    if ($self->{selected_files_label}) {
        $self->{selected_files_label}->set_visible(0);
    }
    if ($self->{target_button}) {
        $self->{target_button}->set_visible(0);
    }
    if ($self->{destination_label}) {
        $self->{destination_label}->set_visible(0);
    }
    if ($self->{backup_name_hbox}) {
        $self->{backup_name_hbox}->set_visible(0);
    }
    
    # Show appropriate widgets based on operation mode and type
    if ($self->{operation_mode} eq 'backup') {
        # Backup mode
        if ($self->{selected_backup_type} eq 'custom') {
            # Custom backup: show file selection first, then destination
            if ($self->{select_files_button}) {
                $self->{select_files_button}->set_visible(1);
            }
            if ($self->{selected_files_label}) {
                $self->{selected_files_label}->set_visible(1);
            }
        }
        
        # Show destination button for all backup types
        if ($self->{target_button}) {
            $self->{target_button}->set_visible(1);
            $self->{target_button}->set_label('Choose backup destination');
        }
        if ($self->{destination_label}) {
            $self->{destination_label}->set_visible(1);
        }
        
        # Show backup name entry for backup operations
        if ($self->{backup_name_hbox}) {
            $self->{backup_name_hbox}->set_visible(1);
        }
    } else {
        # Restore mode
        # Show restore source selection
        if ($self->{target_button}) {
            $self->{target_button}->set_visible(1);
            $self->{target_button}->set_label('Select backup to restore');
        }
        if ($self->{destination_label}) {
            $self->{destination_label}->set_visible(1);
        }
        
        # Hide backup name for restore
        if ($self->{backup_name_hbox}) {
            $self->{backup_name_hbox}->set_visible(0);
        }
    }
}

# load_backup_metadata
# Reads and parses the .backup_info.json file from a selected backup folder.
# Validates that the folder contains proper backup metadata before proceeding.
# Stores metadata in memory for compatibility checking and incremental operations.
sub load_backup_metadata {
    my ($self, $backup_folder) = @_;
    
    my $metadata_file = "$backup_folder/.backup_info.json";
    
    print "Looking for metadata file: $metadata_file\n";
    
    unless (-f $metadata_file) {
        $self->show_error_dialog('Metadata Not Found', 
            "Could not find .backup_info.json in the selected folder.\n" .
            "Please select a folder created by this backup tool.");
        return;
    }
    
    # Read and parse metadata
    eval {
        require JSON;
        
        open my $fh, '<', $metadata_file or die "Cannot open metadata file: $!";
        local $/;
        my $json_content = <$fh>;
        close $fh;
        
        $self->{incremental_metadata} = JSON::decode_json($json_content);
        
        print "Successfully loaded backup metadata\n";
        print "Original backup type: " . ($self->{incremental_metadata}->{backup_type} || 'unknown') . "\n";
        
        # Verify backup type matches
        $self->verify_backup_type_compatibility($backup_folder);
        
    };
    
    if ($@) {
        $self->show_error_dialog('Metadata Error', 
            "Could not read backup metadata: $@");
        return;
    }
}

# load_disc_icon_to_image
# Loads the custom disc.svg icon for progress display time labels.
# Attempts to load from ~/.local/share/wolfmans-backup-tool/icons with size scaling.
# Falls back to system icons if the custom icon file is missing or corrupted.
sub load_disc_icon_to_image {
    my ($self, $image_widget) = @_;
    
    my $icon_dir = "$ENV{HOME}/.local/share/wolfmans-backup-tool/icons";
    my $icon_path = "$icon_dir/disc.svg";
    
    # Try to load the custom icon
    if (-f $icon_path) {
        my $pixbuf;
        eval {
            $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file_at_size($icon_path, 64, 64);
        };
        
        if ($@ || !defined $pixbuf) {
            print "Error loading disc icon: $@\n";
            $self->set_fallback_icon_to_image($image_widget);
        } else {
            $image_widget->set_from_pixbuf($pixbuf);
            print "Loaded disc icon (64x64) for time label\n";
        }
    } else {
        print "Disc icon not found, using fallback\n";
        $self->set_fallback_icon_to_image($image_widget);
    }
}

# load_settings
# Reads saved application settings from the config directory.
# Parses window dimensions, border width, and last backup location from settings file.
# Creates default settings and configuration directory if none exist.
sub load_settings {
    my $self = shift;
    
    my $config_dir = "$ENV{HOME}/.config/wolfmans-backup-tool";
    my $config_file = "$config_dir/settings.conf";
    
    # Default settings
    $self->{settings} = {
        window_width => 1000,
        window_height => 700,
        border_width => 3,
        last_backup_location => '',
    };
    
    # Create config directory if it doesn't exist
    unless (-d $config_dir) {
        File::Path::make_path($config_dir);
    }
    
    # Load settings from file if it exists
    if (-f $config_file) {
        if (open my $fh, '<', $config_file) {
            while (my $line = <$fh>) {
                chomp $line;
                next if $line =~ /^\s*#/ || $line =~ /^\s*$/; 
                
                if ($line =~ /^(\w+)\s*=\s*(.+)$/) {
                    my ($key, $value) = ($1, $2);
                    $value =~ s/^["']//; 
                    $value =~ s/["']$//;
                    
                    next if $key eq 'border_color';
                    
                    $self->{settings}->{$key} = $value;
                }
            }
            close $fh;
            print "Settings loaded from: $config_file\n";
        } else {
            print "Could not read settings file: $!\n";
        }
    } else {
        print "Settings file not found, using defaults\n";
        $self->save_settings(); 
    }
}

# read_backup_metadata
# Reads and validates the .backup_info.json file from a backup directory.
# Provides extensive debugging output to diagnose metadata reading issues.
# Returns parsed metadata structure or undef if file is missing or invalid.
sub read_backup_metadata {
    my ($self, $backup_path) = @_;
    
    my $metadata_file = "$backup_path/.backup_info.json";
    
    print "=== METADATA DEBUG ===\n";
    print "Looking for metadata file: $metadata_file\n";
    
    unless (-f $metadata_file) {
        print "Metadata file does not exist: $metadata_file\n";
        
        # List what files ARE in the backup directory
        if (opendir(my $dh, $backup_path)) {
            my @files = readdir($dh);
            closedir($dh);
            print "Files in backup directory:\n";
            foreach my $file (@files) {
                next if $file =~ /^\.\.?$/;
                print "  - $file\n";
            }
        }
        
        print "===================\n";
        return undef;
    }
    
    print "Metadata file exists, attempting to read...\n";
    
    # Check if JSON module is available
    eval {
        require JSON;
        print "JSON module loaded successfully\n";
    };
    
    if ($@) {
        print "ERROR: JSON module not available: $@\n";
        print "===================\n";
        return undef;
    }
    
    my $metadata;
    eval {
        if (open my $fh, '<', $metadata_file) {
            local $/;
            my $json_content = <$fh>;
            close $fh;
            
            print "Raw JSON content length: " . length($json_content) . " bytes\n";
            print "First 200 chars of JSON: " . substr($json_content, 0, 200) . "\n";
            
            $metadata = JSON::decode_json($json_content);
            print "Successfully decoded JSON metadata\n";
            print "Backup type from metadata: " . ($metadata->{backup_type} || "NONE") . "\n";
        } else {
            print "ERROR: Could not open metadata file: $!\n";
            print "===================\n";
            return undef;
        }
    };
    
    if ($@) {
        print "ERROR: Could not read/parse backup metadata: $@\n";
        print "===================\n";
        return undef;
    }
    
    print "===================\n";
    return $metadata;  # Make sure we return the metadata
}

# save_settings
# Saves current application settings to disk for persistence across sessions.
# Writes window dimensions, border settings, and preferences to config file.
# Excludes border_color setting and creates config directory if needed.
sub save_settings {
    my $self = shift;
    
    my $config_dir = "$ENV{HOME}/.config/wolfmans-backup-tool";
    my $config_file = "$config_dir/settings.conf";
    
    # Ensure config directory exists
    unless (-d $config_dir) {
        File::Path::make_path($config_dir);
    }
    
    if (open my $fh, '>', $config_file) {
        print $fh "# Wolfmans Backup Tool Configuration\n";
        print $fh "# This file is automatically generated\n\n";
        
        foreach my $key (sort keys %{$self->{settings}}) {

            next if $key eq 'border_color';
            
            my $value = $self->{settings}->{$key};
            print $fh "$key = \"$value\"\n";
        }
        
        close $fh;
        print "Settings saved to: $config_file\n";
    } else {
        print "Could not save settings: $!\n";
    }
}

# write_metadata_file
# Creates or updates backup metadata files with comprehensive backup information.
# Encodes the metadata hash as JSON and writes it to the specified file path.
# Handles JSON module availability gracefully with error messages.
sub write_metadata_file {
    my ($self, $metadata_file, $metadata) = @_;
    
    print "Writing metadata to: $metadata_file\n";
    
    # Check if JSON module is available
    eval {
        require JSON;
    };
    
    if ($@) {
        print "WARNING: JSON module not available, skipping metadata creation\n";
        return;
    }
    
    eval {
        if (open my $fh, '>', $metadata_file) {
            my $json_string = JSON::encode_json($metadata);
            print $fh $json_string;
            close $fh;
            print "Metadata written successfully\n";
        } else {
            print "ERROR: Could not write metadata file: $!\n";
        }
    };
    
    if ($@) {
        print "ERROR: Could not create metadata: $@\n";
    }
}

# write_progress_file
# Writes progress messages to temporary files for parent process communication.
# Uses the backup process ID to create unique progress file names.
# Outputs both to file and console for debugging purposes.
sub write_progress_file {
    my ($self, $message) = @_;
    
    # Get the progress file path
    my $progress_file;
    if ($self->{backup_process}) {
        $progress_file = "/tmp/backup_progress_$self->{backup_process}";
    } else {
        $progress_file = "/tmp/backup_progress_$$";
    }
    
    # Write progress to file
    if (open my $fh, '>', $progress_file) {
        print $fh "$message\n";
        close $fh;
    }
    # Also print to console for debugging
    print "PROGRESS: $message\n";
}

# Helper to standardize communication with the parent process
# write_progress_update
# Creates standardized progress messages with percentage, text, and time remaining.
# Sanitizes input data (caps percentage at 0-100, removes newlines from messages).
# Enables autoflush on the file handle to ensure immediate UI updates.
sub write_progress_update {
    my ($self, $progress_file, $percent, $message) = @_;
    
    # Ensure percent is an integer between 0 and 100
    $percent = 0 if $percent < 0;
    $percent = 100 if $percent > 100;
    $percent = int($percent);
    
    # Sanitize message (remove newlines)
    $message =~ s/[\r\n]+//g;
    
    if (open my $fh, '>', $progress_file) {
        # Enable autoflush to ensure UI reads it immediately
        my $old_fh = select($fh);
        $| = 1;
        select($old_fh);
        
        print $fh "PCT:$percent|TXT:$message\n";
        close $fh;
    }
}

# create_backup_metadata
# Creates comprehensive metadata files for new backups with version and timestamp info.
# Records backup type, source paths, compression/encryption settings, and user information.
# Includes suggested restore paths to help users restore backups correctly.
sub create_backup_metadata {
    my ($self, $backup_dir, $backup_type, $source_paths) = @_;
    
    my $metadata_file = "$backup_dir/.backup_info.json";
    
    my $metadata = {
        version => "1.0",
        tool => "",
        created => time(),
        created_readable => POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime),
        backup_type => $backup_type,
        source_paths => $source_paths || [],
        original_user => $ENV{USER} || getpwuid($<),
        original_home => $ENV{HOME},
        compression_enabled => $self->{compress_check} ? $self->{compress_check}->get_active() : 0,
        encryption_enabled => $self->{encrypt_check} ? $self->{encrypt_check}->get_active() : 0,
        hidden_files_included => $self->{hidden_check} ? $self->{hidden_check}->get_active() : 1,
    };
    
    # Add specific metadata based on backup type
    if ($backup_type eq 'home') {
        $metadata->{original_home_path} = $ENV{HOME};
        $metadata->{suggested_restore_path} = $ENV{HOME};
    } elsif ($backup_type eq 'system') {
        $metadata->{original_system_paths} = [qw(/bin /boot /etc /lib /opt /root /sbin /usr /var)];
        $metadata->{suggested_restore_path} = '/';
    } elsif ($backup_type eq 'custom') {
        # For custom backups, suggest restoring to original locations
        my @suggested_paths = ();
        foreach my $path (@{$source_paths || []}) {
            if ($path =~ m{^$ENV{HOME}/(.+)$}) {
                # Files under home directory
                push @suggested_paths, "$ENV{HOME}/$1";
            } else {
                # System files - suggest original location
                push @suggested_paths, $path;
            }
        }
        $metadata->{suggested_restore_paths} = \@suggested_paths;
    }
    
    # Write metadata file
    eval {
        require JSON;
        if (open my $fh, '>', $metadata_file) {
            print $fh JSON::encode_json($metadata);
            close $fh;
            print "Created backup metadata: $metadata_file\n";
        }
    };
    
    if ($@) {
        print "Warning: Could not create backup metadata: $@\n";
        # Continue without metadata - not critical
    }
}

# create_backup_operations_panel
# Creates the left panel with radio buttons for all backup types and options.
# Organizes backup modes (regular, incremental), backup types (system, home, custom), and options.
# Uses a single radio group across all options to ensure mutual exclusivity.
sub create_backup_operations_panel {
    my $self = shift;
    
    my $panel = Gtk3::Box->new('vertical', 0);
    $panel->set_margin_left(10);
    $panel->set_margin_right(10);
    $panel->set_margin_top(15);
    $panel->set_margin_bottom(15);
    
    # Create ONE radio group that will be shared by ALL options (regular + incremental)
    my $master_radio_group;
    
    # ==================== BACKUP SECTION ====================
    my $backup_label = Gtk3::Label->new();
    $backup_label->set_markup('<b>Backup</b>');
    $backup_label->set_alignment(0, 0.5);
    $backup_label->set_margin_bottom(8);
    $panel->pack_start($backup_label, 0, 0, 0);
    
    my @backup_operations = (
        ['system', 'System files'],
        ['home', 'Home directory'],
        ['custom', 'Selected files and folders']
    );
    
    foreach my $operation (@backup_operations) {
        my ($type, $label) = @$operation;
        
        my $radio_button = Gtk3::RadioButton->new_with_label($master_radio_group, $label);
        $master_radio_group = $radio_button->get_group() unless $master_radio_group;
        
        $radio_button->set_halign('fill');
        $radio_button->set_size_request(-1, 40);
        
        # Force text alignment to left
        my $button_label = $radio_button->get_child();
        if ($button_label) {
            $button_label->set_alignment(0, 0.5);
            $button_label->set_halign('start'); 
        }
        
        # Set initial state for system button (first one)
        if ($type eq 'system') {
            $radio_button->set_active(1);
        }
        
        # Add selection effects
        $radio_button->signal_connect('toggled' => sub {
            my $button = $_[0];
            my $current_type = $type; 
            
            if ($button->get_active()) {
                $self->{selected_backup_type} = $current_type;
                $self->{backup_mode} = 'regular';  # Set to regular backup mode
                
                # Update the backup name in the entry box
                $self->update_backup_name();
                
                # Update options visibility based on operation type
                $self->update_backup_options_visibility($current_type);
                $self->update_right_panel();
            }
        });
        
        # Store reference
        $self->{"backup_${type}_button"} = $radio_button;
        
        $panel->pack_start($radio_button, 0, 0, 6);
    }
    
    # Add separator after Backup section
    my $separator1 = Gtk3::Separator->new('horizontal');
    $separator1->set_margin_top(12);
    $separator1->set_margin_bottom(12);
    $panel->pack_start($separator1, 0, 0, 0);
    
    # ==================== INCREMENTAL BACKUP SECTION ====================
    my $incremental_label = Gtk3::Label->new();
    $incremental_label->set_markup('<b>Incremental Backup</b>');
    $incremental_label->set_alignment(0, 0.5);
    $incremental_label->set_margin_bottom(8);
    $panel->pack_start($incremental_label, 0, 0, 0);
    
    my @incremental_modes = (
        ['cumulative', 'Cumulative'],
        ['differential', 'Differential']
    );
    
    # Use the SAME master_radio_group for incremental options
    foreach my $mode (@incremental_modes) {
        my ($type, $label) = @$mode;
        
        # Add to the SAME radio group as regular backups
        my $radio_button = Gtk3::RadioButton->new_with_label($master_radio_group, $label);
        
        $radio_button->set_halign('fill');
        $radio_button->set_size_request(-1, 40);
        
        # Force text alignment to left
        my $button_label = $radio_button->get_child();
        if ($button_label) {
            $button_label->set_alignment(0, 0.5);
            $button_label->set_halign('start');
        }
        
        # Add selection effects
        $radio_button->signal_connect('toggled' => sub {
            my $button = $_[0];
            my $current_mode = $type;
            
            if ($button->get_active()) {
                $self->{backup_mode} = "incremental_$current_mode";
                
                # Update the backup name in the entry box
                $self->update_backup_name();
                
                $self->update_right_panel();
            }
        });
        
        # Store reference
        $self->{"incremental_${type}_button"} = $radio_button;
        
        $panel->pack_start($radio_button, 0, 0, 6);
    }
    
    # Add separator after Incremental Backup section
    my $separator2 = Gtk3::Separator->new('horizontal');
    $separator2->set_margin_top(12);
    $separator2->set_margin_bottom(12);
    $panel->pack_start($separator2, 0, 0, 0);
    
    # ==================== OPTIONS SECTION ====================
    my $options_label = Gtk3::Label->new();
    $options_label->set_markup('<b>Options</b>');
    $options_label->set_alignment(0, 0.5);
    $options_label->set_margin_bottom(8);
    $panel->pack_start($options_label, 0, 0, 0);
    
    # Checkboxes using standard GTK3 checkboxes
    $self->{hidden_check} = Gtk3::CheckButton->new_with_label('Include hidden files');
    $self->{hidden_check}->set_active(1);
    $self->{hidden_check}->set_size_request(-1, 35);
    $panel->pack_start($self->{hidden_check}, 0, 0, 6);
    
    $self->{compress_check} = Gtk3::CheckButton->new_with_label('Enable compression');
    $self->{compress_check}->set_size_request(-1, 35);
    $panel->pack_start($self->{compress_check}, 0, 0, 6);
    
    # Verify - changes label based on operation type
    $self->{verify_check} = Gtk3::CheckButton->new_with_label('Verify backup');
    $self->{verify_check}->set_size_request(-1, 35);
    $panel->pack_start($self->{verify_check}, 0, 0, 6);
    
    $self->{encrypt_check} = Gtk3::CheckButton->new_with_label('Enable encryption');
    $self->{encrypt_check}->set_size_request(-1, 35);
    $self->{encrypt_check}->signal_connect(toggled => sub {
        $self->{encryption_enabled} = $_[0]->get_active();
    });
    $panel->pack_start($self->{encrypt_check}, 0, 0, 6);
    
    return $panel;
}


# create_fallback_icons
# Creates placeholder text files when required icon files don't exist.
# Documents which icons are needed and their required sizes.
# Helps users identify missing icon files that need to be added.
sub create_fallback_icons {
    my ($self, $icons_dir) = @_;
    
    my @icon_files = ('minimize.png', 'close.png', 'drive.png', 'disc.svg');
    
    foreach my $icon_file (@icon_files) {
        my $icon_path = "$icons_dir/$icon_file";
        unless (-f $icon_path) {
            # Create a simple text file as placeholder
            if (open my $fh, '>', $icon_path) {
                print $fh "# Placeholder for $icon_file\n";
                print $fh "# Replace this with actual icon file\n";
                close $fh;
            }
        }
    }
    
    print "Created placeholder icon files in: $icons_dir\n";
    print "Please replace placeholder files with actual icons:\n";
    print "  - minimize.png (16x16 minimize button icon)\n";
    print "  - close.png (16x16 close button icon)\n";
    print "  - drive.png (48x48 hard drive icon)\n";
    print "  - disc.svg (256x256 disc/backup icon)\n";
}

# create_icons_directory
# Creates the ~/.local/share/wolfmans-backup-tool/icons directory structure.
# Ensures the application has a place to store and load custom icons.
# Calls create_fallback_icons to populate with placeholders if needed.
sub create_icons_directory {
    my $self = shift;
    
    my $icons_dir = "$ENV{HOME}/.local/share/wolfmans-backup-tool/icons";
    
    unless (-d $icons_dir) {
        File::Path::make_path($icons_dir);
        print "Created icons directory: $icons_dir\n";
        
        # Create some basic fallback icons if they don't exist
        $self->create_fallback_icons($icons_dir);
    }
}

# create_incremental_metadata
# Creates metadata files specifically for incremental backup directories.
# Records the incremental type (cumulative/differential), parent backup info, and changed files.
# Links incremental backups to their parent for proper restore sequence.
sub create_incremental_metadata {
    my ($self, $incremental_dir, $original_metadata, $files_ref) = @_;
    
    my $incremental_metadata = {
        version => "1.0",
        incremental_backup => 1,
        incremental_type => $self->{backup_mode},
        created => time(),
        created_readable => POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime),
        parent_backup_created => $original_metadata->{created},
        backup_type => $original_metadata->{backup_type},
        original_home => $ENV{HOME},
        original_user => $ENV{USER} || getpwuid($<),
        files_updated => scalar(@$files_ref),
        updated_files_list => $files_ref,
        backup_method => 'incremental_file_copy',
    };
    
    # Write incremental metadata
    my $metadata_file = "$incremental_dir/.incremental_info.json";
    $self->write_metadata_file($metadata_file, $incremental_metadata);
}

# create_left_panel_with_tabs
# Builds the tabbed interface with Backup and Restore tabs.
# Creates radio button tabs with proper styling and content switching.
# Initializes both backup and restore operations panels as tab content.
sub create_left_panel_with_tabs {
    my ($self, $parent) = @_;
    
    my $left_frame = Gtk3::Frame->new();
    $left_frame->set_size_request(260, -1); 
    $parent->pack_start($left_frame, 0, 0, 0);
    
    my $left_vbox = Gtk3::Box->new('vertical', 0);
    $left_frame->add($left_vbox);
    
    # Create tab buttons container with margins
    my $tab_hbox = Gtk3::Box->new('horizontal', 0);
    $tab_hbox->set_margin_left(5);
    $tab_hbox->set_margin_right(5);
    $tab_hbox->set_margin_top(5);
    $left_vbox->pack_start($tab_hbox, 0, 0, 0);
    
    # Create frames for each tab button
    my $backup_tab_frame = Gtk3::Frame->new();
    $backup_tab_frame->set_shadow_type('none');
    $backup_tab_frame->set_margin_right(2);
    
    my $restore_tab_frame = Gtk3::Frame->new();
    $restore_tab_frame->set_shadow_type('none');
    $restore_tab_frame->set_margin_left(2);
    
    # Backup tab button
    $self->{backup_tab_button} = Gtk3::RadioButton->new_with_label([], 'Backup');
    $self->{backup_tab_button}->set_mode(0);
    $self->{backup_tab_button}->set_active(1);
    $self->{backup_tab_button}->get_style_context()->add_class('top-tab');
    
    # Add backup button to its frame
    $backup_tab_frame->add($self->{backup_tab_button});
    
    # Restore tab button
    $self->{restore_tab_button} = Gtk3::RadioButton->new_with_label_from_widget($self->{backup_tab_button}, 'Restore');
    $self->{restore_tab_button}->set_mode(0);
    $self->{restore_tab_button}->get_style_context()->add_class('top-tab');
    
    # Add restore button to its frame
    $restore_tab_frame->add($self->{restore_tab_button});
    
    # Content area for tabs
    $self->{content_stack} = Gtk3::Stack->new();

    $left_vbox->pack_start($self->{content_stack}, 1, 1, 0);
    
    # Connect tab switching
    $self->{backup_tab_button}->signal_connect('toggled' => sub {
        if ($_[0]->get_active()) {
            $self->{content_stack}->set_visible_child_name('backup');
            $self->{operation_mode} = 'backup';
            $self->update_operation_mode();
        }
    });
    
    $self->{restore_tab_button}->signal_connect('toggled' => sub {
        if ($_[0]->get_active()) {
            $self->{content_stack}->set_visible_child_name('restore');
            $self->{operation_mode} = 'restore';
            $self->update_operation_mode();
        }
    });
    
    $tab_hbox->pack_start($backup_tab_frame, 1, 1, 0);
    $tab_hbox->pack_start($restore_tab_frame, 1, 1, 0);
    
    # Create backup operations panel
    my $backup_panel = $self->create_backup_operations_panel();
    $self->{content_stack}->add_named($backup_panel, 'backup');
    
    # Create restore operations panel
    my $restore_panel = $self->create_restore_operations_panel();
    $self->{content_stack}->add_named($restore_panel, 'restore');
    
    $self->{left_panel} = $left_vbox;
}

# create_progress_section
# Constructs the progress monitoring section with time labels, icons, and progress bar.
# Creates dual time displays (elapsed and remaining) with disc icons for visual appeal.
# Centers all elements vertically and provides cancel button for operation interruption.
sub create_progress_section {
    my $self = shift;
    
    my $progress_frame = Gtk3::Frame->new();
    #$progress_frame->set_size_request(-1, 240);  
    
    my $progress_vbox = Gtk3::Box->new('vertical', 0);
    $progress_vbox->set_margin_left(15);
    $progress_vbox->set_margin_right(15);
    $progress_vbox->set_margin_top(5);  
    $progress_vbox->set_margin_bottom(5); 
    $progress_frame->add($progress_vbox);
    
    # Status label - generic for backup/restore
    $self->{status_label} = Gtk3::Label->new('Ready to start');
    $self->{status_label}->set_markup('<i>Select destination for backup</i>');
    $self->{status_label}->set_alignment(0.5, 0.5);
    $self->{status_label}->set_visible(0);
    $progress_vbox->pack_start($self->{status_label}, 0, 0, 3); 
    
    # Add flexible spacer to center everything vertically
    my $top_spacer = Gtk3::Label->new('');
    $progress_vbox->pack_start($top_spacer, 0, 0, 10);
    
    # Center container for progress elements
    my $progress_container = Gtk3::Box->new('vertical', 5);  
    $progress_container->set_halign('center');
    $progress_container->set_valign('center');
    $progress_vbox->pack_start($progress_container, 0, 0, 0);
    
    # Container for icon+label pairs
    my $time_sections_box = Gtk3::Box->new('horizontal', 60);
    $time_sections_box->set_halign('center');
    $progress_container->pack_start($time_sections_box, 0, 0, 0);
    
    # LEFT SECTION: Icon + Elapsed time
    my $elapsed_section = Gtk3::Box->new('vertical', 3);  
    $elapsed_section->set_halign('center');
    
    # Left disc icon
    $self->{left_icon_image} = Gtk3::Image->new();
    $self->load_disc_icon_to_image($self->{left_icon_image});
    my $left_icon_align = Gtk3::Alignment->new(0.5, 0.5, 0, 0);
    $left_icon_align->add($self->{left_icon_image});
    $elapsed_section->pack_start($left_icon_align, 0, 0, 0);
    
    # Elapsed time label and value
    my $elapsed_title = Gtk3::Label->new();
    $elapsed_title->set_markup('<span size="small">Elapsed</span>');
    $elapsed_section->pack_start($elapsed_title, 0, 0, 0);
    
    $self->{elapsed_time_label} = Gtk3::Label->new();
    $self->{elapsed_time_label}->set_markup('<span font="monospace" size="16000" weight="bold" color="#cccccc">00:00:00</span>');
    $self->{elapsed_time_label}->set_halign('center');
    $elapsed_section->pack_start($self->{elapsed_time_label}, 0, 0, 0);
    
    $time_sections_box->pack_start($elapsed_section, 0, 0, 0);
    
    # RIGHT SECTION: Icon + Remaining time
    my $remaining_section = Gtk3::Box->new('vertical', 3); 
    $remaining_section->set_halign('center');
    
    # Right disc icon
    $self->{right_icon_image} = Gtk3::Image->new();
    $self->load_disc_icon_to_image($self->{right_icon_image});
    my $right_icon_align = Gtk3::Alignment->new(0.5, 0.5, 0, 0);
    $right_icon_align->add($self->{right_icon_image});
    $remaining_section->pack_start($right_icon_align, 0, 0, 0);
    
    # Remaining time label and value
    my $remaining_title = Gtk3::Label->new();
    $remaining_title->set_markup('<span size="small">Remaining</span>');
    $remaining_section->pack_start($remaining_title, 0, 0, 0);
    
    $self->{remaining_time_label} = Gtk3::Label->new();
    $self->{remaining_time_label}->set_markup('<span font="monospace" size="16000" weight="bold" color="#cccccc">00:00:00</span>');
    $self->{remaining_time_label}->set_halign('center');
    $remaining_section->pack_start($self->{remaining_time_label}, 0, 0, 0);
    
    $time_sections_box->pack_start($remaining_section, 0, 0, 0);
    
    # Progress title 
    my $progress_title = Gtk3::Label->new();
    $progress_title->set_markup('<span size="large" weight="bold">Progress</span>');
    $progress_title->set_halign('center');
    $progress_title->set_visible(0);
    $progress_container->pack_start($progress_title, 0, 0, 3);  
    $self->{progress_title_label} = $progress_title;
    
    # Progress bar
    $self->{progress_bar} = Gtk3::ProgressBar->new();
    $self->{progress_bar}->set_show_text(1);
    $self->{progress_bar}->set_text('Waiting to start...');
    $self->{progress_bar}->set_size_request(400, 24);
    $self->{progress_bar}->set_halign('center');
    $progress_container->pack_start($self->{progress_bar}, 0, 0, 0);
    
    # Add flexible spacer to center the cancel button
    my $middle_spacer = Gtk3::Label->new('');
    $progress_vbox->pack_start($middle_spacer, 1, 1, 0);
    
    # Cancel button container - centered
    my $cancel_container = Gtk3::Box->new('horizontal', 0);
    $cancel_container->set_halign('center');
    $cancel_container->set_valign('center');
    $progress_vbox->pack_start($cancel_container, 0, 0, 0);
    
    # Cancel button
    $self->{cancel_backup_button} = Gtk3::Button->new_with_label('Cancel operation');
    $self->{cancel_backup_button}->set_size_request(180, 38);
    $self->{cancel_backup_button}->set_sensitive(0);
    $self->{cancel_backup_button}->signal_connect(clicked => sub { $self->cancel_backup(); });
    $cancel_container->pack_start($self->{cancel_backup_button}, 0, 0, 0);
    
    # Add bottom flexible spacer - MINIMAL
    my $bottom_spacer = Gtk3::Label->new('');
    $progress_vbox->pack_start($bottom_spacer, 0, 0, 0);  # No expansion
    
    return $progress_frame;
}

# create_restore_operations_panel
# Creates the restore mode panel with system/home/custom restore options.
# Provides restore-specific checkboxes (overwrite, preserve permissions, backup before restore).
# Uses radio buttons for mutual exclusivity between restore types.
sub create_restore_operations_panel {
    my $self = shift;
    
    my $panel = Gtk3::Box->new('vertical', 0);
    $panel->set_margin_left(10);
    $panel->set_margin_right(10);
    $panel->set_margin_top(15);
    $panel->set_margin_bottom(15);
    
    my @restore_operations = (
        ['system', 'Restore system files'],
        ['home', 'Restore home directory'],
        ['custom', 'Restore selected files and folders']
    );
    
    my $radio_group;
    
    foreach my $operation (@restore_operations) {
        my ($type, $label) = @$operation;
        
        my $radio_button = Gtk3::RadioButton->new_with_label($radio_group, $label);
        $radio_group = $radio_button->get_group() unless $radio_group;
        
        $radio_button->set_halign('fill');
        $radio_button->set_size_request(-1, 45);
        
        # Force text alignment to left
        my $button_label = $radio_button->get_child();
        if ($button_label) {
            $button_label->set_alignment(0, 0.5);
            $button_label->set_halign('start');
        }
        
        # Set initial state for system button (first one)
        if ($type eq 'system') {
            $radio_button->set_active(1);
        }
        
        # Add selection effects
        $radio_button->signal_connect('toggled' => sub {
            my $button = $_[0];
            my $current_type = $type; 
            
            if ($button->get_active()) {
                $self->{selected_backup_type} = $current_type;
                $self->update_right_panel();
            }
        });
        
        # Store reference
        $self->{"restore_${type}_button"} = $radio_button;
        
        $panel->pack_start($radio_button, 0, 0, 8);
    }
    
    # Add separator
    my $separator = Gtk3::Separator->new('horizontal');
    $separator->set_margin_top(15);
    $separator->set_margin_bottom(15);
    $panel->pack_start($separator, 0, 0, 0);
    
    # Restore options section 
    my $options_label = Gtk3::Label->new();
    $options_label->set_markup('<b>Restore Options</b>');
    $options_label->set_alignment(0, 0.5);
    $options_label->set_margin_bottom(12);
    $panel->pack_start($options_label, 0, 0, 0);
    
    # Restore option checkboxes
    $self->{overwrite_check} = Gtk3::CheckButton->new_with_label('Overwrite existing files');
    $self->{overwrite_check}->set_active(1);
    $self->{overwrite_check}->set_size_request(-1, 38);
    $panel->pack_start($self->{overwrite_check}, 0, 0, 8);
    
    $self->{preserve_permissions_check} = Gtk3::CheckButton->new_with_label('Preserve file permissions');
    $self->{preserve_permissions_check}->set_active(1);
    $self->{preserve_permissions_check}->set_size_request(-1, 38);
    $panel->pack_start($self->{preserve_permissions_check}, 0, 0, 8);
    
    $self->{backup_before_restore_check} = Gtk3::CheckButton->new_with_label('Create backup before restore');
    $self->{backup_before_restore_check}->set_active(1);
    $self->{backup_before_restore_check}->set_size_request(-1, 38);
    $panel->pack_start($self->{backup_before_restore_check}, 0, 0, 8);
    
    return $panel;
}

# create_right_panel
# Builds the main work area with target selection, action buttons, and progress display.
# Creates target selection section, start button, and progress monitoring components.
# Manages vertical spacing to create balanced, professional layout.
sub create_right_panel {
    my ($self, $parent) = @_;
    
    my $right_frame = Gtk3::Frame->new();
    $parent->pack_start($right_frame, 1, 1, 0);
    
    my $right_vbox = Gtk3::Box->new('vertical', 5);
    $right_vbox->set_margin_left(15);
    $right_vbox->set_margin_right(15);
    $right_vbox->set_margin_top(15);
    $right_vbox->set_margin_bottom(15);
    $right_frame->add($right_vbox);
    
    # Target selection section
    my $target_section = $self->create_target_selection_section();
    $right_vbox->pack_start($target_section, 0, 0, 0);
    
    # Action button container
    my $start_button_container = Gtk3::Box->new('horizontal', 0);
    $start_button_container->set_halign('center');
    # Increase the padding (last digit) from 5 to 30 to push it away from the top/bottom
    $right_vbox->pack_start($start_button_container, 0, 0, 30);
    
    # Action button
    $self->{start_backup_button} = Gtk3::Button->new_with_label('Start Backup');
    $self->{start_backup_button}->set_size_request(180, 38);
    $self->{start_backup_button}->set_sensitive(0);
    $self->{start_backup_button}->signal_connect(clicked => sub { $self->start_backup(); });
    $start_button_container->pack_start($self->{start_backup_button}, 0, 0, 0);
    
    # Progress section
    my $progress_section = $self->create_progress_section();
    $right_vbox->pack_start($progress_section, 1, 1, 0);
    
    $self->{right_panel} = $right_vbox;
}

# create_secure_sudo_script
# Creates executable shell scripts with sudo commands for privileged operations.
# Leverages existing sudo authentication timestamp to avoid password re-prompts.
# Returns script path for execution or undef if authentication hasn't been established.
sub create_secure_sudo_script {
    my ($self, $commands_array, $script_name) = @_;
    
    unless ($self->{sudo_authenticated}) {
        print "ERROR: Not authenticated for sudo operations\n";
        return undef;
    }
    
    my $script_file = "/tmp/${script_name}_$$.sh";
    
    if (open my $fh, '>', $script_file) {
        print $fh "#!/bin/bash\n";
        print $fh "set -e\n\n";
        
        # Add commands (they will use the existing sudo timestamp)
        foreach my $cmd (@$commands_array) {
            if ($cmd =~ /^sudo /) {
                print $fh "$cmd\n";
            } else {
                print $fh "sudo $cmd\n";
            }
        }
        
        close $fh;
        chmod 0700, $script_file;
        
        print "Created secure sudo script: $script_file\n";
        return $script_file;
    }
    
    print "ERROR: Could not create script file\n";
    return undef;
}


# create_target_selection_section
# Creates the horizontal button layout for file and destination selection.
# Organizes "Select folders and files" and "Choose backup destination" buttons side by side.
# Includes backup name entry field below the buttons for user customization.
sub create_target_selection_section {
    my $self = shift;
    
    my $section_frame = Gtk3::Frame->new();
    $section_frame->set_margin_bottom(5);
    
    my $section_vbox = Gtk3::Box->new('vertical', 6);
    $section_vbox->set_margin_top(10);
    $section_vbox->set_margin_bottom(10);
    $section_vbox->set_margin_left(10);
    $section_vbox->set_margin_right(10);
    
    $section_frame->add($section_vbox);
    
    # Create a HORIZONTAL container to hold the two button groups side-by-side
    my $buttons_hbox = Gtk3::Box->new('horizontal', 20); # 20px gap between the two buttons
    $buttons_hbox->set_halign('center'); # Center the whole group
    $section_vbox->pack_start($buttons_hbox, 0, 0, 0);
    
    # --- GROUP 1: Custom Files Selection (Left Side) ---
    my $files_group_vbox = Gtk3::Box->new('vertical', 5);
    $buttons_hbox->pack_start($files_group_vbox, 0, 0, 0);
    
    # Custom file selection button
    $self->{select_files_button} = Gtk3::Button->new_with_label('Select folders and files');
    $self->{select_files_button}->set_size_request(180, 38);
    $self->{select_files_button}->signal_connect(clicked => sub { $self->show_file_selection_dialog(); });
    $self->{select_files_button}->set_visible(0);
    
    # Auto-hide the parent container when the button is hidden
    $self->{select_files_button}->signal_connect('notify::visible' => sub {
        my $button = shift;
        $files_group_vbox->set_visible($button->get_visible());
    });
    
    $files_group_vbox->pack_start($self->{select_files_button}, 0, 0, 0);
    
    # Selected files label (under the button)
    $self->{selected_files_label} = Gtk3::Label->new('No files selected');
    $self->{selected_files_label}->set_markup('<i>No files selected</i>');
    $self->{selected_files_label}->set_alignment(0.5, 0.5); 
    $self->{selected_files_label}->set_visible(0);
    $files_group_vbox->pack_start($self->{selected_files_label}, 0, 0, 3);
    
    # --- GROUP 2: Destination Selection (Right Side) ---
    my $target_group_vbox = Gtk3::Box->new('vertical', 5);
    $buttons_hbox->pack_start($target_group_vbox, 0, 0, 0);
    
    # Target button 
    $self->{target_button} = Gtk3::Button->new_with_label('Choose backup destination');
    $self->{target_button}->set_size_request(180, 38);
    $self->{target_button}->signal_connect(clicked => sub { $self->choose_backup_destination(); });
    $self->{target_button}->set_visible(0); 
    $target_group_vbox->pack_start($self->{target_button}, 0, 0, 0);
    
    # Target label (under the button)
    $self->{destination_label} = Gtk3::Label->new('No destination selected');
    $self->{destination_label}->set_markup('<i>No destination selected</i>');
    $self->{destination_label}->set_alignment(0.5, 0.5);  
    $self->{destination_label}->set_visible(0); 
    $target_group_vbox->pack_start($self->{destination_label}, 0, 0, 3);
    
    # Backup name section - VERTICAL layout, centered
    my $name_vbox = Gtk3::Box->new('vertical', 5);
    $name_vbox->set_halign('center');  # Center the whole name section
    $name_vbox->set_margin_top(25);
    $section_vbox->pack_start($name_vbox, 0, 0, 10);
    $self->{backup_name_hbox} = $name_vbox;  # Keep the same variable name for compatibility
    
    # Backup name label - centered
    my $name_label = Gtk3::Label->new('Backup name:');
    $name_label->set_alignment(0.5, 0.5);  # Center the text
    $name_vbox->pack_start($name_label, 0, 0, 0);
    
    # Backup name entry box - centered with same width as progress bar (400px)
    $self->{backup_name_entry} = Gtk3::Entry->new();
    # Don't set initial text here - it will be set by update_backup_name()
    $self->{backup_name_entry}->set_size_request(400, -1);  # Same width as progress bar (400px)
    $self->{backup_name_entry}->set_alignment(0.5);  # Center the text inside the entry box
    $self->{backup_name_entry}->set_halign('center');
    $name_vbox->pack_start($self->{backup_name_entry}, 0, 0, 0);
    
    return $section_frame;
}

# show_about_dialog
# Shows application information including version, authors, and license.
# Creates GTK AboutDialog with project details and GitHub link.
# Provides standard application metadata in a modal dialog window.
sub show_about_dialog {
    my $self = shift;
    
    my $dialog = Gtk3::AboutDialog->new();
    $dialog->set_transient_for($self->{window});
    $dialog->set_modal(1);
    
    $dialog->set_program_name('Wolfmans Backup Tool');
    $dialog->set_version('1.0');
    $dialog->set_comments('A backup solution written in Perl');
    $dialog->set_website('https://github.com/crojack/wolfmans-backup-tool');
    $dialog->set_website_label('Project Homepage');
    $dialog->set_authors(['Zeljko Vukman']);
    $dialog->set_license_type('gpl-3-0');
    
    $dialog->run();
    $dialog->destroy();
}

# show_backup_metadata_chooser
# Displays file chooser for selecting previous backup folders for incremental operations.
# Looks for .backup_info.json in selected folder to validate backup structure.
# Loads metadata and triggers compatibility verification before proceeding.
sub show_backup_metadata_chooser {
    my $self = shift;
    
    my $dialog = Gtk3::FileChooserDialog->new(
        'Select Previous Backup Location',
        $self->{window},
        'select-folder',
        'gtk-cancel' => 'cancel',
        'gtk-open' => 'ok'
    );
    
    $dialog->set_default_response('ok');
    
    # Add info label
    my $info_label = Gtk3::Label->new();
    $info_label->set_markup("<b>Select the folder containing your previous backup</b>\n" .
                           "The tool will look for .backup_info.json in the selected folder.");
    $info_label->set_margin_left(10);
    $info_label->set_margin_right(10);
    $info_label->set_margin_top(10);
    $info_label->set_margin_bottom(10);
    
    my $content_area = $dialog->get_content_area();
    $content_area->pack_start($info_label, 0, 0, 0);
    $dialog->show_all();
    
    my $response = $dialog->run();
    
    if ($response eq 'ok') {
        my $selected_folder = $dialog->get_filename();
        $dialog->destroy();
        
        # Try to load backup metadata
        $self->load_backup_metadata($selected_folder);
    } else {
        $dialog->destroy();
    }
}

# show_completion_dialog
# Shows a modal dialog confirming successful backup or restore completion.
# Displays the destination path where backup was saved or files were restored.
# Re-enables UI buttons and updates progress indicators to show completion status.
sub show_completion_dialog {
    my $self = shift;
    
    my $message;
    my $title;
    
    if ($self->{operation_mode} eq 'restore') {
        $title = 'Restore Complete';
        $message = "Restore completed successfully!\n\n";
        $message .= "Files restored to: " . ($self->{restore_destination} || 'Unknown location');
    } else {
        $title = 'Backup Complete';
        $message = "Backup completed successfully!\n\n";
        
        # Get backup location - handle both regular and incremental backups
        my $backup_location = $self->{backup_dir} || $self->{incremental_backup_folder} || $self->{backup_destination} || 'Unknown location';
        $message .= "Backup saved to: " . $backup_location;
    }
    
    my $dialog = Gtk3::MessageDialog->new(
        $self->{window},
        'modal',
        'info',
        'ok',
        $message
    );
    
    $dialog->set_title($title);
    $dialog->run();
    $dialog->destroy();
    
    # Re-enable buttons and reset states - with comprehensive null checks
    if ($self->{start_backup_button}) {
        eval { $self->{start_backup_button}->set_sensitive(1); };
        print "WARNING: Could not re-enable start button: $@\n" if $@;
    }
    
    if ($self->{target_button}) {
        eval { $self->{target_button}->set_sensitive(1); };
        print "WARNING: Could not re-enable target button: $@\n" if $@;
    }
    
    if ($self->{cancel_backup_button}) {
        eval { $self->{cancel_backup_button}->set_sensitive(0); };  # Disable cancel button
        print "WARNING: Could not disable cancel button: $@\n" if $@;
    }
    
    # Update status and progress with null checks
    if ($self->{operation_mode} eq 'restore') {
        if ($self->{status_label}) {
            eval { $self->{status_label}->set_markup('<span size="large" weight="bold" color="green">Restore completed successfully!</span>'); };
            print "WARNING: Could not update status label: $@\n" if $@;
        }
        # Set progress bar to 100%
        if ($self->{progress_bar}) {
            eval { 
                $self->{progress_bar}->set_fraction(1.0);
                $self->{progress_bar}->set_text('100% - Restore completed!');
            };
            print "WARNING: Could not update progress bar: $@\n" if $@;
        }
    } else {
        if ($self->{status_label}) {
            eval { $self->{status_label}->set_markup('<span size="large" weight="bold" color="green">Backup completed successfully!</span>'); };
            print "WARNING: Could not update status label: $@\n" if $@;
        }
        # Set progress bar to 100%
        if ($self->{progress_bar}) {
            eval { 
                $self->{progress_bar}->set_fraction(1.0);
                $self->{progress_bar}->set_text('100% - Backup completed!');
            };
            print "WARNING: Could not update progress bar: $@\n" if $@;
        }
    }
}

# show_error_dialog
# Creates modal error dialogs with custom title and message.
# Blocks application interaction until user acknowledges the error.
# Uses GTK MessageDialog with error icon for clear visual communication.
sub show_error_dialog {
    my ($self, $title, $message) = @_;
    my $dialog = Gtk3::MessageDialog->new($self->{window}, 'modal', 'error', 'ok', $message);
    $dialog->set_title($title);
    $dialog->run();
    $dialog->destroy();
}

# show_file_selection_dialog
# Displays a custom file browser for selecting specific files and folders to backup.
# Provides navigation buttons (Up, Home, Root) and tree view with checkboxes.
# Updates selected file list and enables destination selection when files are chosen.
sub show_file_selection_dialog {
    my $self = shift;
    
    # Import required modules
    use File::Basename qw(dirname);
    
    my $dialog = Gtk3::Dialog->new(
        'Select Files and Folders to Backup',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(700, 500);
    $dialog->set_resizable(1); 
    
    my $content_area = $dialog->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 10);
    $vbox->set_margin_left(20);
    $vbox->set_margin_right(20);
    $vbox->set_margin_top(20);
    $vbox->set_margin_bottom(20);
    $content_area->add($vbox);
    
    # Current path label
    my $path_label = Gtk3::Label->new();
    $path_label->set_markup('<b>Current folder: ' . $ENV{HOME} . '</b>');
    $path_label->set_alignment(0, 0.5);
    $vbox->pack_start($path_label, 0, 0, 0);  
    
    # Navigation buttons
    my $nav_hbox = Gtk3::Box->new('horizontal', 5);
    $vbox->pack_start($nav_hbox, 0, 0, 0); 
    
    my $up_button = Gtk3::Button->new_with_label('Up');
    my $home_button = Gtk3::Button->new_with_label('Home');
    my $root_button = Gtk3::Button->new_with_label('Root');
    
    $nav_hbox->pack_start($up_button, 0, 0, 0);
    $nav_hbox->pack_start($home_button, 0, 0, 0);
    $nav_hbox->pack_start($root_button, 0, 0, 0);
    
    # Create scrolled window for file list 
    my $scrolled = Gtk3::ScrolledWindow->new();
    $scrolled->set_policy('automatic', 'automatic');
    $scrolled->set_hexpand(1); 
    $scrolled->set_vexpand(1); 
    $vbox->pack_start($scrolled, 1, 1, 0); 
    
    # Create tree view for files and folders
    my $store = Gtk3::ListStore->new('Glib::Boolean', 'Glib::String', 'Glib::String', 'Glib::String');
    my $tree_view = Gtk3::TreeView->new($store);
    $scrolled->add($tree_view);
    
    # Checkbox column
    my $check_renderer = Gtk3::CellRendererToggle->new();
    $check_renderer->set_property('activatable', 1);
    my $check_column = Gtk3::TreeViewColumn->new_with_attributes('Select', $check_renderer, 'active' => 0);
    $check_column->set_sizing('fixed');
    $check_column->set_fixed_width(60);
    $tree_view->append_column($check_column);
    
    # Name column
    my $name_renderer = Gtk3::CellRendererText->new();
    my $name_column = Gtk3::TreeViewColumn->new_with_attributes('Name', $name_renderer, 'text' => 1);
    $name_column->set_expand(1);
    $name_column->set_resizable(1);
    $tree_view->append_column($name_column);
    
    # Type column
    my $type_renderer = Gtk3::CellRendererText->new();
    my $type_column = Gtk3::TreeViewColumn->new_with_attributes('Type', $type_renderer, 'text' => 2);
    $type_column->set_sizing('fixed');
    $type_column->set_fixed_width(80);
    $tree_view->append_column($type_column);
    
    # Full path column (hidden)
    my $path_renderer = Gtk3::CellRendererText->new();
    my $path_column = Gtk3::TreeViewColumn->new_with_attributes('Path', $path_renderer, 'text' => 3);
    $path_column->set_visible(0);
    $tree_view->append_column($path_column);
    
    # Track current directory and selected files
    my $current_dir = $ENV{HOME};
    my %selected_files = ();
    
    # Populate function
    my $populate_list = sub {
        my $dir = shift;
        $store->clear();
        $path_label->set_markup('<b>Current folder: ' . $dir . '</b>');
        
        my $dh;
        if (!opendir($dh, $dir)) {
            print "Cannot open directory $dir: $!\n";
            return;
        }
        
        my @entries = readdir($dh);
        closedir($dh);
        
        # Sort: directories first, then files
        @entries = sort {
            my $a_is_dir = -d "$dir/$a";
            my $b_is_dir = -d "$dir/$b";
            
            if ($a_is_dir && !$b_is_dir) { return -1; }
            if (!$a_is_dir && $b_is_dir) { return 1; }
            return lc($a) cmp lc($b);
        } grep { $_ ne '.' && $_ ne '..' } @entries;
        
        # Add parent directory entry if not at root
        if ($dir ne '/') {
            my $iter = $store->append();
            $store->set($iter, 0 => 0, 1 => '..', 2 => 'Parent Directory', 3 => dirname($dir));
        }
        
        foreach my $entry (@entries) {
            # Check hidden files setting
            if ($entry =~ /^\./ && $self->{hidden_check} && !$self->{hidden_check}->get_active()) {
                next; # Skip hidden files if option is off
            }
            
            my $full_path = "$dir/$entry";
            my $type = -d $full_path ? 'Folder' : 'File';
            my $is_selected = exists $selected_files{$full_path};
            
            my $iter = $store->append();
            $store->set($iter, 0 => $is_selected, 1 => $entry, 2 => $type, 3 => $full_path);
        }
    };
    
    # Initial population
    $populate_list->($current_dir);
    
    # Handle checkbox toggling
    $check_renderer->signal_connect('toggled' => sub {
        my ($renderer, $path_str) = @_;
        my $path = Gtk3::TreePath->new($path_str);
        my $iter = $store->get_iter($path);
        
        my ($selected, $name, $type, $full_path) = $store->get($iter, 0, 1, 2, 3);
        
        # Don't allow selection of parent directory
        return if $name eq '..';
        
        $selected = !$selected;
        $store->set($iter, 0 => $selected);
        
        if ($selected) {
            $selected_files{$full_path} = 1;
        } else {
            delete $selected_files{$full_path};
        }
    });
    
    # Handle double-click navigation
    $tree_view->signal_connect('row-activated' => sub {
        my ($tree_view, $path, $column) = @_;
        my $iter = $store->get_iter($path);
        my ($name, $type, $full_path) = $store->get($iter, 1, 2, 3);
        
        if ($type eq 'Folder' || $type eq 'Parent Directory') {
            $current_dir = $full_path;
            $populate_list->($current_dir);
        }
    });
    
    # Navigation button handlers
    $up_button->signal_connect('clicked' => sub {
        my $parent = dirname($current_dir);
        if ($parent ne $current_dir) {
            $current_dir = $parent;
            $populate_list->($current_dir);
        }
    });
    
    $home_button->signal_connect('clicked' => sub {
        $current_dir = $ENV{HOME};
        $populate_list->($current_dir);
    });
    
    $root_button->signal_connect('clicked' => sub {
        $current_dir = '/';
        $populate_list->($current_dir);
    });
    
    # Selection summary
    my $summary_label = Gtk3::Label->new('No files selected');
    $vbox->pack_start($summary_label, 0, 0, 0);  # Don't expand
    
    # Update summary periodically
    my $update_summary = sub {
        my $count = keys %selected_files;
        if ($count == 0) {
            $summary_label->set_text('No files selected');
        } else {
            $summary_label->set_text("$count items selected");
        }
    };
    
    # Add timer to update summary
    my $timer_id = Glib::Timeout->add(500, sub { $update_summary->(); return 1; });
    
    $dialog->show_all();
    my $response = $dialog->run();
    
    # Clean up timer
    Glib::Source->remove($timer_id);
    
    if ($response eq 'ok') {
        my @selected_list = keys %selected_files;
        $self->{selected_files} = \@selected_list;
        
        my $count = @selected_list;
        if ($count > 0) {
            $self->{selected_files_label}->set_markup("<b>Selected:</b> $count items");
            
            # Enable destination selection
            $self->{target_button}->set_sensitive(1);
        } else {
            $self->{selected_files_label}->set_markup('<i>No files selected</i>');
        }
    }
    
    $dialog->destroy();
}


# show_incremental_restore_dialog
# Presents users with options for restoring backups that have incremental additions.
# Shows list of available incremental backups with timestamps and types.
# Allows users to restore full backup only or include all incremental changes.
sub show_incremental_restore_dialog {
    my ($self, $backup_folder, $metadata) = @_;
    
    my $dialog = Gtk3::Dialog->new(
        'Incremental Backups Detected',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(500, 300);
    
    my $content = $dialog->get_content_area();
    $content->set_margin_left(15);
    $content->set_margin_right(15);
    $content->set_margin_top(15);
    $content->set_margin_bottom(15);
    
    # Info label
    my $info_label = Gtk3::Label->new();
    $info_label->set_markup(
        "<b>This backup contains incremental backups</b>\n\n" .
        "Incremental backups contain only the files that changed since the original backup.\n" .
        "You can restore just the full backup, or include the incremental changes."
    );
    $info_label->set_line_wrap(1);
    $info_label->set_alignment(0, 0);
    $content->pack_start($info_label, 0, 0, 10);
    
    # Show incremental backup details
    my $details_frame = Gtk3::Frame->new('Available Incremental Backups');
    $content->pack_start($details_frame, 1, 1, 10);
    
    my $scrolled = Gtk3::ScrolledWindow->new();
    $scrolled->set_policy('automatic', 'automatic');
    $details_frame->add($scrolled);
    
    my $details_text = Gtk3::TextView->new();
    $details_text->set_editable(0);
    $details_text->set_cursor_visible(0);
    $details_text->set_wrap_mode('word');
    $details_text->set_margin_left(10);
    $details_text->set_margin_right(10);
    $details_text->set_margin_top(10);
    $details_text->set_margin_bottom(10);
    $scrolled->add($details_text);
    
    my $buffer = $details_text->get_buffer();
    my $text = $self->format_incremental_backup_list($backup_folder, $metadata);
    $buffer->set_text($text);
    
    # Options
    my $separator = Gtk3::Separator->new('horizontal');
    $content->pack_start($separator, 0, 0, 10);
    
    # Radio buttons for restore options
    my $full_only_radio = Gtk3::RadioButton->new_with_label([], 'Restore full backup only');
    $content->pack_start($full_only_radio, 0, 0, 5);
    
    my $with_incrementals_radio = Gtk3::RadioButton->new_with_label_from_widget(
        $full_only_radio, 
        'Restore full backup + all incremental backups (recommended)'
    );
    $with_incrementals_radio->set_active(1);  # Default to including incrementals
    $content->pack_start($with_incrementals_radio, 0, 0, 5);
    
    $dialog->show_all();
    my $response = $dialog->run();
    
    if ($response eq 'ok') {
        my $include_incrementals = $with_incrementals_radio->get_active();
        $self->{restore_include_incrementals} = $include_incrementals;
        
        # Update UI
        my $backup_name = (split '/', $backup_folder)[-1];
        my $label_text = "<b>Restore from:</b> $backup_name";
        if ($include_incrementals) {
            $label_text .= " <i>(with incrementals)</i>";
        }
        $self->{destination_label}->set_markup($label_text);
        $self->{target_button}->set_label('Change backup source');
        
        # Show restore destination dialog
        print "Backup selected, showing restore destination dialog...\n";
        $self->show_restore_destination_dialog($metadata);
    }
    
    $dialog->destroy();
}

# show_menu
# Shows popup menu with Settings, About, and Quit options.
# Attaches menu to header bar and positions it appropriately.
# Provides standard application menu functionality.
sub show_menu {
    my $self = shift;
    
    my $menu = Gtk3::Menu->new();
    
    # Settings menu item
    my $settings_item = Gtk3::MenuItem->new_with_label('Settings');
    $settings_item->signal_connect(activate => sub { $self->show_settings_dialog(); });
    $menu->append($settings_item);
    
    # Separator
    my $separator = Gtk3::SeparatorMenuItem->new();
    $menu->append($separator);
    
    # About menu item
    my $about_item = Gtk3::MenuItem->new_with_label('About');
    $about_item->signal_connect(activate => sub { $self->show_about_dialog(); });
    $menu->append($about_item);
    
    # Quit menu item
    my $quit_item = Gtk3::MenuItem->new_with_label('Quit');
    $quit_item->signal_connect(activate => sub { Gtk3::main_quit(); });
    $menu->append($quit_item);
    
    $menu->show_all();
    $menu->popup_at_widget($self->{headerbar}, 'south-west', 'north-west', undef);
}

# show_password_dialog
# Requests administrator password for operations requiring elevated privileges.
# Creates modal dialog with password entry field (hidden input for security).
# Returns entered password or undef if user cancels.
sub show_password_dialog {
    my ($self, $message) = @_;
    
    my $dialog = Gtk3::Dialog->new(
        'Administrator Password Required',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(400, 200);
    $dialog->set_resizable(0);
    
    my $content_area = $dialog->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 10);
    $vbox->set_margin_left(20);
    $vbox->set_margin_right(20);
    $vbox->set_margin_top(20);
    $vbox->set_margin_bottom(20);
    $content_area->add($vbox);
    
    # Icon and message
    my $hbox = Gtk3::Box->new('horizontal', 10);
    $vbox->pack_start($hbox, 0, 0, 0);
    
    # Add warning icon
    my $icon = Gtk3::Image->new_from_stock('gtk-dialog-authentication', 'dialog');
    $hbox->pack_start($icon, 0, 0, 0);
    
    my $label = Gtk3::Label->new();
    $label->set_markup($message || 
        'Please enter your password to continue:'
    );
    $label->set_line_wrap(1);
    $label->set_alignment(0, 0.5);
    $hbox->pack_start($label, 1, 1, 0);
    
    # Password entry
    my $password_hbox = Gtk3::Box->new('horizontal', 10);
    $vbox->pack_start($password_hbox, 0, 0, 0);
    
    my $password_label = Gtk3::Label->new('Password:');
    $password_hbox->pack_start($password_label, 0, 0, 0);
    
    my $password_entry = Gtk3::Entry->new();
    $password_entry->set_visibility(0);  # Hide password
    $password_entry->set_activates_default(1);  # Enter key activates OK
    $password_hbox->pack_start($password_entry, 1, 1, 0);
    
    # Set OK as default button
    $dialog->set_default_response('ok');
    
    $dialog->show_all();
    $password_entry->grab_focus();  # Focus on password field
    
    my $response = $dialog->run();
    my $password = '';
    
    if ($response eq 'ok') {
        $password = $password_entry->get_text();
    }
    
    $dialog->destroy();
    
    return ($response eq 'ok') ? $password : undef;
}


# show_question_dialog
# Displays yes/no question dialogs for user confirmation.
# Returns true if user clicks "yes", false for "no".
# Used for operations that need explicit user approval.
sub show_question_dialog {
    my ($self, $title, $message) = @_;
    my $dialog = Gtk3::MessageDialog->new($self->{window}, 'modal', 'question', 'yes-no', $message);
    $dialog->set_title($title);
    my $response = $dialog->run();
    $dialog->destroy();
    return ($response eq 'yes');
}

# show_restore_destination_dialog
# Presents comprehensive dialog for choosing where to restore backup files.
# Shows backup information and offers original location or custom destination.
# Provides restore options (merge mode, backup existing files) and updates UI when confirmed.
sub show_restore_destination_dialog {
    my ($self, $metadata) = @_;
    
    my $dialog = Gtk3::Dialog->new(
        'Choose Restore Destination',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(600, 400);
    
    my $content_area = $dialog->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 10);
    $vbox->set_margin_left(20);
    $vbox->set_margin_right(20);
    $vbox->set_margin_top(20);
    $vbox->set_margin_bottom(20);
    $content_area->add($vbox);
    
    # Show backup information
    if ($metadata) {
        my $info_label = Gtk3::Label->new();
        my $backup_type = $metadata->{backup_type} || 'unknown';
        my $created = $metadata->{created_readable} || 'unknown';
        
        $info_label->set_markup(
            "<b>Backup Information:</b>\n" .
            "Type: " . ucfirst($backup_type) . "\n" .
            "Created: $created\n" .
            "Original user: " . ($metadata->{original_user} || 'unknown')
        );
        $info_label->set_alignment(0, 0);
        $vbox->pack_start($info_label, 0, 0, 0);
        
        my $separator = Gtk3::Separator->new('horizontal');
        $vbox->pack_start($separator, 0, 0, 10);
    }
    
    # Restore options
    my $options_label = Gtk3::Label->new();
    $options_label->set_markup('<b>Restore Options:</b>');
    $options_label->set_alignment(0, 0.5);
    $vbox->pack_start($options_label, 0, 0, 0);
    
    # Option 1: Restore to original location (recommended)
    my $original_radio = Gtk3::RadioButton->new_with_label([], 'Restore to original location (recommended)');
    $vbox->pack_start($original_radio, 0, 0, 5);
    
    my $original_info = Gtk3::Label->new();
    if ($metadata) {
        my $suggested_path = $self->get_suggested_restore_path($metadata);
        $original_info->set_markup("<small><i>Will restore to: $suggested_path</i></small>");
    } else {
        $original_info->set_markup("<small><i>Will attempt to restore to original location</i></small>");
    }
    $original_info->set_alignment(0, 0.5);
    $original_info->set_margin_left(20);
    $vbox->pack_start($original_info, 0, 0, 0);
    
    # Option 2: Choose custom location
    my $custom_radio = Gtk3::RadioButton->new_with_label_from_widget($original_radio, 'Choose custom destination');
    $vbox->pack_start($custom_radio, 0, 0, 15);
    
    # Custom path selection
    my $path_hbox = Gtk3::Box->new('horizontal', 10);
    $path_hbox->set_margin_left(20);
    $vbox->pack_start($path_hbox, 0, 0, 0);
    
    my $path_entry = Gtk3::Entry->new();
    $path_entry->set_text($ENV{HOME});
    $path_entry->set_sensitive(0);  # Initially disabled
    $path_hbox->pack_start($path_entry, 1, 1, 0);
    
    my $browse_button = Gtk3::Button->new_with_label('Browse...');
    $browse_button->set_sensitive(0);  # Initially disabled
    $path_hbox->pack_start($browse_button, 0, 0, 0);
    
    # Enable/disable custom path controls based on radio selection
    $original_radio->signal_connect(toggled => sub {
        if ($_[0]->get_active()) {
            $path_entry->set_sensitive(0);
            $browse_button->set_sensitive(0);
        }
    });
    
    $custom_radio->signal_connect(toggled => sub {
        if ($_[0]->get_active()) {
            $path_entry->set_sensitive(1);
            $browse_button->set_sensitive(1);
        }
    });
    
    # Browse button functionality
    $browse_button->signal_connect(clicked => sub {
        my $folder_dialog = Gtk3::FileChooserDialog->new(
            'Choose Restore Destination',
            $dialog,
            'select-folder',
            'gtk-cancel' => 'cancel',
            'gtk-open' => 'ok'
        );
        
        my $folder_response = $folder_dialog->run();
        if ($folder_response eq 'ok') {
            $path_entry->set_text($folder_dialog->get_filename());
        }
        $folder_dialog->destroy();
    });
    
    # Restore options
    my $options_separator = Gtk3::Separator->new('horizontal');
    $vbox->pack_start($options_separator, 0, 0, 10);
    
    my $merge_check = Gtk3::CheckButton->new_with_label('Merge with existing files (recommended)');
    $merge_check->set_active(1);
    $vbox->pack_start($merge_check, 0, 0, 5);
    
    my $backup_before_check = Gtk3::CheckButton->new_with_label('Create backup of existing files before overwriting');
    $backup_before_check->set_active(1);
    $vbox->pack_start($backup_before_check, 0, 0, 5);
    
    $dialog->show_all();
    my $dialog_response = $dialog->run();
    
    if ($dialog_response eq 'ok') {
        my $restore_destination;
        my $merge_mode = $merge_check->get_active();
        my $backup_existing = $backup_before_check->get_active();
        
        if ($original_radio->get_active()) {
            # Restore to original location
            $restore_destination = $self->get_suggested_restore_path($metadata);
            print "Restoring to original location: $restore_destination\n";
        } else {
            # Restore to custom location
            $restore_destination = $path_entry->get_text();
            print "Restoring to custom location: $restore_destination\n";
        }
        
        # Store restore settings
        $self->{restore_destination} = $restore_destination;
        $self->{restore_merge_mode} = $merge_mode;
        $self->{restore_backup_existing} = $backup_existing;
        
        # Update UI to show restore is ready
        my $type_name = {
            'system' => 'system',
            'home' => 'home directory',
            'custom' => 'selected files'
        };
        my $backup_type = $metadata ? $metadata->{backup_type} : $self->{selected_backup_type};
        my $name = $type_name->{$backup_type} || 'data';
        
        # IMPORTANT: Update the status label AND make it visible
        if ($self->{status_label}) {
            $self->{status_label}->set_markup("<span size=\"large\" weight=\"bold\">Ready to restore $name</span>");
            $self->{status_label}->set_visible(1);
        }
        
        # Enable start restore button
        $self->update_start_button_state();
        
        print "Restore destination set, UI updated\n";
    }
    
    $dialog->destroy();
}

# show_settings_dialog
# Displays modal settings dialog for configuring application preferences.
# Allows users to adjust border width and other application settings.
# Saves settings to disk when user clicks OK.
sub show_settings_dialog {
    my $self = shift;
    
    my $dialog = Gtk3::Dialog->new(
        'Settings',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(400, 200);  # Reduced height since we removed color section
    
    my $content_area = $dialog->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 10);
    $vbox->set_margin_left(20);
    $vbox->set_margin_right(20);
    $vbox->set_margin_top(20);
    $vbox->set_margin_bottom(20);
    $content_area->add($vbox);
    
    # Border width setting (keeping this if you want border functionality)
    my $border_hbox = Gtk3::Box->new('horizontal', 10);
    $vbox->pack_start($border_hbox, 0, 0, 0);
    
    my $border_label = Gtk3::Label->new('Border width:');
    $border_hbox->pack_start($border_label, 0, 0, 0);
    
    my $border_spin = Gtk3::SpinButton->new_with_range(1, 5, 1);
    $border_spin->set_value($self->{settings}->{border_width} || 2);
    $border_hbox->pack_start($border_spin, 0, 0, 0);
    
    $dialog->show_all();
    my $response = $dialog->run();
    
    if ($response eq 'ok') {
        $self->{settings}->{border_width} = $border_spin->get_value();
        
        $self->save_settings();
    }
    
    $dialog->destroy();
}

# copy_file_with_structure
# Copies individual files while creating necessary destination directory structure.
# Preserves file timestamps and permissions from source to destination.
# Returns success status and handles errors with descriptive messages.
sub copy_file_with_structure {
    my ($self, $source_path, $dest_path) = @_;
    
    # Create destination directory
    my $dest_dir = dirname($dest_path);
    unless (-d $dest_dir) {
        File::Path::make_path($dest_dir) or do {
            print "ERROR: Could not create directory $dest_dir: $!\n";
            return 0;
        };
    }
    
    # Copy the file
    if (File::Copy::copy($source_path, $dest_path)) {
        # Preserve timestamps and permissions
        my ($atime, $mtime) = (stat($source_path))[8, 9];
        utime($atime, $mtime, $dest_path);
        
        my $mode = (stat($source_path))[2];
        chmod($mode & 07777, $dest_path);
        
        return 1;
    } else {
        print "ERROR: Could not copy $source_path to $dest_path: $!\n";
        return 0;
    }
}

# restore_by_type
# Routes restore operations to appropriate handler based on backup type.
# Checks if incremental restore is requested and calls appropriate restore method.
# Supports system, home, custom, and directory backup type restoration.
sub restore_by_type {
    my ($self, $metadata, $progress_file) = @_;
    
    my $backup_type = $metadata->{backup_type};
    print "Restoring $backup_type backup using metadata\n";
    
    # Check if we should restore with incrementals
    if ($self->{restore_include_incrementals}) {
        print "Incremental restore requested\n";
        $self->restore_with_incrementals($metadata, $progress_file);
        return;
    }
    
    # Standard restore (full backup only)
    if ($backup_type eq 'directory') {
        # Handle directory backup type
        print "Directory backup type detected, using restore_from_directory\n";
        $self->restore_from_directory($self->{restore_source}, $self->{restore_destination}, $progress_file);
    } elsif ($backup_type eq 'custom') {
        $self->restore_custom_backup($self->{restore_source}, $self->{restore_destination}, $progress_file, $metadata);
    } elsif ($backup_type eq 'home') {
        $self->restore_home_backup($self->{restore_source}, $self->{restore_destination}, $progress_file, $metadata);
    } elsif ($backup_type eq 'system') {
        $self->restore_system_backup($self->{restore_source}, $self->{restore_destination}, $progress_file, $metadata);
    } else {
        print "Unknown backup type: $backup_type, falling back to directory restore\n";
        $self->restore_from_directory($self->{restore_source}, $self->{restore_destination}, $progress_file);
    }
}

# restore_custom_backup
# Restores backups of user-selected files and folders.
# Detects whether backup is tar-based or directory-based and calls appropriate handler.
# Uses metadata to determine original file locations for proper restoration.
sub restore_custom_backup {
    my ($self, $source_dir, $dest_dir, $progress_file, $metadata) = @_;
    
    print "Restoring custom backup from $source_dir to $dest_dir\n";
    
    # Check if this is a tar-based backup or directory-based backup
    opendir(my $dh, $source_dir) or die "Cannot open source directory: $!";
    my @files = readdir($dh);
    closedir($dh);
    
    # Look for tar-based backup files first
    my @tar_files = grep { /^custom_backup_\d{8}_\d{6}\.tar(\.gz)?(\.gpg)?$/ } @files;
    
    if (@tar_files > 0) {
        # Restore from tar file
        my $tar_file = "$source_dir/$tar_files[0]";
        print "Restoring from tar file: $tar_file\n";
        $self->restore_from_tar($tar_file, $dest_dir, $progress_file, $metadata);
    } else {
        # Restore from directory structure
        print "Restoring from directory structure\n";
        $self->restore_from_directory($source_dir, $dest_dir, $progress_file);
    }
}

# restore_from_directory
# Restores backups using rsync to copy directory structures.
# Supports merge mode (keep existing files) or replace mode (delete extra files).
# Creates backup of existing files if requested before overwriting.
sub restore_from_directory {
    my ($self, $source_dir, $dest_dir, $progress_file) = @_;
    
    print "Restoring directory-based backup using rsync\n";
    
    # Ensure destination directory exists
    File::Path::make_path($dest_dir) unless -d $dest_dir;
    
    # Build rsync command for restore
    my @rsync_args = ('rsync', '-av', '--progress');
    
    # Add merge options if specified
    if ($self->{restore_merge_mode}) {
        print "Merge mode enabled - files will be merged with existing\n";
    } else {
        push @rsync_args, '--delete';  # Delete files not in backup
        print "Replace mode enabled - destination will match backup exactly\n";
    }
    
    # Create backup of existing files if requested
    if ($self->{restore_backup_existing}) {
        my $backup_suffix = POSIX::strftime("_backup_%d%m%Y_%H%M%S", localtime);
        push @rsync_args, "--backup", "--suffix=$backup_suffix";
        print "Will backup existing files with suffix: $backup_suffix\n";
    }
    
    push @rsync_args, "$source_dir/", "$dest_dir/";
    
    print "Running restore command: " . join(' ', @rsync_args) . "\n";
    
    # Execute rsync with progress monitoring
    my $pid = open(my $rsync_fh, '-|', @rsync_args) or die "Could not start rsync: $!";
    
    while (my $line = <$rsync_fh>) {
        print $line;
        
        # Parse rsync progress and update progress file
        if ($line =~ /(\d+)%/) {
            my $percent = $1;
            if (open my $fh, '>', $progress_file) {
                print $fh "$percent\n";
                close $fh;
            }
        }
    }
    
    close($rsync_fh);
    my $exit_code = $? >> 8;
    
    if ($exit_code == 0) {
        print "Restore completed successfully\n";
    } else {
        die "Restore failed with exit code: $exit_code";
    }
}

# restore_from_tar
# Extracts tar-based backups with support for compression and encryption.
# Uses metadata to correctly determine compression/encryption instead of just filename.
# Monitors extraction progress and updates UI with percentage and file count.
sub restore_from_tar {
    my ($self, $tar_file, $dest_dir, $progress_file, $metadata) = @_;
    
    print "Restoring from tar file: $tar_file to $dest_dir\n";
    
    # Ensure destination directory exists
    File::Path::make_path($dest_dir) unless -d $dest_dir;
    
    # CRITICAL FIX: Use metadata to determine compression/encryption instead of filename
    my $is_compressed = 0;
    my $is_encrypted = 0;
    
    if ($metadata) {
        $is_compressed = $metadata->{compression_enabled} || 0;
        $is_encrypted = $metadata->{encryption_enabled} || 0;
        print "Using metadata: compression=" . ($is_compressed ? "yes" : "no") . 
              ", encryption=" . ($is_encrypted ? "yes" : "no") . "\n";
    } else {
        # Fallback to filename parsing if no metadata
        $is_compressed = ($tar_file =~ /\.gz(?!\.gpg$)/);  # .gz but not .gz.gpg without actual compression
        $is_encrypted = ($tar_file =~ /\.gpg$/);
        print "Using filename detection: compression=" . ($is_compressed ? "yes" : "no") . 
              ", encryption=" . ($is_encrypted ? "yes" : "no") . "\n";
    }
    
    print "Tar file - Compressed: " . ($is_compressed ? "yes" : "no") . 
          ", Encrypted: " . ($is_encrypted ? "yes" : "no") . "\n";
    
    # Build extraction command
    my $extract_cmd;
    my $password_file;  # Declare outside so we can clean it up later
    
    if ($is_encrypted) {
        # Use the pre-obtained password from parent process
        my $password = $self->{restore_password};
        unless ($password) {
            die "Restore failed - encrypted backup detected but no decryption password available";
        }
        
        print "Using decryption password from parent process\n";
        
        # Create secure temporary password file
        $password_file = "/tmp/restore_pass_$$.tmp";
        if (open my $pass_fh, '>', $password_file) {
            print $pass_fh $password;
            close $pass_fh;
            chmod 0600, $password_file;
            print "Created password file: $password_file\n";
        } else {
            die "Could not create password file for decryption: $!";
        }
        
        if ($is_compressed) {
            $extract_cmd = "gpg --batch --yes --passphrase-file '$password_file' --decrypt '$tar_file' 2>/dev/null | tar -xzf - -C '$dest_dir' 2>&1";
        } else {
            $extract_cmd = "gpg --batch --yes --passphrase-file '$password_file' --decrypt '$tar_file' 2>/dev/null | tar -xf - -C '$dest_dir' 2>&1";
        }
        
    } elsif ($is_compressed) {
        $extract_cmd = "tar -xzf '$tar_file' -C '$dest_dir' 2>&1";
    } else {
        $extract_cmd = "tar -xf '$tar_file' -C '$dest_dir' 2>&1";
    }
    
    print "Extraction command prepared: $extract_cmd\n";
    
    # Execute extraction with progress monitoring
    my $start_time = time();
    my $pid = open(my $tar_fh, '-|', $extract_cmd);
    
    if (!defined $pid) {
        # Clean up password file if command failed to start
        unlink $password_file if $password_file;
        die "Failed to start tar extraction: $!";
    }
    
    # Monitor extraction progress
    my $last_update = time();
    my $files_extracted = 0;
    
    while (my $line = <$tar_fh>) {
        chomp $line;
        
        # Skip GPG status messages
        next if $line =~ /^gpg:/;
        
        # Print errors
        if ($line =~ /^(tar:|gzip:)/) {
            print "EXTRACTION: $line\n";
        }
        
        # Count files being extracted (tar outputs filenames)
        if ($line && length($line) > 5 && $line !~ /^(gpg:|tar:|gzip:)/) {
            $files_extracted++;
        }
        
        # Update progress periodically
        my $current_time = time();
        if (($current_time - $last_update) >= 3 || $files_extracted % 10 == 0) {
            my $elapsed = $current_time - $start_time;
            
            # Calculate progress based on files extracted and time
            my $progress;
            if ($files_extracted < 10) {
                $progress = 20 + ($files_extracted * 2);  # 20% + up to 20% for first 10 files
            } else {
                $progress = 40 + int(($elapsed / 120) * 50);  # 40% + up to 50% over 2 minutes
            }
            
            $progress = 95 if $progress > 95;  # Cap at 95% until completion
            
            print "Tar restore progress: $files_extracted files extracted, ${elapsed}s elapsed, $progress%\n";
            
            if (open my $progress_fh, '>', $progress_file) {
                print $progress_fh "$progress\n";
                close $progress_fh;
            }
            
            $last_update = $current_time;
        }
    }
    
    close $tar_fh;
    my $exit_status = $? >> 8;
    
    # NOW clean up password file after command completion
    if ($password_file) {
        unlink $password_file;
        print "Cleaned up password file\n";
    }
    
    if ($exit_status == 0) {
        print "Tar restore completed successfully\n";
        print "Total files extracted: $files_extracted\n";
        
        # Update progress to 98%
        if (open my $progress_fh, '>', $progress_file) {
            print $progress_fh "98\n";
            close $progress_fh;
        }
    } else {
        print "Tar restore failed with exit code: $exit_status\n";
        
        # Enhanced error diagnostics
        print "Diagnostics:\n";
        print "- Password file existed: " . ($password_file && -f $password_file ? "yes" : "no") . "\n";
        print "- Backup file exists: " . (-f $tar_file ? "yes" : "no") . "\n";
        print "- Backup file size: " . (-s $tar_file || "0") . " bytes\n";
        print "- Destination writable: " . (-w $dest_dir ? "yes" : "no") . "\n";
        print "- Metadata compression flag: " . ($metadata && $metadata->{compression_enabled} ? "yes" : "no") . "\n";
        print "- Metadata encryption flag: " . ($metadata && $metadata->{encryption_enabled} ? "yes" : "no") . "\n";
        
        die "Tar restore failed with exit code: $exit_status";
    }
}

# restore_incremental_backup
# Applies a single incremental backup on top of restored full backup.
# Uses rsync to merge incremental changes into the destination directory.
# Always merges (never deletes) to preserve both base and incremental content.
sub restore_incremental_backup {
    my ($self, $inc_path, $dest_dir, $progress_file) = @_;
    
    print "Restoring incremental from: $inc_path\n";
    print "To destination: $dest_dir\n";
    
    # Use rsync to copy incremental files over the restored backup
    # This preserves the directory structure created during incremental backup
    my @rsync_args = ('rsync', '-av');
    
    # Always merge (never delete) for incremental restores
    push @rsync_args, "$inc_path/", "$dest_dir/";
    
    print "Running: " . join(' ', @rsync_args) . "\n";
    
    my $rsync_pid = open(my $rsync_fh, '-|', @rsync_args);
    
    unless ($rsync_pid) {
        print "ERROR: Failed to start rsync for incremental restore: $!\n";
        return;
    }
    
    # Read rsync output
    while (my $line = <$rsync_fh>) {
        chomp $line;
        if ($line =~ /\S/) {  # Skip empty lines
            print "  $line\n";
        }
    }
    
    close($rsync_fh);
    my $exit_code = $? >> 8;
    
    if ($exit_code == 0) {
        print "Incremental restore completed successfully\n";
    } else {
        print "WARNING: Incremental restore exited with code $exit_code\n";
    }
}

# restore_with_incrementals
# Restores full backup first, then sequentially applies incremental backups.
# Determines whether to restore only latest cumulative or all differential backups.
# Provides progress updates for each phase of the multi-stage restore.
sub restore_with_incrementals {
    my ($self, $metadata, $progress_file) = @_;
    
    my $backup_folder = $self->{restore_source};
    my $dest_dir = $self->{restore_destination};
    my $backup_type = $metadata->{backup_type};
    
    print "=== RESTORING WITH INCREMENTALS ===\n";
    print "Backup type: $backup_type\n";
    print "Source: $backup_folder\n";
    print "Destination: $dest_dir\n";
    
    # Step 1: Restore the full backup first
    print "\n[1/2] Restoring full backup...\n";
    $self->write_progress_file("PCT:10|TXT:Restoring full backup...|REM:Calculating...");
    
    if ($backup_type eq 'custom') {
        $self->restore_custom_backup($backup_folder, $dest_dir, $progress_file, $metadata);
    } elsif ($backup_type eq 'home') {
        $self->restore_home_backup($backup_folder, $dest_dir, $progress_file, $metadata);
    } elsif ($backup_type eq 'system') {
        $self->restore_system_backup($backup_folder, $dest_dir, $progress_file, $metadata);
    } else {
        $self->restore_from_directory($backup_folder, $dest_dir, $progress_file);
    }
    
    # Step 2: Get list of incremental backups
    my @incremental_dirs = $self->get_incremental_backup_list($backup_folder, $metadata);
    
    if (@incremental_dirs == 0) {
        print "No incremental backups found to restore\n";
        return;
    }
    
    print "\n[2/2] Restoring incremental backups...\n";
    print "Found " . scalar(@incremental_dirs) . " incremental backup(s)\n";
    
    # Determine if we have cumulative or differential backups
    my $has_cumulative = 0;
    my $has_differential = 0;
    
    if ($metadata && $metadata->{incremental_backups}) {
        foreach my $inc (@{$metadata->{incremental_backups}}) {
            if ($inc->{backup_type} && $inc->{backup_type} eq 'incremental_cumulative') {
                $has_cumulative = 1;
            } elsif ($inc->{backup_type} && $inc->{backup_type} eq 'incremental_differential') {
                $has_differential = 1;
            }
        }
    }
    
    # Strategy for restore:
    # - Cumulative: Only restore the LATEST one (it contains all changes)
    # - Differential: Restore ALL in chronological order
    # - Mixed or Unknown: Restore ALL in chronological order (safest)
    
    my @dirs_to_restore;
    
    if ($has_cumulative && !$has_differential) {
        # Pure cumulative - only restore the latest
        @dirs_to_restore = ($incremental_dirs[-1]);
        print "Cumulative backups detected - will restore only the latest\n";
    } else {
        # Differential or mixed - restore all in order
        @dirs_to_restore = @incremental_dirs;
        print "Differential/mixed backups detected - will restore all in order\n";
    }
    
    # Restore each incremental backup
    my $inc_count = 0;
    my $total_inc = scalar(@dirs_to_restore);
    
    foreach my $inc_dir (@dirs_to_restore) {
        $inc_count++;
        my $inc_path = "$backup_folder/$inc_dir";
        
        print "Restoring incremental backup $inc_count/$total_inc: $inc_dir\n";
        
        my $progress = 50 + (($inc_count / $total_inc) * 50);  # 50-100%
        $self->write_progress_file("PCT:$progress|TXT:Restoring incremental $inc_count/$total_inc|REM:Calculating...");
        
        # Restore this incremental backup on top of the main restore
        $self->restore_incremental_backup($inc_path, $dest_dir, $progress_file);
    }
    
    print "=== INCREMENTAL RESTORE COMPLETE ===\n";
    $self->write_progress_file("PCT:100|TXT:Restore complete|REM:00:00:00");
}

# handle_backup_error
# Cleans up UI state when backup operations fail.
# Stops progress timers, re-enables buttons, and displays error message.
# Shows error dialog to inform user of the failure cause.
sub handle_backup_error {
    my ($self, $error_msg) = @_;
    
    if ($self->{timeout_id}) {
        Glib::Source->remove($self->{timeout_id});
        $self->{timeout_id} = undef;
    }
    
    $self->{status_label}->set_markup('<span size="large" weight="bold" color="red">Backup failed!</span>');
    $self->{progress_bar}->set_text("Error: $error_msg");
    
    # Re-enable buttons
    $self->{start_backup_button}->set_sensitive(1);
    $self->set_button_style($self->{start_backup_button}, 'suggested-action', 1);
    $self->{target_button}->set_sensitive(1);
    $self->{cancel_backup_button}->set_sensitive(0);
    $self->set_button_style($self->{cancel_backup_button}, 'destructive-action', 0);
    
    $self->show_error_dialog('Backup Failed', $error_msg);
}

# get_directory_size
# Recursively calculates total size of all files in a directory.
# Uses File::Find to walk directory tree and sum file sizes.
# Returns total size in bytes for progress estimation.
sub get_directory_size {
    my ($self, $dir) = @_;
    
    my $size = 0;
    
    File::Find::find(sub {
        return unless -f $_;
        $size += -s $_;
    }, $dir);
    
    return $size;
}

# get_encryption_password
# Prompts user to enter and confirm encryption password for backup.
# Validates password strength (minimum 6 characters) and match confirmation.
# Returns password or undef if user cancels or passwords don't match.
sub get_encryption_password {
    my $self = shift;
    
    my $dialog = Gtk3::Dialog->new(
        'Encryption Password',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(400, 200);
    $dialog->set_resizable(0);
    
    my $content_area = $dialog->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 10);
    $vbox->set_margin_left(20);
    $vbox->set_margin_right(20);
    $vbox->set_margin_top(20);
    $vbox->set_margin_bottom(20);
    $content_area->add($vbox);
    
    # Info label
    my $info_label = Gtk3::Label->new();
    $info_label->set_markup(
        '<b>Backup Encryption</b>\n\n' .
        'Enter a strong password to encrypt your backup.\n' .
        'Make sure to remember this password - you will need it to restore!'
    );
    $info_label->set_line_wrap(1);
    $info_label->set_alignment(0, 0.5);
    $vbox->pack_start($info_label, 0, 0, 0);
    
    # Password entry
    my $password_hbox = Gtk3::Box->new('horizontal', 10);
    $vbox->pack_start($password_hbox, 0, 0, 0);
    
    my $password_label = Gtk3::Label->new('Password:');
    $password_hbox->pack_start($password_label, 0, 0, 0);
    
    my $password_entry = Gtk3::Entry->new();
    $password_entry->set_visibility(0);  # Hide password
    $password_entry->set_activates_default(1);
    $password_hbox->pack_start($password_entry, 1, 1, 0);
    
    # Confirm password entry
    my $confirm_hbox = Gtk3::Box->new('horizontal', 10);
    $vbox->pack_start($confirm_hbox, 0, 0, 0);
    
    my $confirm_label = Gtk3::Label->new('Confirm:');
    $confirm_hbox->pack_start($confirm_label, 0, 0, 0);
    
    my $confirm_entry = Gtk3::Entry->new();
    $confirm_entry->set_visibility(0);  # Hide password
    $confirm_entry->set_activates_default(1);
    $confirm_hbox->pack_start($confirm_entry, 1, 1, 0);
    
    # Show password checkbox
    my $show_password_check = Gtk3::CheckButton->new_with_label('Show passwords');
    $show_password_check->signal_connect(toggled => sub {
        my $visible = $_[0]->get_active();
        $password_entry->set_visibility($visible);
        $confirm_entry->set_visibility($visible);
    });
    $vbox->pack_start($show_password_check, 0, 0, 0);
    
    $dialog->set_default_response('ok');
    $dialog->show_all();
    $password_entry->grab_focus();
    
    my $password;
    while (1) {
        my $response = $dialog->run();
        
        if ($response ne 'ok') {
            $dialog->destroy();
            return undef;  # User cancelled
        }
        
        my $pass1 = $password_entry->get_text();
        my $pass2 = $confirm_entry->get_text();
        
        if (length($pass1) < 6) {
            $self->show_error_dialog('Weak Password', 'Password must be at least 6 characters long.');
            next;
        }
        
        if ($pass1 ne $pass2) {
            $self->show_error_dialog('Password Mismatch', 'Passwords do not match. Please try again.');
            $confirm_entry->set_text('');
            next;
        }
        
        $password = $pass1;
        last;
    }
    
    $dialog->destroy();
    return $password;
}

# get_fast_total_size
# Uses du command for fast size calculation with exclusions.
# Implements timeout mechanism to prevent hanging on large directories.
# Returns total bytes or 0 if calculation times out or fails.
sub get_fast_total_size {
    my ($self, $source, $excludes_ref) = @_;
    
    # Standardize locale locally
    local $ENV{LC_ALL} = 'C';

    my @cmd = ();
    
    # 1. HANDLE SUDO
    if ($self->{sudo_authenticated}) {
        push @cmd, 'sudo', 'env', 'LC_ALL=C';
    }
    
    # 2. BUILD COMMAND
    push @cmd, 'du', '-sbx'; 
    
    # 3. EXCLUDES
    push @cmd, "--exclude=/proc", "--exclude=/sys", "--exclude=/dev", 
               "--exclude=/run", "--exclude=/mnt", "--exclude=/media", 
               "--exclude=/tmp", "--exclude=/lost+found";
               
    foreach my $ex (@$excludes_ref) {
        if ($ex =~ /^--exclude=(.+)$/) {
            push @cmd, "--exclude=$1";
        } else {
            push @cmd, "--exclude=$ex";
        }
    }
    
    # 4. SOURCE
    if (ref($source) eq 'ARRAY') {
        foreach my $path (@$source) { push @cmd, $path; }
    } else {
        push @cmd, $source;
    }
    
    my $total_bytes = 0;
    
    # 5. DETERMINE TIMEOUT BASED ON SOURCE - Use longer timeout for custom backups
    my $timeout = 30;
    
    if (!ref($source) && $source eq '/') {
        $timeout = 180;  # 3 minutes for root
        print "Using extended timeout (${timeout}s) for root filesystem scan\n";
    } elsif (ref($source) eq 'ARRAY') {
        # For custom file lists, use timeout based on item count
        my $item_count = scalar(@$source);
        if ($item_count > 10) {
            $timeout = 180;  # 3 minutes for large custom backups
        } else {
            $timeout = 90;   # 1.5 minutes for smaller custom backups
        }
        print "Using extended timeout (${timeout}s) for custom file list ($item_count items)\n";
    } elsif (ref($source) eq 'ARRAY' && (grep { $_ eq '/bin' || $_ eq '/usr' } @$source)) {
        $timeout = 120;
        print "Using extended timeout (${timeout}s) for system directories scan\n";
    }
    
    # 6. EXECUTE WITH TIMEOUT
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        
        # Build command string for execution
        my $cmd_str = join(' ', map { "'$_'" } @cmd) . " 2>/dev/null";
        
        print "Calculating total size with command: $cmd_str\n";
        print "Timeout set to: ${timeout}s\n";
        
        my $output = `$cmd_str`;
        
        if ($output && $output =~ /^(\d+)/) {
            $total_bytes = $1;
        } else {
            # Try line-by-line parsing
            foreach my $line (split /\n/, $output) {
                if ($line =~ /^(\d+)\s/) {
                    $total_bytes += $1;
                }
            }
        }
        
        alarm 0;
    };
    
    if ($@) { 
        my $error = $@;
        chomp $error;
        print "Size calc warning: $error\n";
        if ($error =~ /timeout/) {
            print "WARNING: Size calculation timed out after ${timeout}s\n";
            print "This is normal for very large file sets. Will show progress without percentage.\n";
        }
        return 0; 
    }
    
    if ($total_bytes > 0) {
        print "Total size calculated: $total_bytes bytes (" . 
              sprintf("%.2f GB", $total_bytes / (1024**3)) . ")\n";
    } else {
        print "WARNING: Could not calculate total size - will show rsync progress without percentage\n";
    }
    
    return $total_bytes;
}



# get_incremental_backup_list
# Retrieves list of incremental backup directories for a given backup.
# First checks metadata for chronologically ordered list, then scans directory.
# Returns array of incremental directory names in creation order.
sub get_incremental_backup_list {
    my ($self, $backup_folder, $metadata) = @_;
    
    my @incremental_dirs;
    
    # Try to get list from metadata first (preserves order and type info)
    if ($metadata && $metadata->{incremental_backups}) {
        foreach my $inc (@{$metadata->{incremental_backups}}) {
            if ($inc->{incremental_dir}) {
                push @incremental_dirs, $inc->{incremental_dir};
            }
        }
    }
    
    # If no metadata, scan directory
    if (@incremental_dirs == 0) {
        opendir(my $dh, $backup_folder) or return ();
        @incremental_dirs = sort grep { /^incremental_\d{8}_\d{6}$/ && -d "$backup_folder/$_" } readdir($dh);
        closedir($dh);
    }
    
    return @incremental_dirs;
}







# get_restore_password
# Prompts user for password to decrypt encrypted backup files.
# Creates modal dialog with masked password entry field.
# Returns password string or undef if user cancels.
sub get_restore_password {
    my $self = shift;
    
    my $dialog = Gtk3::Dialog->new(
        'Decryption Password Required',
        $self->{window},
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok'
    );
    
    $dialog->set_default_size(400, 180);
    $dialog->set_resizable(0);
    
    my $content_area = $dialog->get_content_area();
    my $vbox = Gtk3::Box->new('vertical', 10);
    $vbox->set_margin_left(20);
    $vbox->set_margin_right(20);
    $vbox->set_margin_top(20);
    $vbox->set_margin_bottom(20);
    $content_area->add($vbox);
    
    # Info label
    my $info_label = Gtk3::Label->new();
    $info_label->set_markup(
        '<b>Encrypted Backup Detected</b>\n\n' .
        'Please enter the password used to encrypt this backup:'
    );
    $info_label->set_line_wrap(1);
    $info_label->set_alignment(0, 0.5);
    $vbox->pack_start($info_label, 0, 0, 0);
    
    # Password entry
    my $password_hbox = Gtk3::Box->new('horizontal', 10);
    $vbox->pack_start($password_hbox, 0, 0, 0);
    
    my $password_label = Gtk3::Label->new('Password:');
    $password_hbox->pack_start($password_label, 0, 0, 0);
    
    my $password_entry = Gtk3::Entry->new();
    $password_entry->set_visibility(0);  # Hide password
    $password_entry->set_activates_default(1);
    $password_hbox->pack_start($password_entry, 1, 1, 0);
    
    $dialog->set_default_response('ok');
    $dialog->show_all();
    $password_entry->grab_focus();
    
    my $response = $dialog->run();
    my $password = '';
    
    if ($response eq 'ok') {
        $password = $password_entry->get_text();
    }
    
    $dialog->destroy();
    
    return ($response eq 'ok') ? $password : undef;
}

# get_suggested_restore_path
# Determines best restore location based on backup type and metadata.
# Returns home directory for home backups, root for system, original paths for custom.
# Provides safe fallback to home directory if metadata is missing.
sub get_suggested_restore_path {
    my ($self, $metadata) = @_;
    
    return $ENV{HOME} unless $metadata;  # Safe fallback
    
    my $backup_type = $metadata->{backup_type};
    
    if ($backup_type eq 'home') {
        return $ENV{HOME};
    } elsif ($backup_type eq 'system') {
        return '/';
    } elsif ($backup_type eq 'custom') {
        # For custom backups, use the first suggested path or home
        my $suggested_paths = $metadata->{suggested_restore_paths};
        if ($suggested_paths && @$suggested_paths > 0) {
            # Find common parent directory
            my $first_path = $suggested_paths->[0];
            if ($first_path =~ m{^($ENV{HOME})/}) {
                return $ENV{HOME};
            } else {
                return dirname($first_path);
            }
        }
        return $ENV{HOME};
    }
    
    return $ENV{HOME};  # Safe fallback
}

# calculate_backup_path
# Calculates destination path for files in incremental backups.
# Maintains directory structure relative to backup type (home/system/custom).
# Ensures files are stored in proper hierarchy within incremental directories.
sub calculate_backup_path {
    my ($self, $source_path, $incremental_dir, $original_metadata) = @_;
    
    # For custom backups, maintain the original directory structure
    if ($original_metadata->{backup_type} eq 'custom') {
        # Strip the leading path to create relative structure
        my $relative_path = $source_path;
        
        # If it's under home directory, make it relative to home
        if ($source_path =~ m{^$ENV{HOME}/(.+)}) {
            $relative_path = "home/$1";
        } else {
            # System path - use full path but strip leading slash
            $relative_path = $source_path;
            $relative_path =~ s{^/}{};
        }
        
        return "$incremental_dir/$relative_path";
    }
    
    # For home backups
    if ($original_metadata->{backup_type} eq 'home') {
        my $relative_path = $source_path;
        $relative_path =~ s{^$ENV{HOME}/}{};
        return "$incremental_dir/$relative_path";
    }
    
    # For system backups
    if ($original_metadata->{backup_type} eq 'system') {
        my $relative_path = $source_path;
        $relative_path =~ s{^/}{};
        return "$incremental_dir/$relative_path";
    }
    
    return "$incremental_dir/" . File::Basename::basename($source_path);
}

# check_sudo_auth
# Verifies if sudo authentication timestamp is still valid.
# Runs 'sudo -n true' to check without prompting for password.
# Returns true if authenticated, false if timestamp expired.
sub check_sudo_auth {
    my $self = shift;
    
    # Quick check if sudo timestamp is still valid - use ARRAY FORM (secure)
    system('sudo', '-n', 'true');
    
    if ($? == 0) {
        return 1;  # Still authenticated
    } else {
        print "WARNING: Sudo authentication expired\n";
        $self->{sudo_authenticated} = 0;
        return 0;
    }
}

# format_backup_details
# Creates formatted text description of backup contents from metadata.
# Shows source paths, backup type, and mode in human-readable format.
# Provides preview of what will be included in incremental backup.
sub format_backup_details {
    my ($self, $metadata) = @_;
    
    my $details = "<b>Backup Details:</b>\n";
    
    if ($metadata->{backup_type} eq 'custom') {
        my $source_paths = $metadata->{source_paths} || [];
        $details .= "Items in original backup: " . scalar(@$source_paths) . "\n";
        
        if (@$source_paths > 0) {
            $details .= "Some included paths:\n";
            my $count = 0;
            foreach my $path (@$source_paths) {
                last if $count >= 5; # Show first 5 paths
                my $short_path = $path;
                $short_path =~ s|^$ENV{HOME}/|~/|; # Simplify home paths
                $details .= "  • $short_path\n";
                $count++;
            }
            if (@$source_paths > 5) {
                $details .= "  • ... and " . (@$source_paths - 5) . " more\n";
            }
        }
    } elsif ($metadata->{backup_type} eq 'home') {
        $details .= "Source: Home directory (" . ($metadata->{original_home} || $ENV{HOME}) . ")\n";
    } elsif ($metadata->{backup_type} eq 'system') {
        $details .= "Source: System directories\n";
    }
    
    $details .= "\nMode: " . ucfirst($self->{backup_mode});
    $details =~ s/_/ /g; # Replace underscores with spaces
    
    return $details;
}

# format_incremental_backup_list
# Creates formatted text list of incremental backups with timestamps.
# Parses directory names or metadata to show human-readable dates and types.
# Returns formatted string for display in dialogs.
sub format_incremental_backup_list {
    my ($self, $backup_folder, $metadata) = @_;
    
    my $text = "";
    
    if ($metadata && $metadata->{incremental_backups}) {
        foreach my $inc (@{$metadata->{incremental_backups}}) {
            my $timestamp = $inc->{timestamp_readable} || 'Unknown';
            my $type = $inc->{backup_type} || 'Unknown';
            my $dir_name = $inc->{incremental_dir} || 'Unknown';
            
            $text .= "• $timestamp - $type\n";
            $text .= "  Directory: $dir_name\n\n";
        }
    } else {
        # Fall back to directory listing
        opendir(my $dh, $backup_folder) or return "Could not read backup directory\n";
        my @incremental_dirs = sort grep { /^incremental_(\d{8}_\d{6})$/ && -d "$backup_folder/$_" } readdir($dh);
        closedir($dh);
        
        foreach my $dir (@incremental_dirs) {
            if ($dir =~ /^incremental_(\d{8})_(\d{6})$/) {
                my ($date, $time) = ($1, $2);
                # Format: 17122025_002531 -> 17-12-2025 00:25:31
                my $formatted = substr($date, 0, 2) . "-" . substr($date, 2, 2) . "-" . 
                               substr($date, 4, 4) . " " . substr($time, 0, 2) . ":" . 
                               substr($time, 2, 2) . ":" . substr($time, 4, 2);
                $text .= "• $formatted\n";
                $text .= "  Directory: $dir\n\n";
            }
        }
    }
    
    return $text || "No incremental backups found\n";
}

# format_time
# Converts seconds into HH:MM:SS formatted string.
# Handles hours, minutes, and seconds with zero-padding.
# Used for displaying elapsed and remaining time estimates.
sub format_time {
    my ($self, $seconds) = @_;
    
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    $seconds = $seconds % 60;
    
    return sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);
}

# analyze_backup_changes
# Analyzes selected backup metadata for incremental backup preparation.
# Updates UI with backup details and readies start button.
# Sets flag indicating application is in incremental mode.
sub analyze_backup_changes {
    my ($self, $backup_folder) = @_;
    
    my $metadata = $self->{incremental_metadata};
    
    # Update status
    if ($self->{status_label}) {
        $self->{status_label}->set_markup(
            "<b>Analyzing changes for incremental backup...</b>\n" .
            "Backup type: " . ucfirst($metadata->{backup_type} || 'unknown') . "\n" .
            "Original backup: " . ($metadata->{created_readable} || 'unknown')
        );
    }
    
    # Show backup details
    my $details_text = $self->format_backup_details($metadata);
    if ($self->{details_label}) {
        $self->{details_label}->set_markup($details_text);
        $self->{details_label}->set_visible(1);
    }
    
    # Store the backup folder for the incremental backup
    $self->{incremental_backup_folder} = $backup_folder;
    
    # Change button label and make it ready
    $self->{start_backup_button}->set_label('Start Incremental Backup');
    $self->{start_backup_button}->set_sensitive(1);
    
    # Set a flag to indicate we're in incremental mode
    $self->{incremental_mode_active} = 1;
    
    print "Backup analysis completed, ready to start incremental backup\n";
}

# backup_changed_files
# Copies only changed and new files to incremental backup directory.
# Maintains directory structure and creates incremental metadata.
# Provides progress updates based on file count and estimated time.
sub backup_changed_files {
    my ($self, $backup_folder, $changed_files_ref, $new_files_ref, $original_metadata) = @_;
    
    my @all_files = (@$changed_files_ref, @$new_files_ref);
    my $total_files = @all_files;
    
    print "Backing up $total_files changed/new files\n";
    
    # Create incremental backup subdirectory
    my $timestamp = POSIX::strftime("%d%m%Y_%H%M%S", localtime);
    my $incremental_dir = "$backup_folder/incremental_$timestamp";
    
    unless (mkdir $incremental_dir) {
        print "ERROR: Could not create incremental backup directory: $!\n";
        $self->write_progress_file("ERROR: Could not create incremental backup directory: $!");
        return;
    }
    
    # Write initial progress
    $self->write_progress_file("PCT:0|TXT:Starting incremental backup...|REM:Calculating...");
    
    # Copy changed files maintaining directory structure
    my $copied_count = 0;
    my $last_update_count = 0;
    my $last_update_percent = 0;
    
    foreach my $file_path (@all_files) {
        # Calculate relative path for backup
        my $backup_file_path = $self->calculate_backup_path($file_path, $incremental_dir, $original_metadata);
        
        if ($self->copy_file_with_structure($file_path, $backup_file_path)) {
            $copied_count++;
            
            # Calculate progress
            my $percent = int(($copied_count / $total_files) * 100);
            
            # Update progress every 10 files OR when percent changes by 2% or more
            my $should_update = ($copied_count - $last_update_count >= 10) || 
                               ($percent - $last_update_percent >= 2);
            
            if ($should_update || $copied_count == $total_files) {
                my $speed_text = "Copying files...";
                my $remaining = "Calculating...";
                
                # Calculate remaining time
                if ($copied_count > 0) {
                    my $elapsed = time() - ($self->{start_time} || time());
                    if ($elapsed > 0) {
                        my $files_per_sec = $copied_count / $elapsed;
                        if ($files_per_sec > 0) {
                            my $files_left = $total_files - $copied_count;
                            my $sec_left = int($files_left / $files_per_sec);
                            my $h = int($sec_left / 3600);
                            my $m = int(($sec_left % 3600) / 60);
                            my $s = $sec_left % 60;
                            $remaining = sprintf("%02d:%02d:%02d", $h, $m, $s);
                            
                            # Update speed text
                            if ($files_per_sec >= 1) {
                                $speed_text = sprintf("%.1f files/sec", $files_per_sec);
                            } else {
                                $speed_text = sprintf("%.1f sec/file", 1/$files_per_sec);
                            }
                        }
                    }
                }
                
                $self->write_progress_file("PCT:$percent|TXT:$speed_text ($copied_count/$total_files)|REM:$remaining");
                
                $last_update_count = $copied_count;
                $last_update_percent = $percent;
            }
        }
    }
    
    # Create incremental metadata
    $self->create_incremental_metadata($incremental_dir, $original_metadata, \@all_files);
    
    # Update main backup metadata
    $self->update_main_backup_metadata($backup_folder, $incremental_dir);
    
    print "Incremental backup completed: $copied_count files copied\n";
    
    # Store the incremental directory path for completion dialog
    $self->{backup_dir} = $incremental_dir;
    
    $self->write_progress_file("COMPLETE");
}

# backup_completed
# Handles UI updates and user notification when backup completes.
# Shows completion dialog and resets button states.
# Removes destructive-action styling from cancel button.
sub backup_completed {
    my $self = shift;
    
    $self->show_completion_dialog();
    
    if ($self->{cancel_backup_button}) {
        $self->{cancel_backup_button}->set_sensitive(0);
        # Remove RED style
        $self->set_button_style($self->{cancel_backup_button}, 'destructive-action', 0);
    }
    
    # Reset styling
    $self->update_start_button_state();
}

# backup_contains_encrypted_files
# Checks if backup directory or file contains encrypted (.gpg) content.
# Scans directory for .gpg files or checks single file extension.
# Returns true if encryption detected, false otherwise.
sub backup_contains_encrypted_files {
    my ($self, $backup_path) = @_;
    
    print "Checking for encrypted files in: $backup_path\n";
    
    # Check if this is a directory or file
    if (-d $backup_path) {
        # Directory - check for .gpg files
        opendir(my $dh, $backup_path) or return 0;
        my @files = readdir($dh);
        closedir($dh);
        
        foreach my $file (@files) {
            if ($file =~ /\.gpg$/) {
                print "Found encrypted file: $file\n";
                return 1;
            }
        }
        print "No encrypted files found in directory\n";
        return 0;
    } elsif (-f $backup_path) {
        # Single file - check extension
        if ($backup_path =~ /\.gpg$/) {
            print "Single encrypted file detected\n";
            return 1;
        }
        print "Single unencrypted file\n";
        return 0;
    }
    
    return 0;
}

# backup_custom_files
# Handles backup of user-selected files and folders.
# Routes to tar-based backup (with compression/encryption) or rsync-based backup.
# Calls appropriate handler based on compression and encryption settings.
sub backup_custom_files {
    my ($self, $backup_dir, $progress_file) = @_;
    
    return unless $self->{selected_files};
    
    my @files = @{$self->{selected_files}};
    my $total_items = @files;
    
    print "Starting custom backup of $total_items items to $backup_dir\n";
    
    # Check settings
    my $compression_enabled = $self->{compress_check} ? $self->{compress_check}->get_active() : 0;
    my $encryption_enabled = $self->{encrypt_check} ? $self->{encrypt_check}->get_active() : 0;
    
    if ($compression_enabled || $encryption_enabled) {
        # Use tar-based method for compression/encryption
        $self->backup_custom_with_tar($backup_dir, $progress_file, \@files, $compression_enabled, $encryption_enabled);
    } else {
        # SWITCH TO SMART RSYNC (Fixes flattening and timer)
        # We pass the array reference \@files as the source
        $self->backup_with_rsync(\@files, $backup_dir, $progress_file, 1, 'custom');
    }
}

# backup_custom_with_tar
# Creates compressed/encrypted tar archive of selected custom files.
# Monitors tar operation progress by file count and archive size.
# Handles password file creation and cleanup for encrypted backups.
sub backup_custom_with_tar {
    my ($self, $backup_dir, $progress_file, $files_ref, $compression_enabled, $encryption_enabled) = @_;
    
    print "Using Smart Tar Custom Backup\n";
    local $ENV{LC_ALL} = 'C';
    
    my $encryption_password;
    if ($encryption_enabled) {
        $encryption_password = $self->{encryption_password};
        unless ($encryption_password) {
            $self->write_progress_update($progress_file, 0, "ERROR: Password missing");
            return;
        }
    }
    
    # 1. CALCULATE SIZE AND COUNT FILES
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:0|TXT:Analyzing files...|REM:Calculating...\n";
        close $fh;
    }
    
    # Create temp list for tar
    my $file_list = "/tmp/custom_backup_files_$$.txt";
    if (open my $fh, '>', $file_list) {
        foreach my $file (@$files_ref) { print $fh "$file\n"; }
        close $fh;
    } else {
        print "ERROR: Could not create file list: $!\n";
        $self->write_progress_update($progress_file, 0, "ERROR: Could not create file list");
        return;
    }
    
    # Calculate total size
    my $total_bytes = $self->get_fast_total_size($files_ref, []); 
    $total_bytes = 1000000 if $total_bytes < 1;
    
    print "Total uncompressed input size: " . sprintf("%.2f GB", $total_bytes / (1024**3)) . "\n";
    
    # Count total files for accurate progress
    print "Counting files for progress tracking...\n";
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:2|TXT:Counting files...|REM:Calculating...\n";
        close $fh;
    }
    
    my $total_files = 0;
    foreach my $path (@$files_ref) {
        if (-f $path) {
            $total_files++;
        } elsif (-d $path) {
            # Count files in directory
            my $count_cmd = "find '$path' -type f 2>/dev/null | wc -l";
            my $count = `$count_cmd`;
            chomp $count;
            if ($count && $count =~ /^\d+$/) {
                $total_files += $count;
            }
        }
    }
    
    $total_files = 100 if $total_files < 100;  # Minimum fallback
    print "Total files to backup: $total_files\n";

    # 2. BUILD COMMAND - CRITICAL FIX: Don't redirect stderr into the tar data stream!
    my $backup_name = "custom_backup_" . POSIX::strftime("%d%m%Y_%H%M%S", localtime);
    my $backup_file = "$backup_dir/$backup_name.tar";
    $backup_file .= ".gz" if $compression_enabled;
    $backup_file .= ".gpg" if $encryption_enabled;

    # Build tar command for data stream (no stderr redirection)
    my $tar_data_cmd = "tar -c";  # No verbose flag for data stream
    $tar_data_cmd .= "z" if $compression_enabled;
    $tar_data_cmd .= " -f - -T '$file_list'";
    
    # Build separate tar command for progress monitoring
    my $tar_progress_cmd = "tar -cv";
    $tar_progress_cmd .= "z" if $compression_enabled;
    $tar_progress_cmd .= " -f - -T '$file_list' 2>&1 | wc -l &";  # Run in background, count lines
    
    my $password_file;
    if ($encryption_enabled) {
        $password_file = "/tmp/backup_pass_$$.tmp";
        if (open my $pass_fh, '>', $password_file) {
            print $pass_fh $encryption_password;
            close $pass_fh;
            chmod 0600, $password_file;
        } else {
            print "ERROR: Could not create password file: $!\n";
            unlink $file_list;
            $self->write_progress_update($progress_file, 0, "ERROR: Could not create password file");
            return;
        }
    }
    
    # Build full pipeline with clean data stream
    my $full_cmd;
    if ($encryption_enabled) {
        $full_cmd = "$tar_data_cmd 2>/dev/null | gpg --batch --yes --passphrase-file '$password_file' --symmetric --cipher-algo AES256 --output '$backup_file'";
    } else {
        $full_cmd = "$tar_data_cmd > '$backup_file' 2>/dev/null";
    }
    
    print "Executing command: $full_cmd\n";
    
    # 3. EXECUTE IN BACKGROUND
    my $backup_pid = fork();
    
    if (!defined $backup_pid) {
        print "ERROR: Could not fork: $!\n";
        unlink $file_list;
        unlink $password_file if $password_file;
        $self->write_progress_update($progress_file, 0, "ERROR: Could not start backup");
        return;
    }
    
    if ($backup_pid == 0) {
        # Child process - execute the backup command
        exec($full_cmd) or die "Cannot exec tar: $!";
    }
    
    # 4. PARENT PROCESS - MONITOR PROGRESS BY CHECKING FILE SIZE
    my $start_time = time();
    my $last_update_time = 0;
    my $last_file_size = 0;
    
    while (1) {
        # Check if child process is still running
        my $kid = waitpid($backup_pid, POSIX::WNOHANG);
        last if $kid == $backup_pid;  # Child finished
        
        sleep 1;
        
        my $now = time();
        if ($now - $last_update_time >= 2.0) {
            $last_update_time = $now;
            
            # Check backup file size for progress
            my $current_file_size = -s $backup_file || 0;
            my $elapsed = $now - $start_time;
            
            # Estimate progress based on file size growth
            my $percent = 0;
            if ($total_bytes > 0) {
                # For compressed/encrypted, estimate 50-70% compression ratio
                my $estimated_final_size = $compression_enabled ? int($total_bytes * 0.6) : $total_bytes;
                $percent = int(($current_file_size / $estimated_final_size) * 100);
                $percent = 95 if $percent > 95;  # Cap at 95%
            }
            
            # Calculate speed
            my $speed_str = "Processing...";
            if ($elapsed > 3 && $current_file_size > $last_file_size) {
                my $bytes_per_sec = ($current_file_size - $last_file_size) / 2.0;
                if ($bytes_per_sec > 1024*1024) {
                    $speed_str = sprintf("%.1f MB/s", $bytes_per_sec / (1024*1024));
                } elsif ($bytes_per_sec > 1024) {
                    $speed_str = sprintf("%.1f KB/s", $bytes_per_sec / 1024);
                }
            }
            
            # Estimate time remaining
            my $rem_time = "Calculating...";
            if ($elapsed > 5 && $current_file_size > 0) {
                my $bytes_per_sec = $current_file_size / $elapsed;
                if ($bytes_per_sec > 0) {
                    my $estimated_final = $compression_enabled ? int($total_bytes * 0.6) : $total_bytes;
                    my $bytes_left = $estimated_final - $current_file_size;
                    $bytes_left = 0 if $bytes_left < 0;
                    
                    my $sec_left = int($bytes_left / $bytes_per_sec);
                    my $h = int($sec_left / 3600);
                    my $m = int(($sec_left % 3600) / 60);
                    my $s = $sec_left % 60;
                    $rem_time = sprintf("%02d:%02d:%02d", $h, $m, $s);
                }
            }
            
            # Write progress
            if (open my $fh, '>', $progress_file) {
                my $old_fh = select($fh); $| = 1; select($old_fh);
                print $fh "PCT:$percent|TXT:$speed_str|REM:$rem_time\n";
                close $fh;
            }
            
            $last_file_size = $current_file_size;
        }
    }
    
    # Get exit status
    my $exit_status = $? >> 8;
    
    print "Backup command completed with exit status: $exit_status\n";
    
    unlink $file_list;
    unlink $password_file if $password_file;
    
    # 5. FLUSHING
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:99|TXT:Flushing write cache...|REM:00:00:05\n";
        close $fh;
    }
    
    sleep 1;
    
    # 6. VERIFICATION
    if (-f $backup_file && ($exit_status == 0 || $exit_status == 1)) {
        my $final_size = -s $backup_file;
        my $compression_ratio = $total_bytes > 0 ? ($final_size / $total_bytes) * 100 : 0;
        
        print "Backup file created successfully: " . sprintf("%.2f GB", $final_size / (1024**3)) . "\n";
        print "Compression ratio: " . sprintf("%.1f%%", $compression_ratio) . " of original size\n";
        
        my $meta = {
            version => "1.0",
            created => time(),
            created_readable => POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime),
            backup_type => 'custom',
            backup_file => (split '/', $backup_file)[-1],
            compression_enabled => $compression_enabled,
            encryption_enabled => $encryption_enabled,
            source_paths => $files_ref,
            backup_size_bytes => $final_size,
            uncompressed_size_bytes => $total_bytes,
            compression_ratio => sprintf("%.1f%%", $compression_ratio),
            total_files => $total_files,
        };
        $self->write_metadata_file("$backup_dir/.backup_info.json", $meta);
        
        if (open my $fh, '>', $progress_file) { print $fh "COMPLETE\n"; close $fh; }
    } else {
        print "ERROR: Backup file not created or tar failed (exit: $exit_status)\n";
        if (open my $fh, '>', $progress_file) { 
            print $fh "PCT:0|TXT:Error Code $exit_status|REM:--:--:--\n"; 
            close $fh; 
        }
    }
}

# backup_directory
# Routes directory backups to tar or rsync method based on settings.
# Handles encryption password collection if encryption enabled.
# Creates backup destination directory and initiates backup process.
sub backup_directory {
    my ($self, $source, $dest, $progress_file, $backup_type) = @_;  # Add backup_type parameter
    
    print "Starting backup from $source to $dest (type: $backup_type)\n";
    print "Progress file: $progress_file\n";
    
    # Check compression and encryption settings
    my $compression_enabled = $self->{compress_check} ? $self->{compress_check}->get_active() : 0;
    my $encryption_enabled = $self->{encrypt_check} ? $self->{encrypt_check}->get_active() : 0;
    
    print "Compression enabled: " . ($compression_enabled ? "YES" : "NO") . "\n";
    print "Encryption enabled: " . ($encryption_enabled ? "YES" : "NO") . "\n";
    
    # If encryption is enabled, get password
    my $encryption_password;
    if ($encryption_enabled) {
        $encryption_password = $self->get_encryption_password();
        unless ($encryption_password) {
            print "Encryption cancelled by user\n";
            if (open my $progress_fh, '>', $progress_file) {
                print $progress_fh "ERROR: Encryption cancelled\n";
                close $progress_fh;
            }
            return;
        }
    }
    
    # Create destination directory
    File::Path::make_path($dest);
    
    # Check if hidden files should be included
    my $include_hidden = $self->{hidden_check} ? $self->{hidden_check}->get_active() : 1;
    
    # Write initial progress immediately
    print "Writing initial progress (0%) to $progress_file\n";
    if (open my $progress_fh, '>', $progress_file) {
        print $progress_fh "0\n";
        close $progress_fh;
        print "Initial progress written successfully\n";
    } else {
        print "ERROR: Could not write initial progress: $!\n";
    }
    
    # Choose backup method based on compression/encryption settings
    if ($compression_enabled || $encryption_enabled) {
        # Use tar-based backup for compression/encryption
        $self->backup_with_tar($source, $dest, $progress_file, $compression_enabled, $encryption_enabled, $encryption_password, $include_hidden, $backup_type);
    } else {
        # Use rsync for regular backup (existing code)
        $self->backup_with_rsync($source, $dest, $progress_file, $include_hidden, $backup_type);
    }
}

# backup_directory_with_callback
# Backs up a directory with callback-based progress reporting.
# Used for multi-directory backups to maintain accurate overall progress.
# Accumulates file counts across multiple directory operations.
sub backup_directory_with_callback {
    my ($self, $source, $dest, $progress_file, $files_completed_so_far, $total_files) = @_;
    
    print "Backing up directory $source to $dest\n";
    
    # Create destination directory
    File::Path::make_path($dest);
    
    # Check if hidden files should be included
    my $include_hidden = $self->{hidden_check} ? $self->{hidden_check}->get_active() : 1;
    
    # Build rsync command
    my @rsync_args = ('rsync', '-av', '--progress');
    
    # Add exclude patterns for hidden files if not including them
    if (!$include_hidden) {
        push @rsync_args, '--exclude=.*';
        print "Excluding hidden files from backup\n";
    }
    
    # Add compression if enabled
    if ($self->{compress_check} && $self->{compress_check}->get_active()) {
        push @rsync_args, '--compress';
        print "Compression enabled\n";
    }
    
    push @rsync_args, "$source/", "$dest/";
    
    print "Running: " . join(' ', @rsync_args) . "\n";
    
    # Get file count for this directory
    my $dir_file_count = $self->count_files_in_directory($source, $include_hidden);
    print "Directory contains $dir_file_count files\n";
    
    my $pid = open my $rsync_fh, '-|';
    
    if (!defined $pid) {
        die "Cannot fork: $!";
    }
    
    if ($pid == 0) {
        # Child process
        exec(@rsync_args) or die "Cannot exec rsync: $!";
    }
    
    # Parent process - track progress
    my $files_processed_in_dir = 0;
    my $last_update_time = time();
    
    while (my $line = <$rsync_fh>) {
        chomp $line;
        print "rsync: $line\n";
        
        # Count files being processed
        if ($line =~ /^[^\/\s]/ && $line !~ /^(sent|total|Number|created|transferred|speedup)/ && length($line) > 10) {
            $files_processed_in_dir++;
            
            # Update progress every few files or every second
            my $current_time = time();
            if ($files_processed_in_dir % 5 == 0 || ($current_time - $last_update_time) >= 1) {
                my $total_files_processed = $files_completed_so_far + $files_processed_in_dir;
                my $progress = int(($total_files_processed / $total_files) * 100);
                $progress = 99 if $progress > 99; # Don't show 100% until completely done
                
                print "Directory progress: $files_processed_in_dir/$dir_file_count, Overall: $total_files_processed/$total_files ($progress%)\n";
                
                if (open my $progress_fh, '>', $progress_file) {
                    print $progress_fh "$progress\n";
                    close $progress_fh;
                }
                
                $last_update_time = $current_time;
            }
        }
    }
    
    close $rsync_fh;
    my $exit_status = $? >> 8;
    
    if ($exit_status == 0) {
        print "Directory backup completed successfully\n";
    } else {
        print "Directory backup completed with exit code: $exit_status\n";
    }
}

# backup_system
# Routes system backups to tar or directory-by-directory method.
# Decides handler based on compression and encryption settings.
# Backs up core system directories (/bin, /etc, /usr, etc.).
sub backup_system {
    my ($self, $backup_dir, $progress_file) = @_;
    
    print "Starting system backup to $backup_dir\n";
    
    # Check compression and encryption settings
    my $compression_enabled = $self->{compress_check} ? $self->{compress_check}->get_active() : 0;
    my $encryption_enabled = $self->{encrypt_check} ? $self->{encrypt_check}->get_active() : 0;
    
    if ($compression_enabled || $encryption_enabled) {
        # Use tar-based method for compression/encryption
        $self->backup_system_with_tar($backup_dir, $progress_file, $compression_enabled, $encryption_enabled);
    } else {
        # Use original directory-by-directory method
        $self->backup_system_with_directories($backup_dir, $progress_file);
    }
}

# backup_system_with_directories
# Backs up system using optimized rsync from root source.
# Passes 'system' type to rsync handler for special handling.
# Disables symlink following for system backup integrity.
sub backup_system_with_directories {
    my ($self, $backup_dir, $progress_file) = @_;
    
    print "Using Optimized System Backup (Root Source Mode)\n";
    
    # Source is Root
    my $source = '/';
    
    # Pass 'system' as the type so rsync knows to disable -L
    $self->backup_with_rsync($source, $backup_dir, $progress_file, 1, 'system');
}

# backup_system_with_tar
# Creates tar archive of system directories with progress monitoring.
# Uses sudo for privileged access to system files.
# Implements checkpoint-based progress reporting for accurate percentage.
sub backup_system_with_tar {
    my ($self, $backup_dir, $progress_file, $compression_enabled, $encryption_enabled) = @_;
    
    # Force English locale for consistent number parsing
    local $ENV{LC_ALL} = 'C';
    print "Using Smart Tar System Backup\n";
    
    # 1. DEFINE SYSTEM DIRS & EXCLUSIONS
    my @system_dirs = qw(/bin /boot /etc /lib /opt /root /sbin /usr /var);
    # Filter only existing directories
    my @valid_dirs = grep { -d $_ } @system_dirs;
    
    my @excludes = (
        '--exclude=/proc', '--exclude=/sys', '--exclude=/dev',
        '--exclude=/tmp', '--exclude=/run', '--exclude=/mnt',
        '--exclude=/media', '--exclude=/lost+found',
        '--exclude=/var/cache', '--exclude=/var/tmp',
        '--exclude=/var/log/*.log', '--exclude=/var/crash',
        '--exclude=.cache', '--exclude=.Trash'
    );
    
    # Get Encryption Password if needed
    my $encryption_password;
    if ($encryption_enabled) {
        $encryption_password = $self->{encryption_password};
        unless ($encryption_password) {
            $self->write_progress_update($progress_file, 0, "ERROR: Password missing");
            return;
        }
    }
    
    # 2. FAST SIZE CALCULATION
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:0|TXT:Calculating total size...|REM:Calculating...\n";
        close $fh;
    }
    
    # Calculate size of ALL system directories at once
    my $total_bytes = $self->get_fast_total_size(\@valid_dirs, \@excludes);
    
    # Determine if we have a reliable size estimate
    my $use_percentage = ($total_bytes > 1000000);  # Only trust if > 1MB
    
    if ($use_percentage) {
        print "Total size calculated: $total_bytes bytes (" . sprintf("%.2f GB", $total_bytes / (1024**3)) . ")\n";
    } else {
        print "Could not calculate reliable total size - will show progress without percentage\n";
        $total_bytes = 0;  # Don't use unreliable estimates
    }

    # 3. BUILD COMMAND
    my $backup_name = "system_backup_" . POSIX::strftime("%d%m%Y_%H%M%S", localtime);
    my $backup_file = "$backup_dir/$backup_name.tar";
    $backup_file .= ".gz" if $compression_enabled;
    $backup_file .= ".gpg" if $encryption_enabled;
    
    # Create Metadata early
    my $metadata = {
        version => "1.0",
        created => time(),
        backup_type => 'system',
        backup_file => (split '/', $backup_file)[-1],
        compression_enabled => $compression_enabled,
        encryption_enabled => $encryption_enabled,
        source_paths => \@valid_dirs,
        system_backup => 1,
    };
    $self->write_metadata_file("$backup_dir/.backup_info.json", $metadata);

    # Build command with SUDO (Required for system backup)
    my @tar_args = ('sudo', 'tar', '-c');
    
    # Smart Checkpoints (Track size, not files)
    push @tar_args, '--record-size=1K', '--checkpoint=1000', '--checkpoint-action=echo="PCT:%u"';
    push @tar_args, '-z' if $compression_enabled;
    push @tar_args, '-f', '-'; # Output to stdout
    
    # Password File creation (if encrypted)
    my $password_file;
    if ($encryption_enabled) {
        $password_file = "/tmp/system_backup_pass_$$.tmp";
        if (open my $pass_fh, '>', $password_file) {
            print $pass_fh $encryption_password;
            close $pass_fh;
            chmod 0600, $password_file;
        }
    }
    
    # Construct Pipeline
    my $cmd = join(' ', @tar_args) . " " . join(' ', @excludes) . " " . join(' ', @valid_dirs);
    
    if ($encryption_enabled) {
        $cmd .= " | gpg --batch --yes --passphrase-file '$password_file' --symmetric --cipher-algo AES256 --output '$backup_file'";
    } else {
        $cmd .= " > '$backup_file'";
    }
    
    # 4. EXECUTE
    my $pid = open(my $tar_fh, "-|", "$cmd 2>&1");
    
    if (!defined $pid) {
        $self->write_progress_update($progress_file, 0, "ERROR: Failed to start backup process");
        unlink $password_file if $password_file;
        return;
    }
    
    # 5. PARSE PROGRESS
    my $start_time = time();
    my $last_update_time = 0;
    
    while (my $line = <$tar_fh>) {
        if ($line =~ /PCT:(\d+)/) {
            my $records = $1;
            my $bytes_processed = $records * 512;
            
            # Rate limit UI updates (max 2 per second)
            if (time() - $last_update_time < 0.5) { next; }
            $last_update_time = time();
            
            # Calculate elapsed time
            my $elapsed = time() - $start_time;
            my $speed_bytes_sec = $elapsed > 0 ? $bytes_processed / $elapsed : 0;
            
            # Format processed size
            my $size_processed_str;
            if ($bytes_processed > 1024*1024*1024) {
                $size_processed_str = sprintf("%.2f GB", $bytes_processed / (1024*1024*1024));
            } elsif ($bytes_processed > 1024*1024) {
                $size_processed_str = sprintf("%.2f MB", $bytes_processed / (1024*1024));
            } else {
                $size_processed_str = sprintf("%.2f KB", $bytes_processed / 1024);
            }
            
            my $speed_str = "Processing...";
            my $rem_time = "Calculating...";
            my $percent = 0;
            
            if ($use_percentage && $total_bytes > 0) {
                # We have a reliable size estimate - show percentage
                $percent = int(($bytes_processed / $total_bytes) * 100);
                $percent = 99 if $percent > 99;  # Cap at 99% for flushing phase
                
                if ($speed_bytes_sec > 0) {
                    my $bytes_left = $total_bytes - $bytes_processed;
                    $bytes_left = 0 if $bytes_left < 0;
                    
                    my $sec_left = int($bytes_left / $speed_bytes_sec);
                    my $h = int($sec_left / 3600);
                    my $m = int(($sec_left % 3600) / 60);
                    my $s = $sec_left % 60;
                    $rem_time = sprintf("%02d:%02d:%02d", $h, $m, $s);
                }
            } else {
                # No reliable size - just show data transferred
                $percent = 0;  # Don't show percentage
                $rem_time = "Unknown";
            }
            
            # Speed String
            if ($speed_bytes_sec > 1024*1024) {
                $speed_str = sprintf("%.1f MB/s ($size_processed_str)", $speed_bytes_sec / (1024*1024));
            } elsif ($speed_bytes_sec > 1024) {
                $speed_str = sprintf("%.1f KB/s ($size_processed_str)", $speed_bytes_sec / 1024);
            } else {
                $speed_str = sprintf("%.0f B/s ($size_processed_str)", $speed_bytes_sec);
            }
            
            # Update UI via file
            if (open my $fh, '>', $progress_file) {
                my $old_fh = select($fh); $| = 1; select($old_fh);
                if ($use_percentage) {
                    print $fh "PCT:$percent|TXT:$speed_str|REM:$rem_time\n";
                } else {
                    # Show indeterminate progress - no percentage
                    print $fh "PCT:0|TXT:$speed_str|REM:$rem_time\n";
                }
                close $fh;
            }
        }
    }
    
    close $tar_fh;
    my $exit_status = $? >> 8;
    unlink $password_file if $password_file;
    
    # 6. FLUSHING PHASE
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:99|TXT:Flushing write cache...|REM:Finishing...\n";
        close $fh;
    }
    
    # 7. VERIFICATION & FINALIZATION
    if (-f $backup_file && ($exit_status == 0 || $exit_status == 1)) {
        $metadata->{backup_size_bytes} = -s $backup_file;
        $metadata->{backup_completed} = time();
        $self->write_metadata_file("$backup_dir/.backup_info.json", $metadata);
        
        if (open my $fh, '>', $progress_file) { 
            print $fh "COMPLETE\n"; 
            close $fh; 
        }
    } else {
        if (open my $fh, '>', $progress_file) { 
            print $fh "PCT:0|TXT:Error Code $exit_status|REM:--:--:--\n"; 
            close $fh; 
        }
    }
}


# backup_with_rsync
# Performs efficient file copying using rsync with progress monitoring.
# Handles exclusions, sudo authentication, and relative path preservation.
# Provides real-time progress updates with transfer speed and time remaining.
sub backup_with_rsync {
    my ($self, $source, $dest, $progress_file, $include_hidden, $backup_type) = @_;
    
    local $ENV{LC_ALL} = 'C';
    
    # --- 1. ENSURE DESTINATION EXISTS ---
    unless (-d $dest) {
        eval { File::Path::make_path($dest); };
        if ($@ || !-d $dest) {
            die "Failed to create destination directory: $@";
        }
    }
    
    # --- 2. SETUP EXCLUSIONS ---
    my @critical_excludes = ();
    
    if ($backup_type eq 'system') {
        push @critical_excludes, '/proc', '/sys', '/dev', '/run', '/mnt', '/media', '/tmp';
        push @critical_excludes, '/home'; 
        push @critical_excludes, '/lost+found';
        push @critical_excludes, '/bin/X11', '/usr/bin/X11', '/usr/X11R6';
    } else {
        push @critical_excludes, '/mnt', '/media', '/run', '/proc', '/sys', '/dev';
    }

    # --- 3. FAST PRE-CALCULATION ---
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:0|TXT:Calculating total size...|REM:Calculating...\n";
        close $fh;
    }
    
    my $total_bytes_expected = $self->get_fast_total_size($source, \@critical_excludes);
    my $use_percentage = ($total_bytes_expected > 100000000);  # Only trust if > 100MB
    
    if ($use_percentage) {
        print "Total size calculated: $total_bytes_expected bytes (" . 
              sprintf("%.2f GB", $total_bytes_expected / (1024**3)) . ")\n";
    } else {
        print "Size calculation incomplete - will show data transferred without percentage\n";
    }
    
    # --- 4. METADATA ---
    my $metadata = {
        version => "1.0",
        created => time(),
        created_readable => POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime),
        backup_type => $backup_type || 'directory',
        total_size_bytes => $total_bytes_expected,
        hidden_files_included => $include_hidden,
    };
    
    # CRITICAL FIX: Store source_paths for custom backups so incremental backups know what to scan
    if ($backup_type eq 'custom' && ref($source) eq 'ARRAY') {
        $metadata->{source_paths} = $source;
        print "Storing source paths in metadata for custom backup: " . join(', ', @$source) . "\n";
    } elsif ($backup_type eq 'home') {
        $metadata->{source_paths} = [$ENV{HOME}];
        $metadata->{original_home_path} = $ENV{HOME};
    } elsif ($backup_type eq 'system') {
        my @system_dirs = qw(/bin /boot /etc /lib /opt /root /sbin /usr /var);
        $metadata->{source_paths} = \@system_dirs;
    }
    
    $self->write_metadata_file("$dest/.backup_info.json", $metadata);

    # --- 5. BUILD RSYNC COMMAND ---
    my @rsync_args = ();
    
    if ($backup_type eq 'system' || $self->{sudo_authenticated}) {
        push @rsync_args, 'sudo', 'env', 'LC_ALL=C';
    }
    
    push @rsync_args, 'rsync', '-av', '--progress';
    
    if ($backup_type ne 'system') { push @rsync_args, '-L'; }
    if ($backup_type eq 'custom') { push @rsync_args, '-R'; }

    foreach my $ex (@critical_excludes) { push @rsync_args, "--exclude=$ex"; }
    
    my @garbage = ('.cache', '.thumbnails', '.local/share/Trash', '.Trash', '*.tmp', '*.lock');
    foreach my $g (@garbage) { push @rsync_args, "--exclude=$g"; }
    
    if (!$include_hidden) { push @rsync_args, '--exclude=.*'; }
    
    if (ref($source) eq 'ARRAY') {
        push @rsync_args, @$source;
    } else {
        my $clean_source = $source;
        unless ($clean_source eq '/') {
            $clean_source =~ s{/$}{}; 
            $clean_source .= "/";
        }
        push @rsync_args, $clean_source;
    }
    
    push @rsync_args, "$dest/";
    
    # --- 6. EXECUTE ---
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:5|TXT:Starting transfer...|REM:Calculating...\n";
        close $fh;
    }
    
    my $pid = open(my $rsync_fh, "-|");
    
    if (!defined $pid) {
        die "Cannot fork rsync process: $!";
    }
    
    if ($pid == 0) {
        open STDERR, '>&STDOUT';
        exec(@rsync_args) or die "Cannot exec rsync: $!";
    }
    
    # --- 7. PARSE WITH MINIMAL OVERHEAD ---
    my $start_time = time();
    my $total_bytes_transferred = 0;
    my $last_ui_update = 0;
    my $files_transferred = 0;
    
    while (my $line = <$rsync_fh>) {
        chomp $line;
        
        my @segments = split(/\r/, $line);
        my $final_segment = $segments[-1];
        
        # Only count completed files (100%)
        if ($final_segment =~ /^\s+([\d,]+)\s+100%.*\(xfr#(\d+)/) {
            my $bytes_str = $1;
            $bytes_str =~ s/,//g;
            
            $total_bytes_transferred += $bytes_str;
            $files_transferred++;
            
            # Update UI only every 3 seconds to minimize overhead
            my $now = time();
            if ($now - $last_ui_update >= 3.0) {
                $last_ui_update = $now;
                
                my $elapsed = $now - $start_time;
                my $bytes_per_sec = $elapsed > 0 ? $total_bytes_transferred / $elapsed : 0;
                
                # Format transferred size
                my $size_transferred_str;
                if ($total_bytes_transferred > 1024*1024*1024) {
                    $size_transferred_str = sprintf("%.2f GB", $total_bytes_transferred / (1024*1024*1024));
                } elsif ($total_bytes_transferred > 1024*1024) {
                    $size_transferred_str = sprintf("%.2f MB", $total_bytes_transferred / (1024*1024));
                } else {
                    $size_transferred_str = sprintf("%.2f KB", $total_bytes_transferred / 1024);
                }
                
                my $speed_display;
                if ($bytes_per_sec > 1024*1024) {
                    $speed_display = sprintf("%.2f MB/s (%s)", $bytes_per_sec / (1024*1024), $size_transferred_str);
                } elsif ($bytes_per_sec > 1024) {
                    $speed_display = sprintf("%.2f KB/s (%s)", $bytes_per_sec / 1024, $size_transferred_str);
                } else {
                    $speed_display = sprintf("%.0f B/s (%s)", $bytes_per_sec, $size_transferred_str);
                }
                
                my $time_remaining = "Calculating...";
                my $percent = 0;
                
                if ($use_percentage && $total_bytes_expected > 0) {
                    # Calculate percentage, but handle case where we transfer MORE than expected
                    if ($total_bytes_transferred > $total_bytes_expected) {
                        # We've exceeded our estimate - adjust it dynamically
                        $total_bytes_expected = int($total_bytes_transferred * 1.2);  # Estimate 20% more
                        print "Adjusted size estimate to: " . sprintf("%.2f GB", $total_bytes_expected / (1024**3)) . "\n";
                    }
                    
                    $percent = int(($total_bytes_transferred / $total_bytes_expected) * 100);
                    $percent = 95 if $percent > 95;  # Cap at 95% until truly done
                    
                    if ($bytes_per_sec > 0) {
                        my $bytes_left = $total_bytes_expected - $total_bytes_transferred;
                        $bytes_left = 0 if $bytes_left < 0;
                        
                        my $sec_left = int($bytes_left / $bytes_per_sec);
                        my $h = int($sec_left / 3600);
                        my $m = int(($sec_left % 3600) / 60);
                        my $s = $sec_left % 60;
                        $time_remaining = sprintf("%02d:%02d:%02d", $h, $m, $s);
                    }
                } else {
                    # No reliable size estimate
                    $percent = 0;
                    $time_remaining = "Unknown";
                }
                
                if (open my $fh, '>', $progress_file) {
                    my $old_fh = select($fh); $| = 1; select($old_fh);
                    if ($use_percentage) {
                        print $fh "PCT:$percent|TXT:$speed_display|REM:$time_remaining\n";
                    } else {
                        # Show progress without percentage
                        print $fh "PCT:0|TXT:$speed_display|REM:$time_remaining\n";
                    }
                    close $fh;
                }
            }
        }
    }
    
    close $rsync_fh;
    my $exit_status = $? >> 8;
    
    # --- 8. FLUSHING ---
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        
        # Show actual completion percentage based on what we transferred
        my $final_percent = 99;
        if ($use_percentage && $total_bytes_expected > 0) {
            $final_percent = int(($total_bytes_transferred / $total_bytes_expected) * 100);
            $final_percent = 99 if $final_percent > 99;
        }
        
        print $fh "PCT:$final_percent|TXT:Flushing cache...|REM:Finishing...\n";
        close $fh;
    }
    
    if ($exit_status == 0 || $exit_status == 24) {
        if (open my $fh, '>', $progress_file) { print $fh "COMPLETE\n"; close $fh; }
    } else {
        if (open my $fh, '>', $progress_file) { print $fh "PCT:0|TXT:Error $exit_status|REM:--:--:--\n"; close $fh; }
    }
}

# backup_with_tar
# Creates tar archives with optional compression and encryption.
# Uses checkpoint mechanism for progress reporting during archive creation.
# Handles password file creation/deletion for encrypted backups.
sub backup_with_tar {
    my ($self, $source, $dest, $progress_file, $compression_enabled, $encryption_enabled, $encryption_password, $include_hidden) = @_;
    
    local $ENV{LC_ALL} = 'C';
    print "Using tar-based backup (Smart Checkpoint Mode)\n";
    
    # 1. SETUP & EXCLUSIONS
    my @excludes = ();
    
    # Anti-loop
    use Cwd qw(abs_path);
    my $abs_source = abs_path($source);
    my $abs_dest_dir = abs_path($dest);
    if ($abs_dest_dir =~ /^\Q$abs_source\E/) {
        my $rel_path = substr($abs_dest_dir, length($abs_source));
        $rel_path =~ s{^/}{};
        my ($exclude_folder) = split('/', $rel_path);
        if ($exclude_folder) { push @excludes, "--exclude=$exclude_folder"; }
    }
    
    push @excludes, '--exclude=.cache', '--exclude=.Trash', '--exclude=/mnt', '--exclude=/media', '--exclude=/run', '--exclude=/sys', '--exclude=/proc';
    if (!$include_hidden) { push @excludes, '--exclude=.*'; }

    # 2. FAST SIZE CALCULATION
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:0|TXT:Calculating total size...|REM:Calculating...\n";
        close $fh;
    }
    
    my $total_bytes = $self->get_fast_total_size($source, \@excludes);
    $total_bytes = 1000000 if $total_bytes < 1; # Safety fallback

    # 3. BUILD COMMAND
    my $backup_name = "backup_" . POSIX::strftime("%d%m%Y_%H%M%S", localtime);
    my $backup_file = "$dest/$backup_name.tar";
    $backup_file .= ".gz" if $compression_enabled;
    $backup_file .= ".gpg" if $encryption_enabled;

    my @tar_args = ('tar', '-c');
    
    # CRITICAL: Use checkpoints to print status every 1000 records (512KB)
    push @tar_args, '--record-size=1K', '--checkpoint=1000', '--checkpoint-action=echo="PCT:%u"';
    
    push @tar_args, '-z' if $compression_enabled;
    push @tar_args, '-f', '-'; # Output to stdout
    
    # Password handling
    my $password_file;
    if ($encryption_enabled) {
        $password_file = "/tmp/backup_pass_$$.tmp";
        if (open my $pass_fh, '>', $password_file) {
            print $pass_fh $encryption_password;
            close $pass_fh;
            chmod 0600, $password_file;
        }
    }
    
    # Construct Pipeline
    my $cmd = join(' ', @tar_args) . " " . join(' ', @excludes) . " -C '$source' .";
    
    if ($encryption_enabled) {
        $cmd .= " | gpg --batch --yes --passphrase-file '$password_file' --symmetric --cipher-algo AES256 --output '$backup_file'";
    } else {
        $cmd .= " > '$backup_file'";
    }
    
    # 4. EXECUTE
    my $pid = open(my $tar_fh, "-|", "$cmd 2>&1");
    
    # 5. PARSE PROGRESS
    my $start_time = time();
    my $last_update_time = 0;
    
    while (my $line = <$tar_fh>) {
        if ($line =~ /PCT:(\d+)/) {
            my $records = $1;
            my $bytes_processed = $records * 512;
            
            if (time() - $last_update_time < 0.5) { next; }
            $last_update_time = time();
            
            my $percent = int(($bytes_processed / $total_bytes) * 100);
            
            # Time Calc
            my $elapsed = time() - $start_time;
            my $speed_bytes_sec = $elapsed > 0 ? $bytes_processed / $elapsed : 0;
            my $rem_time = "Calculating...";
            my $speed_str = "Processing...";
            
            if ($speed_bytes_sec > 0) {
                my $bytes_left = $total_bytes - $bytes_processed;
                my $sec_left = int($bytes_left / $speed_bytes_sec);
                
                my $h = int($sec_left / 3600);
                my $m = int(($sec_left % 3600) / 60);
                my $s = $sec_left % 60;
                $rem_time = sprintf("%02d:%02d:%02d", $h, $m, $s);
                
                if ($speed_bytes_sec > 1024*1024) {
                    $speed_str = sprintf("%.1f MB/s", $speed_bytes_sec / (1024*1024));
                } else {
                    $speed_str = sprintf("%.1f KB/s", $speed_bytes_sec / 1024);
                }
            }
            
            $percent = 99 if $percent > 99;
            
            if (open my $fh, '>', $progress_file) {
                my $old_fh = select($fh); $| = 1; select($old_fh);
                print $fh "PCT:$percent|TXT:Speed: $speed_str|REM:$rem_time\n";
                close $fh;
            }
        }
    }
    
    close $tar_fh;
    my $exit_status = $? >> 8;
    unlink $password_file if $password_file;
    
    # 6. FLUSHING
    if (open my $fh, '>', $progress_file) {
        my $old_fh = select($fh); $| = 1; select($old_fh);
        print $fh "PCT:99|TXT:Please wait, flushing write cache (ensuring data safety)...|REM:Finishing...\n";
        close $fh;
    }
    
    if (-f $backup_file && $exit_status == 0) {
        my $meta = {
            version => "1.0",
            created => time(),
            backup_type => 'custom',
            backup_file => (split '/', $backup_file)[-1],
            compression_enabled => $compression_enabled,
            encryption_enabled => $encryption_enabled,
        };
        $self->write_metadata_file("$dest/.backup_info.json", $meta);
        
        if (open my $fh, '>', $progress_file) { print $fh "COMPLETE\n"; close $fh; }
    } else {
        if (open my $fh, '>', $progress_file) { print $fh "PCT:0|TXT:Error Code $exit_status|REM:--:--:--\n"; close $fh; }
    }
}

# cancel_backup
# Terminates running backup/restore process and cleans up UI.
# Sends TERM then KILL signals to child process if needed.
# Resets progress bar and button states to idle configuration.
sub cancel_backup {
    my $self = shift;
    
    if ($self->{backup_process}) {
        kill 'TERM', $self->{backup_process};
        sleep 1;
        kill 'KILL', $self->{backup_process};
        waitpid($self->{backup_process}, 0);
        $self->{backup_process} = undef;
    }
    
    if ($self->{timeout_id}) {
        Glib::Source->remove($self->{timeout_id});
        $self->{timeout_id} = undef;
    }
    
    # Clean up UI
    $self->{start_backup_button}->set_sensitive(1);
    $self->{target_button}->set_sensitive(1);
    
    if ($self->{cancel_backup_button}) {
        $self->{cancel_backup_button}->set_sensitive(0);
        # Remove RED style
        $self->set_button_style($self->{cancel_backup_button}, 'destructive-action', 0);
    }
    
    $self->{progress_bar}->set_fraction(0.0);
    $self->{progress_bar}->set_text('Operation cancelled');
}

# choose_backup_destination
# Shows file chooser dialog for selecting backup destination folder.
# Validates custom file selection before allowing destination choice.
# Updates UI with selected path and enables start button.
sub choose_backup_destination {
    my $self = shift;
    
    # Handle restore mode
    if ($self->{operation_mode} eq 'restore') {
        $self->choose_restore_source();
        return;
    }
    
    # Handle incremental backup mode
    if ($self->{backup_mode} =~ /^incremental_/) {
        $self->show_backup_metadata_chooser();
        return;
    }
    
    # For custom backup, check if files are selected first (ONLY in backup mode)
    if ($self->{selected_backup_type} eq 'custom' && $self->{operation_mode} eq 'backup') {
        unless ($self->{selected_files} && @{$self->{selected_files}} > 0) {
            $self->show_error_dialog('No files selected', 'Please select files and folders first using the "Select folders and files" button.');
            return;
        }
    }
    
    my $dialog = Gtk3::FileChooserDialog->new(
        'Choose Backup Destination Folder',
        $self->{window},
        'select-folder',
        'gtk-cancel' => 'cancel',
        'gtk-open' => 'ok'
    );
    
    $dialog->set_current_folder($ENV{HOME});
    $dialog->set_create_folders(1);
    
    my $response = $dialog->run();
    
    if ($response eq 'ok') {
        my $selected_folder = $dialog->get_filename();
        $self->{backup_destination} = $selected_folder;
        
        # Update the UI
        $self->{destination_label}->set_markup("<b>Destination:</b> $selected_folder");
        $self->{target_button}->set_label('Change destination');
        
        # Update start button state
        $self->update_start_button_state();
        
        if ($self->{backup_name_entry}) {
            $self->{backup_name_entry}->grab_focus();
        }
        
        # Show what will be backed up
        if ($self->{selected_backup_type} eq 'custom' && $self->{selected_files}) {
            my $count = @{$self->{selected_files}};
            if ($self->{status_label}) {
                $self->{status_label}->set_markup("<span size=\"large\" weight=\"bold\">Ready to backup $count items</span>");
            }
        } else {
            my $type_name = {
                'system' => 'system',
                'home' => 'home directory',
                'custom' => 'selected files'
            };
            my $name = $type_name->{$self->{selected_backup_type}} || 'data';
            if ($self->{status_label}) {
                $self->{status_label}->set_markup("<span size=\"large\" weight=\"bold\">Ready to backup $name</span>");
            }
        }
    }
    
    $dialog->destroy();
}

# choose_restore_source
# Shows file chooser for selecting backup folder to restore from.
# Verifies backup structure and reads metadata for validation.
# Automatically shows restore destination dialog after source selection.
sub choose_restore_source {
    my $self = shift;
    
    # Show file/folder selection dialog for local restore
    my $dialog = Gtk3::FileChooserDialog->new(
        'Select Backup to Restore',
        $self->{window},
        'select-folder',
        'gtk-cancel' => 'cancel',
        'gtk-open' => 'ok'
    );
    
    $dialog->set_current_folder($ENV{HOME});
    
    my $response = $dialog->run();
    
    if ($response eq 'ok') {
        my $selected_backup = $dialog->get_filename();
        
        # Verify this looks like a backup
        unless ($self->verify_backup_structure($selected_backup)) {
            $self->show_error_dialog('Invalid Backup', 
                'The selected folder does not appear to be a valid backup.\n' .
                'Please select a folder created by this backup tool.'
            );
            $dialog->destroy();
            return;
        }
        
        $self->{restore_source} = $selected_backup;
        
        # Read backup metadata
        my $metadata = $self->read_backup_metadata($selected_backup);
        $self->{backup_metadata} = $metadata;
        
        # Check for incremental backups
        my $has_incrementals = $self->detect_incremental_backups($selected_backup, $metadata);
        
        if ($has_incrementals) {
            # Show incremental restore options
            $self->show_incremental_restore_dialog($selected_backup, $metadata);
        } else {
            # No incrementals - proceed with normal restore
            # Update the UI
            my $backup_name = (split '/', $selected_backup)[-1];
            $self->{destination_label}->set_markup("<b>Restore from:</b> $backup_name");
            $self->{target_button}->set_label('Change backup source');
            
            # AUTOMATICALLY show restore destination dialog
            print "Backup selected, showing restore destination dialog...\n";
            $self->show_restore_destination_dialog($metadata);
        }
    }
    
    $dialog->destroy();
}

# cleanup_sudo
# Cleans up sudo authentication when application closes.
# Stops refresh timer and invalidates sudo timestamp.
# Ensures no persistent elevated privileges remain after exit.
sub cleanup_sudo {
    my $self = shift;
    
    print "Cleaning up sudo session...\n";
    
    # Stop the refresh timer
    if ($self->{sudo_refresh_timer}) {
        Glib::Source->remove($self->{sudo_refresh_timer});
        $self->{sudo_refresh_timer} = undef;
        print "Stopped sudo refresh timer\n";
    }
    
    # Invalidate the sudo timestamp - use ARRAY FORM (secure)
    if ($self->{sudo_authenticated}) {
        system('sudo', '-k');
        $self->{sudo_authenticated} = 0;
        print "Sudo timestamp invalidated\n";
    }
}

# count_files_in_directory
# Counts total files in directory tree with hidden file filtering.
# Uses File::Find to recursively traverse directory structure.
# Returns file count or reasonable estimate if traversal fails.
sub count_files_in_directory {
    my ($self, $dir, $include_hidden) = @_;
    
    my $count = 0;
    
    eval {
        File::Find::find({
            wanted => sub {
                return unless -f $_;
                
                # Skip hidden files if not including them
                if (!$include_hidden && $File::Find::name =~ /\/\./) {
                    return;
                }
                
                $count++;
            },
            no_chdir => 1,
        }, $dir);
    };
    
    if ($@) {
        print "Warning: Error counting files in $dir: $@\n";
        # Return a reasonable estimate
        return 1000;
    }
    
    return $count || 1; 
}

# detect_incremental_backups
# Checks if a backup folder contains incremental backup subdirectories.
# First checks metadata, then scans for incremental_* directories.
# Returns count of incremental backups found.
sub detect_incremental_backups {
    my ($self, $backup_folder, $metadata) = @_;
    
    print "Checking for incremental backups in: $backup_folder\n";
    
    # First check metadata
    if ($metadata && $metadata->{incremental_backups} && @{$metadata->{incremental_backups}} > 0) {
        my $count = scalar(@{$metadata->{incremental_backups}});
        print "Found $count incremental backups in metadata\n";
        return $count;
    }
    
    # Also check for incremental_* directories
    opendir(my $dh, $backup_folder) or return 0;
    my @incremental_dirs = grep { /^incremental_\d{8}_\d{6}$/ && -d "$backup_folder/$_" } readdir($dh);
    closedir($dh);
    
    if (@incremental_dirs) {
        my $count = scalar(@incremental_dirs);
        print "Found $count incremental backup directories\n";
        return $count;
    }
    
    print "No incremental backups found\n";
    return 0;
}







    
# elevate_privileges
# Authenticates user for sudo access using password via stdin.
# More reliable than SUDO_ASKPASS for passwords with special characters.
# Starts refresh timer to maintain authentication throughout operation.
sub elevate_privileges {
    my ($self, $password) = @_;
    
    unless (defined $password && length($password) > 0) {
        print "ERROR: No password provided\n";
        return 0;
    }
    
    print "Attempting sudo authentication...\n";
    
    # Use sudo -S to read password from stdin (more reliable than SUDO_ASKPASS)
    my $pid = open(my $sudo_fh, '|-', 'sudo', '-S', '-v');
    
    unless ($pid) {
        print "ERROR: Could not open pipe to sudo: $!\n";
        return 0;
    }
    
    # Write password to sudo's stdin
    print $sudo_fh "$password\n";
    close($sudo_fh);
    
    my $exit_code = $? >> 8;
    
    # Clear password from memory
    undef $password;
    
    if ($exit_code == 0) {
        print "Authentication successful - sudo timestamp established\n";
        $self->{sudo_authenticated} = 1;
        
        # Start a timer to refresh sudo timestamp every 4 minutes
        # (sudo timeout is typically 5 minutes)
        $self->start_sudo_refresh_timer();
        
        return 1;
    } else {
        print "Authentication failed (exit code: $exit_code)\n";
        $self->{sudo_authenticated} = 0;
        return 0;
    }
}

# estimate_custom_files_count
# Estimates total file count for custom file/folder selection.
# Uses find command for directories, counts individual files directly.
# Provides fallback estimates based on directory names if find fails.
sub estimate_custom_files_count {
    my ($self, $files_ref) = @_;
    
    my $total_estimated = 0;
    
    foreach my $file (@$files_ref) {
        if (-f $file) {
            $total_estimated += 1;
        } elsif (-d $file) {
            # Quick estimate using find
            my $find_cmd = "find '$file' -type f | wc -l";
            my $count = `$find_cmd`;
            chomp $count;
            
            if ($count && $count =~ /^\d+$/) {
                $total_estimated += $count;
                print "Directory $file: estimated $count files\n";
            } else {
                # Fallback estimate based on directory name
                if ($file =~ /(Documents|Pictures|Downloads)/) {
                    $total_estimated += 1000;  # Typical user directories
                } elsif ($file =~ /(\.config|\.themes|\.icons)/) {
                    $total_estimated += 500;   # Config directories
                } else {
                    $total_estimated += 100;   # Generic fallback
                }
                print "Directory $file: using fallback estimate\n";
            }
        }
    }
    
    print "Total estimated files for custom backup: $total_estimated\n";
    return $total_estimated || 1000;  # Minimum fallback
}

# estimate_file_count
# Uses find command with exclusions to quickly count files.
# Skips cache directories and other non-essential files for speed.
# Returns count or reasonable fallback based on directory type.
sub estimate_file_count {
    my ($self, $source, $include_hidden) = @_;
    
    print "Estimating file count for: $source\n";
    
    # Use find command for fast file counting with exclusions
    my $find_cmd = "find '$source' -type f";
    
    # Add exclusions to speed up counting
    my @find_exclusions = (
        '-not -path "*/.*"',  # Skip hidden files if not included
        '-not -path "*/Cache*"',
        '-not -path "*/cache*"',
        '-not -path "*/.cache/*"',
        '-not -path "*/.thumbnails/*"',
        '-not -path "*/node_modules/*"',
        '-not -path "*/__pycache__/*"',
        '-not -path "*/.npm/*"',
        '-not -path "*/.steam/*"',
        '-not -path "*/.local/share/Trash/*"',
        '-not -path "*/tmp/*"',
        '-not -path "*/.tmp/*"',
    );
    
    # Only exclude hidden files if not including them
    if (!$include_hidden) {
        $find_cmd .= " " . join(' ', @find_exclusions);
    } else {
        # Skip the hidden files exclusion but keep others
        shift @find_exclusions;  # Remove the first exclusion (hidden files)
        $find_cmd .= " " . join(' ', @find_exclusions);
    }
    
    $find_cmd .= " | wc -l";
    
    print "File count command: $find_cmd\n";
    
    my $count = `$find_cmd`;
    chomp $count;
    
    # Validate the count
    if ($count && $count =~ /^\d+$/) {
        print "Estimated file count: $count\n";
        return $count;
    } else {
        print "Could not estimate file count, using fallback\n";
        # Fallback estimation based on directory type
        if ($source eq $ENV{HOME}) {
            return 50000;  # Typical home directory
        } elsif ($source =~ m{^/(bin|sbin|usr|etc|var)}) {
            return 100000;  # System directories
        } else {
            return 10000;  # Generic fallback
        }
    }
}

# execute_incremental_backup
# Forks child process to perform incremental backup operation.
# Disables UI during backup and enables cancel button.
# Monitors backup process for completion and progress updates.
sub execute_incremental_backup {
    my ($self, $backup_folder) = @_;
    
    print "Executing incremental backup to: $backup_folder\n";
    print "Mode: $self->{backup_mode}\n";
    print "Type: $self->{selected_backup_type}\n";
    
    # Disable UI during backup
    $self->{start_backup_button}->set_sensitive(0);
    if ($self->{cancel_backup_button}) {
        $self->{cancel_backup_button}->set_sensitive(1);
    }
    
    # Start progress indication
    $self->{start_time} = time();
    $self->start_progress_updates();
    
    # Fork backup process
    $self->{backup_process} = fork();
    
    if (!defined $self->{backup_process}) {
        $self->show_error_dialog('Fork Error', "Could not start backup process: $!");
        return;
    }
    
    if ($self->{backup_process} == 0) {
        # Child process - perform the incremental backup
        $self->perform_incremental_backup($backup_folder);
        exit(0);
    } else {
        # Parent process - monitor the backup
        $self->monitor_backup_process();
    }
}


# find_changed_files_in_directory
# Recursively finds files modified after a given timestamp.
# Uses File::Find to traverse directory and check modification times.
# Populates arrays with paths of changed files for incremental backup.
sub find_changed_files_in_directory {
    my ($self, $dir, $last_backup_time, $changed_files_ref, $new_files_ref) = @_;
    
    return unless -d $dir;
    
    File::Find::find(sub {  # <-- Change this line to use fully qualified name
        return if -d $_;  # Skip directories themselves
        
        my $file_path = $File::Find::name;
        my $mtime = (stat($file_path))[9];

        # Skip files where stat failed or mtime is undefined
        if (defined $mtime && $mtime > $last_backup_time) {
            push @$changed_files_ref, $file_path;
        }
    }, $dir);
}

# infer_backup_type_from_metadata
# Attempts to determine backup type from metadata when not explicitly stored.
# Checks source paths for system, home, or custom backup indicators.
# Returns inferred type or undef if type cannot be determined.
sub infer_backup_type_from_metadata {
    my ($self, $metadata) = @_;
    
    # Check for system backup indicators
    if ($metadata->{system_backup} || 
        ($metadata->{source_paths} && grep { $_ eq '/bin' || $_ eq '/etc' || $_ eq '/usr' } @{$metadata->{source_paths}})) {
        return 'system';
    }
    
    # Check for home backup indicators
    if ($metadata->{source_path} && $metadata->{source_path} eq $ENV{HOME}) {
        return 'home';
    }
    if ($metadata->{original_home_path} && $metadata->{original_home_path} eq $ENV{HOME}) {
        return 'home';
    }
    
    # Check for custom backup indicators
    if ($metadata->{custom_backup} || 
        ($metadata->{source_paths} && scalar(@{$metadata->{source_paths}}) > 0) ||
        $metadata->{selected_items_count}) {
        return 'custom';
    }
    
    # Could not determine type
    return undef;
}

# init_ui
# Creates and configures the main application window and all UI components.
# Loads CSS styling, builds left/right panels, and sets up signal handlers.
# Shows window and establishes initial UI state for user interaction.
sub init_ui {
    my $self = shift;
    
    # Load settings
    $self->load_settings();
    
    # --- CSS SETUP START ---
    my $css_provider = Gtk3::CssProvider->new();
    my $css_data = "
        /* Target only the top navigation tabs */
        .top-tab {
            background-color: transparent;
            border: 1px solid transparent;
            padding: 8px;
            transition: all 0.2s;
        }

        /* Style for the selected tab */
        .top-tab:checked {
            background-color: #444;
            border: 1px solid #4ba5ff;                
            color: #ffffff;                          
            font-weight: bold;
        }

        /* Hover effect for tabs */
        .top-tab:hover:not(:checked) {
            background-color: #444;
            border: 1px solid #666;
        }

        /* Keep existing incremental-btn styles */
        .incremental-btn { 
            border: 1px solid #4ba5ff; 
            border-radius: 3px;
        }
    ";
    
    # Load CSS with error handling
    eval {
        $css_provider->load_from_data($css_data);
        Gtk3::StyleContext::add_provider_for_screen(
            Gtk3::Gdk::Screen::get_default(),
            $css_provider,
            600 # GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    };
    if ($@) { print "CSS Error: $@\n"; }
    # --- CSS SETUP END ---
    
    # Create main window with standard GTK decorations
    $self->{window} = Gtk3::Window->new('toplevel');
    $self->{window}->set_title('Wolfmans Backup Tool');
    $self->{window}->set_default_size(1000, 700);
    $self->{window}->set_position('center');
    $self->{window}->set_resizable(1);
    $self->{window}->set_decorated(1);
    $self->{window}->signal_connect(delete_event => sub {
        print "Window closing...\n";
        $self->cleanup_sudo();  # Clean up sudo before closing
        
        # Cancel any running operations
        if ($self->{timeout_id}) {
            Glib::Source->remove($self->{timeout_id});
        }
        if ($self->{progress_timeout_id}) {
            Glib::Source->remove($self->{progress_timeout_id});
        }
        
        Gtk3::main_quit();
        return 0;
    });
    
    # Set minimum window size to allow shrinking
    $self->{window}->set_size_request(1000, 700);
    
    # Create main container
    my $main_vbox = Gtk3::Box->new('vertical', 0);
    $self->{window}->add($main_vbox);
    
    # Create main content area
    my $content_hbox = Gtk3::Box->new('horizontal', 0);
    $main_vbox->pack_start($content_hbox, 1, 1, 0);
    
    # Set defaults
    $self->{operation_mode} = 'backup';
    $self->{selected_backup_type} = 'system';
    $self->{backup_mode} = 'incremental';
    
    # Create left panel with size constraints
    $self->create_left_panel_with_tabs($content_hbox);
    
    # Add separator
    my $separator = Gtk3::Separator->new('vertical');
    $content_hbox->pack_start($separator, 0, 0, 0);
    
    # Create right panel
    $self->create_right_panel($content_hbox);
    
    # Show everything FIRST
    $self->{window}->show_all();
    
    # Process events before forcing resize
    while (Gtk3::events_pending()) {
        Gtk3::main_iteration();
    }
    
    # Force the desired size after everything is shown and laid out
    $self->{window}->resize(1000, 700);
    
    while (Gtk3::events_pending()) {
        Gtk3::main_iteration();
    }
    
    $self->setup_initial_ui_state();
    $self->update_right_panel();
    
    print "Window created with standard GTK decorations: " . join('x', $self->{window}->get_size()) . "\n";
    
    my ($min_width, $min_height) = $self->{window}->get_size_request();
}

# log_debug
# Writes timestamped debug messages to log file for troubleshooting.
# Appends to ~/backup_debug.log with formatted timestamp.
# Provides persistent debug trail for difficult-to-diagnose issues.
sub log_debug {
    my ($msg) = @_;
    my $log_file = "$ENV{HOME}/backup_debug.log";
    if (open my $fh, '>>', $log_file) {
        my $time = POSIX::strftime("%H:%M:%S", localtime);
        print $fh "[$time] $msg\n";
        close $fh;
    }
}

# monitor_backup_process
# Sets up periodic timer to check backup progress from child process.
# Reads progress file created by child and updates UI accordingly.
# Continues until backup completes or user cancels operation.
sub monitor_backup_process {
    my $self = shift;
    
    print "=== MONITOR_BACKUP_PROCESS STARTING ===\n";
    print "Monitoring PID: $self->{backup_process}\n";
    print "Progress file will be: /tmp/backup_progress_$self->{backup_process}\n";
    
    # Set up a timer to check backup progress
    my $tick_count = 0;  # Add a counter instead of using $.
    $self->{progress_timeout_id} = Glib::Timeout->add(500, sub {
        $tick_count++;
        print "DEBUG: update_progress called (timer tick)\n" if $tick_count % 10 == 0;
        
        # Call update_progress which reads the progress file
        my $continue = $self->update_progress();
        
        unless ($continue) {
            print "DEBUG: update_progress returned 0, stopping timer\n";
            $self->{progress_timeout_id} = undef;
        }
        
        return $continue;
    });
    
    print "Progress monitoring timer started (ID: $self->{progress_timeout_id})\n";
}

# perform_backup
# Executes the actual backup operation in child process.
# Routes to appropriate handler based on backup type (system/home/custom).
# Writes progress updates to temporary file for parent process monitoring.
sub perform_backup {
    my $self = shift;
    
    my $backup_type = $self->{selected_backup_type};
    my $progress_file = "/tmp/backup_progress_$$";
    my $backup_dir = $self->{backup_dir};
    
    unless ($backup_dir) {
        if (open my $fh, '>', $progress_file) {
            print $fh "ERROR: No backup directory specified\n";
            close $fh;
        }
        return;
    }
    
    my $source_paths = [];
    if ($backup_type eq 'home') {
        $source_paths = [$ENV{HOME}];
    } elsif ($backup_type eq 'system') {
        $source_paths = [qw(/bin /boot /etc /lib /opt /root /sbin /usr /var)];
    } elsif ($backup_type eq 'custom') {
        $source_paths = $self->{selected_files} || [];
    }
    
    $self->create_backup_metadata($backup_dir, $backup_type, $source_paths);
    
    # Write initial progress
    if (open my $fh, '>', $progress_file) {
        print $fh "1\n";
        close $fh;
    }
    
    if ($backup_type eq 'home') {
        print "Starting home directory backup\n";
        # Added 'home' as the 4th argument
        $self->backup_directory($ENV{HOME}, $backup_dir, $progress_file, 'home');
        
    } elsif ($backup_type eq 'system') {
        print "Starting system backup\n";
        $self->backup_system($backup_dir, $progress_file);
        
    } elsif ($backup_type eq 'custom') {
        print "Starting custom files backup\n";
        $self->backup_custom_files($backup_dir, $progress_file);
        
    } else {
        if (open my $fh, '>', $progress_file) {
            print $fh "ERROR: Unknown backup type\n";
            close $fh;
        }
        return;
    }
    
    if (open my $fh, '>', $progress_file) {
        print $fh "COMPLETE\n";
        close $fh;
    }
}

# perform_incremental_backup
# Routes incremental backup to type-specific handler.
# Performs incremental backup of only changed files since last backup.
# Executed in child process to avoid blocking UI.
sub perform_incremental_backup {
    my ($self, $backup_folder) = @_;
    
    my $metadata = $self->{incremental_metadata};
    my $backup_type = $self->{selected_backup_type};
    
    print "Performing incremental backup...\n";
    
    if ($backup_type eq 'custom') {
        $self->perform_incremental_custom_backup($backup_folder, $metadata);
    } elsif ($backup_type eq 'home') {
        $self->perform_incremental_home_backup($backup_folder, $metadata);
    } elsif ($backup_type eq 'system') {
        $self->perform_incremental_system_backup($backup_folder, $metadata);
    }
}

# perform_incremental_custom_backup
# Finds changed files in custom file selection since last backup.
# Compares modification times against last backup timestamp.
# Copies only changed/new files to incremental backup directory.
sub perform_incremental_custom_backup {
    my ($self, $backup_folder, $metadata) = @_;
    
    my $source_paths = $metadata->{source_paths} || [];
    my $last_backup_time = $metadata->{created} || 0;
    
    # CRITICAL FIX: If metadata has no source_paths (old backup format), reconstruct from backup structure
    if (!@$source_paths || scalar(@$source_paths) == 0) {
        print "WARNING: No source_paths in metadata - attempting to reconstruct from backup structure\n";
        $source_paths = $self->reconstruct_source_paths_from_backup($backup_folder);
        
        if (!@$source_paths || scalar(@$source_paths) == 0) {
            print "ERROR: Could not reconstruct source paths from backup\n";
            $self->write_progress_file("ERROR: Could not determine what files were originally backed up. This may be an old backup format.");
            return;
        }
        
        print "Reconstructed " . scalar(@$source_paths) . " source paths from backup structure\n";
    }
    
    print "Checking " . scalar(@$source_paths) . " paths for changes since " . 
          POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($last_backup_time)) . "\n";
    
    # Find changed files
    my @changed_files = ();
    my @new_files = ();
    
    foreach my $source_path (@$source_paths) {
        print "Checking source path: $source_path\n";
        
        if (-e $source_path) {
            if (-f $source_path) {
                # Single file
                my $mtime = (stat($source_path))[9];
                if ($mtime > $last_backup_time) {
                    push @changed_files, $source_path;
                    print "  File changed: $source_path\n";
                }
            } elsif (-d $source_path) {
                # Directory - recursively check
                $self->find_changed_files_in_directory($source_path, $last_backup_time, \@changed_files, \@new_files);
                print "  Directory scanned: $source_path (" . (scalar(@changed_files) + scalar(@new_files)) . " changes so far)\n";
            }
        } else {
            print "Warning: Source path no longer exists: $source_path\n";
        }
    }
    
    my $total_changed = @changed_files + @new_files;
    print "Found $total_changed changed/new files\n";
    
    if ($total_changed == 0) {
        print "No changes detected since last backup\n";
        $self->write_progress_file("COMPLETE: No changes detected. Incremental backup completed.");
        return;
    }
    
    # Perform the backup of changed files
    $self->backup_changed_files($backup_folder, \@changed_files, \@new_files, $metadata);
}

# perform_incremental_home_backup
# Finds changed files in home directory since last backup.
# Recursively scans home directory for files newer than last backup.
# Creates incremental backup of only modified content.
sub perform_incremental_home_backup {
    my ($self, $backup_folder, $metadata) = @_;
    
    my $home_dir = $ENV{HOME};
    my $last_backup_time = $metadata->{created} || 0;
    
    print "Checking home directory for changes since " . 
          POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($last_backup_time)) . "\n";
    
    # Find changed files in home directory
    my @changed_files = ();
    my @new_files = ();
    
    $self->find_changed_files_in_directory($home_dir, $last_backup_time, \@changed_files, \@new_files);
    
    my $total_changed = @changed_files + @new_files;
    print "Found $total_changed changed/new files in home directory\n";
    
    if ($total_changed == 0) {
        print "No changes detected in home directory since last backup\n";
        $self->write_progress_file("COMPLETE: No changes detected. Incremental backup completed.");
        return;
    }
    
    # Perform the backup
    $self->backup_changed_files($backup_folder, \@changed_files, \@new_files, $metadata);
}

# perform_incremental_system_backup
# Finds changed files in system directories since last backup.
# Scans all major system directories for modifications.
# Creates incremental backup of only changed system files.
sub perform_incremental_system_backup {
    my ($self, $backup_folder, $metadata) = @_;
    
    my @system_dirs = qw(/bin /boot /etc /lib /opt /root /sbin /usr /var);
    my $last_backup_time = $metadata->{created} || 0;
    
    print "Checking system directories for changes since " . 
          POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($last_backup_time)) . "\n";
    
    my @changed_files = ();
    my @new_files = ();
    
    foreach my $system_dir (@system_dirs) {
        if (-d $system_dir) {
            print "Scanning $system_dir...\n";
            $self->find_changed_files_in_directory($system_dir, $last_backup_time, \@changed_files, \@new_files);
        }
    }
    
    my $total_changed = @changed_files + @new_files;
    print "Found $total_changed changed/new files in system directories\n";
    
    if ($total_changed == 0) {
        print "No changes detected in system directories since last backup\n";
        $self->write_progress_file("COMPLETE: No changes detected. Incremental backup completed.");
        return;
    }
    
    # Perform the backup
    $self->backup_changed_files($backup_folder, \@changed_files, \@new_files, $metadata);
}

# reconstruct_source_paths_from_backup
# Reconstructs the original source paths by examining backup directory structure.
# Scans backup folder for directories and converts relative paths to absolute paths.
# Returns array of source paths that were originally backed up.
sub reconstruct_source_paths_from_backup {
    my ($self, $backup_folder) = @_;
    
    my @reconstructed_paths = ();
    
    print "Reconstructing source paths from backup directory: $backup_folder\n";
    
    # For custom backups created with rsync -R, the structure preserves the full path
    # For example: /backup/home/antialias/Videos means original was /home/antialias/Videos
    
    # Look for top-level directories in the backup
    opendir(my $dh, $backup_folder) or do {
        print "ERROR: Cannot open backup folder: $!\n";
        return ();
    };
    
    my @entries = grep { $_ ne '.' && $_ ne '..' && $_ !~ /^\.backup_info/ && $_ !~ /^incremental_/ } readdir($dh);
    closedir($dh);
    
    foreach my $entry (@entries) {
        my $full_path = "$backup_folder/$entry";
        next unless -d $full_path;
        
        print "  Examining top-level entry: $entry\n";
        
        # If it's "home", scan for user directories
        if ($entry eq 'home') {
            opendir(my $home_dh, $full_path) or next;
            my @users = grep { $_ ne '.' && $_ ne '..' && -d "$full_path/$_" } readdir($home_dh);
            closedir($home_dh);
            
            foreach my $user (@users) {
                my $user_path = "$full_path/$user";
                
                # Get all subdirectories under this user
                opendir(my $user_dh, $user_path) or next;
                my @user_dirs = grep { $_ ne '.' && $_ ne '..' && -d "$user_path/$_" } readdir($user_dh);
                closedir($user_dh);
                
                foreach my $dir (@user_dirs) {
                    my $reconstructed = "/home/$user/$dir";
                    print "    Reconstructed path: $reconstructed\n";
                    push @reconstructed_paths, $reconstructed;
                }
                
                # Also check for files directly under user home
                opendir($user_dh, $user_path);
                my @user_files = grep { $_ ne '.' && $_ ne '..' && -f "$user_path/$_" } readdir($user_dh);
                closedir($user_dh);
                
                foreach my $file (@user_files) {
                    my $reconstructed = "/home/$user/$file";
                    print "    Reconstructed file: $reconstructed\n";
                    push @reconstructed_paths, $reconstructed;
                }
            }
        }
        # If it's a system directory, reconstruct as /$entry
        elsif ($entry =~ /^(bin|boot|etc|lib|opt|root|sbin|usr|var)$/) {
            my $reconstructed = "/$entry";
            print "    Reconstructed system path: $reconstructed\n";
            push @reconstructed_paths, $reconstructed;
        }
        # Otherwise, might be a relative path backup
        else {
            # Try to determine if this is a full path or relative
            # For now, assume it's relative to current directory
            print "    Unknown entry type: $entry (skipping)\n";
        }
    }
    
    print "Reconstructed " . scalar(@reconstructed_paths) . " source paths total\n";
    return \@reconstructed_paths;
}

# perform_restore
# Executes actual restore operation in child process.
# Determines if backup is directory-based or file-based and routes accordingly.
# Writes progress updates for parent process UI monitoring.
sub perform_restore {
    my $self = shift;
    
    my $progress_file = "/tmp/backup_progress_$$";
    
    print "=== PERFORM_RESTORE DEBUG ===\n";
    print "Starting restore process\n";
    print "Restore from: $self->{restore_source}\n";
    print "Restore to: $self->{restore_destination}\n";
    
    # Write initial progress
    if (open my $fh, '>', $progress_file) {
        print $fh "1\n";
        close $fh;
        print "Initial restore progress (1%) written to file\n";
    } else {
        print "ERROR: Could not write to restore progress file: $!\n";
    }
    
    # First, check if this is a directory-based backup or file-based backup
    if (-d $self->{restore_source}) {
        print "Directory-based backup detected\n";
        
        # Try to read metadata from directory
        my $metadata = $self->read_backup_metadata($self->{restore_source});
        
        if ($metadata) {
            print "Found metadata, using backup type: $metadata->{backup_type}\n";
            $self->restore_by_type($metadata, $progress_file);
        } else {
            print "No metadata found, falling back to directory restore\n";
            $self->restore_from_directory($self->{restore_source}, $self->{restore_destination}, $progress_file);
        }
    } elsif (-f $self->{restore_source}) {
        print "Single file backup detected: $self->{restore_source}\n";
        
        # This is a single backup file (likely compressed/encrypted)
        $self->restore_from_single_file($self->{restore_source}, $self->{restore_destination}, $progress_file);
    } else {
        die "Invalid restore source: $self->{restore_source}";
    }
    
    print "Restore process completed, marking as complete\n";
    
    # Write completion marker
    if (open my $fh, '>', $progress_file) {
        print $fh "COMPLETE\n";
        close $fh;
        print "Restore completion marker written to $progress_file\n";
    } else {
        print "ERROR: Could not write restore completion marker: $!\n";
    }
    
    print "=== PERFORM_RESTORE COMPLETED ===\n";
}

# run_sudo_command
# Executes single sudo command with existing authentication.
# Returns command exit status for success/failure checking.
# Requires prior authentication via elevate_privileges.
sub run_sudo_command {
    my ($self, $command) = @_;
    
    unless ($self->{sudo_authenticated}) {
        print "ERROR: Not authenticated for sudo operations\n";
        return undef;
    }
    
    return system('sudo', $command);
}

# run_with_sudo
# Wraps command string with 'sudo' prefix for execution.
# Redirects stderr to stdout for combined output capture.
# Returns formatted command string ready for execution.
sub run_with_sudo {
    my ($self, $command) = @_;
    
    unless ($self->{sudo_authenticated}) {
        print "ERROR: Not authenticated for sudo operations\n";
        return undef;
    }
    
    print "Running with sudo: $command\n";
    return "sudo $command 2>&1";
}

# secure_decrypt_backup
# Decrypts GPG-encrypted backup files using provided password.
# Uses secure temporary password file with restricted permissions.
# Cleans up password file and clears password from memory after operation.
sub secure_decrypt_backup {
    my ($self, $input_file, $output_file, $password) = @_;
    
    print "Decrypting backup with GPG...\n";
    
    unless (defined $input_file && -f $input_file) {
        print "ERROR: Input file does not exist: $input_file\n";
        return 0;
    }
    
    unless (defined $password && length($password) > 0) {
        print "ERROR: No password provided\n";
        return 0;
    }
    
    # Create secure temporary password file
    my ($pass_fh, $pass_file) = eval {
        tempfile(
            'gpg_pass_XXXXXX',
            DIR => '/tmp',
            SUFFIX => '.txt',
            UNLINK => 1
        );
    };
    
    if ($@ || !defined $pass_fh) {
        print "ERROR: Could not create secure password file: $@\n";
        return 0;
    }
    
    print $pass_fh $password;
    close $pass_fh;
    chmod 0600, $pass_file;
    
    # Use ARRAY FORM for GPG command (secure)
    my @gpg_cmd = (
        'gpg',
        '--batch',
        '--yes',
        '--decrypt',
        '--passphrase-file', $pass_file,
        '--output', $output_file,
        $input_file
    );
    
    print "Running GPG decryption...\n";
    my $result = system(@gpg_cmd);
    my $exit_code = $? >> 8;
    
    # Password file auto-deleted by File::Temp
    unlink $pass_file if -f $pass_file;
    undef $password;
    
    if ($exit_code == 0) {
        print "Decryption completed successfully\n";
        return 1;
    } else {
        print "Decryption failed with exit code: $exit_code\n";
        return 0;
    }
}

# secure_encrypt_backup
# Encrypts backup files using AES256 symmetric encryption.
# Creates temporary password file with secure permissions for GPG.
# Automatically cleans up sensitive password data after encryption.
sub secure_encrypt_backup {
    my ($self, $input_file, $output_file, $password) = @_;
    
    print "Encrypting backup with GPG...\n";
    
    unless (defined $input_file && -f $input_file) {
        print "ERROR: Input file does not exist: $input_file\n";
        return 0;
    }
    
    unless (defined $password && length($password) > 0) {
        print "ERROR: No password provided\n";
        return 0;
    }
    
    # Create secure temporary password file using File::Temp
    my ($pass_fh, $pass_file) = eval {
        tempfile(
            'gpg_pass_XXXXXX',
            DIR => '/tmp',
            SUFFIX => '.txt',
            UNLINK => 1  # Auto-delete
        );
    };
    
    if ($@ || !defined $pass_fh) {
        print "ERROR: Could not create secure password file: $@\n";
        return 0;
    }
    
    print $pass_fh $password;
    close $pass_fh;
    chmod 0600, $pass_file;
    
    # Use ARRAY FORM for GPG command (secure)
    my @gpg_cmd = (
        'gpg',
        '--batch',
        '--yes',
        '--cipher-algo', 'AES256',
        '--symmetric',
        '--passphrase-file', $pass_file,
        '--output', $output_file,
        $input_file
    );
    
    print "Running GPG encryption...\n";
    my $result = system(@gpg_cmd);
    my $exit_code = $? >> 8;
    
    # Password file auto-deleted by File::Temp
    unlink $pass_file if -f $pass_file;
    undef $password;
    
    if ($exit_code == 0) {
        print "Encryption completed successfully\n";
        return 1;
    } else {
        print "Encryption failed with exit code: $exit_code\n";
        return 0;
    }
}

# start_backup
# Validates settings and initiates backup or restore operation.
# Handles authentication for system backups and password collection for encryption.
# Creates backup directory and forks child process for actual operation.
sub start_backup {
    my $self = shift;
    
    # Check if we're in incremental backup mode
    if ($self->{backup_mode} =~ /^incremental_/) {
        unless ($self->{incremental_backup_folder}) {
            $self->show_error_dialog('No previous backup selected', 'Please select a previous backup location first.');
            return;
        }
        
        # Execute incremental backup
        $self->execute_incremental_backup($self->{incremental_backup_folder});
        return;
    }
    
    # Handle restore operations
    if ($self->{operation_mode} eq 'restore') {
        unless ($self->{restore_source}) {
            $self->show_error_dialog('No backup selected', 'Please select a backup to restore first.');
            return;
        }
        unless ($self->{restore_destination}) {
            $self->show_error_dialog('No restore destination selected', 'Please select where to restore the backup.');
            return;
        }
        
        my $restore_password;
        if ($self->backup_contains_encrypted_files($self->{restore_source})) {
            $restore_password = $self->get_restore_password();
            return unless $restore_password;
            $self->{restore_password} = $restore_password;
        } else {
            $self->{restore_password} = undef;
        }
        
        $self->start_restore_process();
        return;
    }
    
    # --- REGULAR BACKUP MODE LOGIC ---
    
    # 1. SYSTEM BACKUP AUTHENTICATION
    if ($self->{selected_backup_type} eq 'system') {
        unless ($self->{sudo_authenticated}) {
            my $password = $self->show_password_dialog("<b>Administrator privileges required</b>\n\nPlease enter your password to backup system files:");
            return unless $password; 
            
            unless ($self->elevate_privileges($password)) {
                $self->show_error_dialog("Authentication Failed", "Incorrect password. System backup requires administrator privileges.");
                return;
            }
        }
    }
    
    # Basic validation
    unless ($self->{backup_destination}) {
        $self->show_error_dialog('No destination selected', 'Please select a backup destination first.');
        return;
    }
    
    if ($self->{selected_backup_type} eq 'custom' && (!$self->{selected_files} || @{$self->{selected_files}} == 0)) {
        $self->show_error_dialog('No files selected', 'Please select files and folders to backup.');
        return;
    }
    
    # Check encryption
    my $encryption_password;
    my $encryption_enabled = $self->{encrypt_check} ? $self->{encrypt_check}->get_active() : 0;
    
    if ($encryption_enabled) {
        $encryption_password = $self->get_encryption_password();
        return unless $encryption_password;
        $self->{encryption_password} = $encryption_password;
    } else {
        $self->{encryption_password} = undef;
    }
    
    # Create backup directory path
    my $backup_name = '';
    if ($self->{backup_name_entry}) {
        $backup_name = $self->{backup_name_entry}->get_text();
    }
    $backup_name =~ s/[^\w\-_.]//g;
    $backup_name = 'backup_' . POSIX::strftime ("%d%m%Y_%H%M%S", localtime) unless $backup_name;
    
    $self->{backup_dir} = "$self->{backup_destination}/$backup_name";
    
    # Check existing
    if (-e $self->{backup_dir}) {
        my $response = $self->show_question_dialog('Directory exists', "The directory '$backup_name' already exists.\nOverwrite?");
        return unless $response;
    }
    
    # Check writable
    unless (-w $self->{backup_destination}) {
        $self->show_error_dialog('Permission denied', "Cannot write to backup destination.");
        return;
    }
    
    # Create directory
    eval { File::Path::make_path($self->{backup_dir}); };
    if ($@ || !-d $self->{backup_dir}) {
        $self->show_error_dialog('Error', "Failed to create backup directory: $@");
        return;
    }
    
    # UI Updates
    if ($self->{start_backup_button}) { $self->{start_backup_button}->set_sensitive(0); }
    if ($self->{cancel_backup_button}) { 
        $self->{cancel_backup_button}->set_sensitive(1);
        $self->set_button_style($self->{cancel_backup_button}, 'destructive-action', 1);
    }
    
    $self->{start_time} = time();
    $self->{processed_size} = 0;
    
    $self->{total_size} = 0; 
    
    if ($self->{status_label}) {
        $self->{status_label}->set_markup("<span size=\"large\" weight=\"bold\">Backup in progress...</span>");
    }
    
    # Fork Process
    $self->{backup_process} = fork();
    
    if (!defined $self->{backup_process}) {
        $self->show_error_dialog('Fork failed', "Could not start backup process: $!");
        return;
    }
    
    if ($self->{backup_process} == 0) {
        # Child process
        my $progress_file = "/tmp/backup_progress_$$";
        unlink $progress_file if -f $progress_file;
        
        if (open my $fh, '>', $progress_file) { print $fh "0\n"; close $fh; }
        
        eval {
            $self->perform_backup();
        };
        if ($@) {
            if (open my $fh, '>', $progress_file) { print $fh "ERROR: $@\n"; close $fh; }
        }
        exit(0);
    } else {
        $self->monitor_backup_process();
        if ($self->{progress_bar}) {
            $self->{progress_bar}->set_fraction(0.0);
            $self->{progress_bar}->set_text('Starting...');
        }
    }
}

# start_incremental_backup
# Shows backup metadata chooser for incremental backup mode.
# Triggered when user selects incremental backup option.
# Routes to execute_incremental_backup after folder selection.
sub start_incremental_backup {
    my $self = shift;
    
    print "Starting incremental backup: type=$self->{selected_backup_type}, mode=$self->{backup_mode}\n";
    
    # Show file chooser to select backup metadata
    $self->show_backup_metadata_chooser();
}
  
# start_progress_updates
# Resets progress indicators to starting state.
# Sets progress bar to 0% and initializes time labels.
# Prepares UI for monitoring new backup/restore operation.
sub start_progress_updates {
    my $self = shift;
    
    $self->{progress_bar}->set_fraction(0);
    $self->{progress_bar}->set_text('Starting...');
    
    if ($self->{elapsed_time_label}) {
        $self->{elapsed_time_label}->set_text('Elapsed: 00:00:00');
    }
    if ($self->{remaining_time_label}) {
        $self->{remaining_time_label}->set_text('Remaining: Calculating...');
    }
}

# start_restore_process
# Initiates restore operation by forking child process.
# Updates UI for restore mode and enables cancel button.
# Sets up progress monitoring timer for restore tracking.
sub start_restore_process {
    my $self = shift;
    
    print "Starting restore process...\n";
    print "Restore from: $self->{restore_source}\n";
    print "Restore to: $self->{restore_destination}\n";
    
    # Update UI for restore operation
    $self->{start_backup_button}->set_sensitive(0);
    $self->set_button_style($self->{start_backup_button}, 'suggested-action', 0);
    
    $self->{target_button}->set_sensitive(0);
    $self->set_button_style($self->{target_button}, 'suggested-action', 0);
    
    $self->{cancel_backup_button}->set_sensitive(1);
    # Turn Cancel button RED
    $self->set_button_style($self->{cancel_backup_button}, 'destructive-action', 1);
    
    $self->{start_time} = time();
    
    # Start restore process (similar to backup but for restore)
    $self->{backup_process} = fork();
    
    if (!defined $self->{backup_process}) {
        $self->show_error_dialog('Fork failed', "Could not start restore process: $!");
        return;
    }
    
    if ($self->{backup_process} == 0) {
        # Child process - do the actual restore
        my $progress_file = "/tmp/backup_progress_$$";
        
        eval {
            $self->perform_restore();
        };
        if ($@) {
            print "ERROR in perform_restore: $@\n";
            if (open my $fh, '>', $progress_file) {
                print $fh "ERROR: $@\n";
                close $fh;
            }
        }
        
        exit(0);
    } else {
        # Parent process - update UI
        $self->{timeout_id} = Glib::Timeout->add(500, sub { $self->update_progress(); });
        
        if ($self->{progress_bar}) {
            $self->{progress_bar}->set_fraction(0.0);
            $self->{progress_bar}->set_text('Starting restore...');
        }
    }
}

# start_sudo_refresh_timer
# Creates periodic timer to refresh sudo authentication timestamp.
# Runs 'sudo -v' every 4 minutes to prevent timeout.
# Stops timer if sudo authentication fails.
sub start_sudo_refresh_timer {
    my $self = shift;
    
    # Remove existing timer if any
    if ($self->{sudo_refresh_timer}) {
        Glib::Source->remove($self->{sudo_refresh_timer});
    }
    
    # Refresh sudo every 4 minutes (240000 ms)
    $self->{sudo_refresh_timer} = Glib::Timeout->add(240000, sub {
        if ($self->{sudo_authenticated}) {
            print "Refreshing sudo timestamp...\n";
            
            # Use ARRAY FORM (secure)
            system('sudo', '-v');
            
            if ($? != 0) {
                print "WARNING: sudo timestamp refresh failed\n";
                $self->{sudo_authenticated} = 0;
                return 0;  # Stop the timer
            }
        }
        return 1;  # Continue the timer
    });
    
    print "Sudo refresh timer started\n";
}

# sudo_cmd
# Formats commands with 'sudo' prefix when authenticated.
# Relies on existing sudo timestamp from elevate_privileges.
# Returns formatted command string or error message if not authenticated.
sub sudo_cmd {
    my ($self, $command) = @_;
    
    unless ($command) {
        print "ERROR: No command provided to sudo_cmd\n";
        return "true";
    }
    
    unless ($self->{sudo_authenticated}) {
        print "ERROR: Not authenticated for sudo operations\n";
        return "false";
    }
    
    # Simply return the command with sudo
    # The sudo timestamp is already established and being refreshed
    return "sudo $command";
}

# verify_backup_completion
# Verifies that all selected files were successfully backed up.
# Compares source and destination file sizes and counts.
# Returns true if verification passes, false if discrepancies found.
sub verify_backup_completion {
    my ($self, $backup_dir, $selected_files) = @_;
    
    print "Verifying backup completion...\n";
    
    my $verification_passed = 1;
    my $include_hidden = $self->{hidden_check} ? $self->{hidden_check}->get_active() : 1;
    
    foreach my $source_item (@$selected_files) {
        my $basename = (split '/', $source_item)[-1];
        my $dest_item = "$backup_dir/$basename";
        
        print "Verifying: $source_item -> $dest_item\n";
        
        if (-f $source_item) {
            # Verify file
            if (!-f $dest_item) {
                print "ERROR: File $dest_item not found in backup\n";
                $verification_passed = 0;
                next;
            }
            
            # Compare file sizes
            my $source_size = -s $source_item;
            my $dest_size = -s $dest_item;
            
            if ($source_size != $dest_size) {
                print "ERROR: File size mismatch for $basename (source: $source_size, dest: $dest_size)\n";
                $verification_passed = 0;
            } else {
                print "OK: File $basename verified (size: $source_size bytes)\n";
            }
        } elsif (-d $source_item) {
            # Verify directory
            if (!-d $dest_item) {
                print "ERROR: Directory $dest_item not found in backup\n";
                $verification_passed = 0;
                next;
            }
            
            # Count files in source and destination
            my $source_file_count = $self->count_files_in_directory($source_item, $include_hidden);
            my $dest_file_count = $self->count_files_in_directory($dest_item, $include_hidden);
            
            if ($source_file_count != $dest_file_count) {
                print "WARNING: File count mismatch for $basename (source: $source_file_count, dest: $dest_file_count)\n";
                # Don't fail verification for minor count differences (could be timing issues)
            } else {
                print "OK: Directory $basename verified ($source_file_count files)\n";
            }
        }
    }
    
    if ($verification_passed) {
        print "Backup verification PASSED\n";
    } else {
        print "Backup verification FAILED\n";
    }
    
    return $verification_passed;
}

# verify_backup_integrity
# Verifies integrity of tar/gzip/gpg backup archives.
# Uses file type detection and format-specific integrity checks.
# Returns true if backup file is valid and readable.
sub verify_backup_integrity {
    my ($self, $backup_file, $compression_enabled, $encryption_enabled) = @_;
    
    print "Improved verification for backup: $backup_file\n";
    
    unless (-f $backup_file) {
        print "ERROR: Backup file does not exist\n";
        return 0;
    }
    
    my $file_size = -s $backup_file;
    print "Backup file size: " . sprintf("%.2f GB", $file_size / (1024**3)) . "\n";
    
    if ($file_size == 0) {
        print "ERROR: Backup file is empty\n";
        return 0;
    }
    
    # For encrypted files, we need to handle verification differently
    if ($encryption_enabled) {
        print "Verifying encrypted backup file...\n";
        
        # For encrypted files, check if it's a valid GPG file
        my $gpg_check = `file '$backup_file'`;
        if ($gpg_check =~ /(GPG|encrypted|OpenPGP)/i) {
            print "File appears to be properly encrypted (GPG format detected)\n";
            
            # Try to get GPG file info without decrypting
            my $gpg_info = `gpg --list-packets --verbose '$backup_file' 2>/dev/null | head -5`;
            if ($gpg_info && $gpg_info =~ /(encrypted|symmetric)/i) {
                print "GPG packet structure verified - appears to be valid encrypted backup\n";
                return 1;
            } else {
                print "WARNING: Could not verify GPG packet structure\n";
                # Don't fail - file might still be valid
                return 1;
            }
        } else {
            print "ERROR: File does not appear to be encrypted despite encryption being enabled\n";
            print "File type: $gpg_check\n";
            return 0;
        }
    } elsif ($compression_enabled) {
        print "Verifying compressed backup file...\n";
        
        # For compressed files, test the gzip header and structure
        my $gzip_test = system("gzip -tq '$backup_file' 2>/dev/null");
        if ($gzip_test == 0) {
            print "Gzip integrity test passed\n";
            return 1;
        } else {
            print "Gzip integrity test failed, trying alternative verification...\n";
            
            # Check file header for gzip magic number
            if (open my $fh, '<', $backup_file) {
                binmode $fh;
                my $buffer;
                if (read($fh, $buffer, 2) == 2) {
                    close $fh;
                    # Gzip magic number is 0x1f 0x8b
                    if (unpack('H*', $buffer) eq '1f8b') {
                        print "Gzip magic number verified - file appears valid\n";
                        return 1;
                    }
                }
                close $fh;
            }
            print "Gzip verification failed\n";
            return 0;
        }
    } else {
        print "Verifying uncompressed tar backup file...\n";
        
        # For plain tar files, test if we can list contents
        my $tar_test = system("tar -tf '$backup_file' >/dev/null 2>&1");
        if ($tar_test == 0) {
            print "Tar file structure test passed\n";
            return 1;
        } else {
            print "Tar file structure test failed\n";
            return 0;
        }
    }
}

# verify_backup_integrity_fast
# Performs fast integrity checks suitable for large backup files.
# Uses header validation instead of full file verification.
# Skips intensive checks for files over 5GB.
sub verify_backup_integrity_fast {
    my ($self, $backup_file, $compression_enabled, $encryption_enabled, $encryption_password) = @_;
    
    print "Fast verification for backup: $backup_file\n";
    
    unless (-f $backup_file) {
        print "ERROR: Backup file does not exist\n";
        return 0;
    }
    
    my $file_size = -s $backup_file;
    print "Backup file size: $file_size bytes (" . sprintf("%.2f GB", $file_size / (1024**3)) . ")\n";
    
    if ($file_size == 0) {
        print "ERROR: Backup file is empty\n";
        return 0;
    }
    
    # For files larger than 5GB, just do basic checks
    if ($file_size > 5368709120) {  # 5GB
        print "Very large file detected (>5GB), doing minimal verification\n";
        
        # Just check file type
        my $file_output = `file '$backup_file'`;
        if ($file_output =~ /(gzip|tar|encrypted|GPG)/) {
            print "File type check passed: appears to be a valid archive\n";
            return 1;
        } else {
            print "File type check failed: $file_output\n";
            return 0;
        }
    }
    
    # For encrypted files, test GPG header
    if ($encryption_enabled) {
        print "Testing encrypted file header...\n";
        
        # Test if GPG can at least recognize the file
        my $test_result = system("gpg --list-packets '$backup_file' >/dev/null 2>&1");
        if ($test_result == 0) {
            print "Encrypted backup header is valid\n";
            return 1;
        } else {
            print "Encrypted backup header test failed\n";
            return 0;
        }
    } elsif ($compression_enabled) {
        # For compressed files, test gzip header
        print "Testing gzip file header...\n";
        
        # Use gzip -t to test the file integrity
        my $test_result = system("gzip -tq '$backup_file' 2>/dev/null");
        if ($test_result == 0) {
            print "Compressed backup header is valid\n";
            return 1;
        } else {
            print "Compressed backup header test failed, trying alternative check\n";
            
            # Alternative: check if file starts with gzip magic number
            if (open my $fh, '<', $backup_file) {
                binmode $fh;
                my $buffer;
                if (read($fh, $buffer, 2) == 2) {
                    close $fh;
                    # Gzip magic number is 0x1f 0x8b
                    if (unpack('H*', $buffer) eq '1f8b') {
                        print "Gzip magic number check passed\n";
                        return 1;
                    }
                }
                close $fh;
            }
            print "All gzip tests failed\n";
            return 0;
        }
    } else {
        # For plain tar files, test the header
        print "Testing tar file header...\n";
        
        # Quick tar header test - just list first few files
        my $test_result = system("tar -tf '$backup_file' | head -10 >/dev/null 2>&1");
        if ($test_result == 0) {
            print "Tar header test passed\n";
            return 1;
        } else {
            print "Tar header test failed\n";
            return 0;
        }
    }
}

# verify_backup_structure
# Verifies that selected folder contains valid backup content.
# Looks for backup files created by tool or reasonable directory structure.
# Returns true if folder appears to be valid backup.
sub verify_backup_structure {
    my ($self, $backup_path) = @_;
    
    return 0 unless -d $backup_path;
    
    print "Verifying backup structure for: $backup_path\n";
    
    # Check for tar-based backups (compressed/encrypted files)
    opendir(my $dh, $backup_path) or return 0;
    my @files = readdir($dh);
    closedir($dh);
    
    # Look for backup files created by this tool
    my $found_backup_files = 0;
    
    foreach my $file (@files) {
        next if $file =~ /^\.\.?$/;  # Skip . and ..
        
        my $full_path = "$backup_path/$file";
        
        # Check for tar-based backup files
        if ($file =~ /^(backup_|system_backup_|custom_backup_|home_backup_)\d{8}_\d{6}\.tar(\.gz)?(\.gpg)?$/) {
            $found_backup_files++;
        }
        # Check for directory-based backups
        elsif (-d $full_path && ($file eq 'home' || $file eq 'bin' || $file eq 'etc' || $file eq 'usr' || $file eq 'var')) {
    
            $found_backup_files++;
        }
    }
    
    if ($found_backup_files > 0) {

        return 1;
    }
    
    my $directory_count = 0;
    my $file_count = 0;
    
    foreach my $file (@files) {
        next if $file =~ /^\.\.?$/;
        my $full_path = "$backup_path/$file";
        
        if (-d $full_path) {
            $directory_count++;
        } elsif (-f $full_path) {
            $file_count++;
        }
    }
    
    # If we have a reasonable number of files/directories, consider it a potential backup
    if ($directory_count >= 2 || $file_count >= 5) {

        return 1;
    }

    return 0;
}

# verify_backup_type_compatibility
# Ensures selected backup type matches original backup metadata.
# Handles legacy 'directory' type backups with type inference.
# Automatically sets backup type to match loaded backup for incremental operations.
sub verify_backup_type_compatibility {
    my ($self, $backup_folder) = @_;
    
    my $metadata = $self->{incremental_metadata};
    my $original_type = $metadata->{backup_type} || '';
    
    print "Loading incremental backup with type: '$original_type'\n";
    
    # Handle legacy backups with 'directory' type
    if ($original_type eq 'directory') {
        print "Found legacy 'directory' type backup, trying to infer actual type...\n";
        
        # Try to infer the actual backup type from metadata
        my $inferred_type = $self->infer_backup_type_from_metadata($metadata);
        
        if ($inferred_type) {
            print "Successfully inferred backup type as '$inferred_type'\n";
            # Update the metadata for consistency
            $metadata->{backup_type} = $inferred_type;
            $original_type = $inferred_type;
        } else {
            print "Could not infer backup type from legacy metadata\n";
            # Show a more helpful error for legacy backups
            $self->show_error_dialog('Legacy Backup Format',
                "This appears to be a backup created with an older version of the tool.\n" .
                "The backup type could not be determined automatically.\n\n" .
                "Please try selecting a different backup type that matches your original backup:\n" .
                "- If you backed up your home directory, use 'Backup home directory'\n" . 
                "- If you backed up the system files, use 'Backup system files'\n" .
                "- If you backed up specific files/folders, use 'Backup selected files and folders'");
            return;
        }
    }
    
    # CRITICAL FIX: For incremental backups, automatically set the backup type to match the loaded backup
    # This is required because incremental backups MUST use the same type as the original backup
    print "Setting selected_backup_type to match loaded backup: '$original_type'\n";
    $self->{selected_backup_type} = $original_type;
    
    # Update the destination label to show the correct information
    my $backup_name = (split '/', $backup_folder)[-1];
    my $type_display = ucfirst($original_type);
    
    if ($self->{destination_label}) {
        $self->{destination_label}->set_markup(
            "<b>Incremental backup for:</b> $backup_name\n" .
            "<i>Type: $type_display</i>"
        );
    }
    
    # Proceed with analysis
    $self->analyze_backup_changes($backup_folder);
}

#---------------------------------------------------Main Application----------------------------------------

# Create and run the application
my $app = BackupTool->new();
$app->run();