#!/bin/bash

# Moodle + Koha Restore Script
# Restores from Backblaze B2 backups created by backup.sh
#
# Usage: 
#   ./restore.sh                    # Interactive mode
#   ./restore.sh --latest daily     # Restore latest daily backup
#   ./restore.sh --date 20240115    # Restore specific date
#   ./restore.sh --list             # List available backups

set -e

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

# Configuration
BACKUP_NAME="moodle-koha-$(hostname)"
B2_REMOTE="b2:your-bucket-name"  # Change this to your B2 remote name
B2_PATH="backups/$BACKUP_NAME"
RESTORE_DIR="/var/restore/$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/restore"
LOG_FILE="$LOG_DIR/restore-$(date +%Y%m%d-%H%M%S).log"
SITES_DIRECTORY="${SITES_DIRECTORY:-/var/www}"

# Parse command line arguments
RESTORE_MODE="interactive"
RESTORE_TYPE=""
RESTORE_DATE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --latest)
            RESTORE_MODE="latest"
            RESTORE_TYPE="$2"
            shift 2
            ;;
        --date)
            RESTORE_MODE="date"
            RESTORE_DATE="$2"
            shift 2
            ;;
        --list)
            RESTORE_MODE="list"
            shift
            ;;
        --help)
            cat << EOF
Usage: $0 [OPTIONS]

Options:
  --latest TYPE     Restore latest backup of TYPE (daily/weekly/monthly)
  --date DATE       Restore backup from specific date (YYYYMMDD)
  --list           List available backups
  --help           Show this help message

Examples:
  $0                      # Interactive mode
  $0 --latest daily       # Restore latest daily backup
  $0 --date 20240115      # Restore backup from Jan 15, 2024
  $0 --list              # Show all available backups

EOF
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Create necessary directories
setup_directories() {
    mkdir -p "$RESTORE_DIR"
    mkdir -p "$LOG_DIR"
}

# Load database credentials
load_db_credentials() {
    if [ -f "$SITES_DIRECTORY/config/database-credentials.txt" ]; then
        DB_ROOT_PASSWORD=$(grep "Password:" "$SITES_DIRECTORY/config/database-credentials.txt" | grep "MariaDB Root" -A1 | tail -1 | awk '{print $2}')
        MOODLE_DB_PASSWORD=$(grep "Password:" "$SITES_DIRECTORY/config/database-credentials.txt" | grep "Moodle Database" -A1 | tail -1 | awk '{print $2}')
    else
        error "Database credentials file not found!"
    fi
}

# List available backups
list_backups() {
    info "=== Available Backups ==="
    echo
    
    for type in daily weekly monthly; do
        echo -e "${BLUE}${type^} Backups:${NC}"
        rclone ls "$B2_REMOTE/$B2_PATH/$type/" 2>/dev/null | grep -E "backup-$type-.*\.tar\.gz$" | sort -r | head -10 || echo "  No $type backups found"
        echo
    done
}

# Find latest backup of specific type
find_latest_backup() {
    local backup_type="$1"
    local latest=$(rclone ls "$B2_REMOTE/$B2_PATH/$backup_type/" 2>/dev/null | grep -E "backup-$backup_type-.*\.tar\.gz$" | sort -r | head -1 | awk '{print $2}')
    
    if [ -z "$latest" ]; then
        error "No $backup_type backups found!"
    fi
    
    echo "$latest"
}

# Find backup by date
find_backup_by_date() {
    local date_pattern="$1"
    local found_backups=()
    
    for type in daily weekly monthly; do
        local backups=$(rclone ls "$B2_REMOTE/$B2_PATH/$type/" 2>/dev/null | grep -E "backup-$type-.*$date_pattern.*\.tar\.gz$" | awk '{print $2}')
        if [ -n "$backups" ]; then
            while IFS= read -r backup; do
                found_backups+=("$type/$backup")
            done <<< "$backups"
        fi
    done
    
    if [ ${#found_backups[@]} -eq 0 ]; then
        error "No backups found for date: $date_pattern"
    elif [ ${#found_backups[@]} -eq 1 ]; then
        echo "${found_backups[0]}"
    else
        echo -e "${YELLOW}Multiple backups found for date $date_pattern:${NC}"
        select backup in "${found_backups[@]}"; do
            echo "$backup"
            break
        done
    fi
}

# Pre-restore checks
pre_restore_checks() {
    log "Performing pre-restore checks..."
    
    # Check if services are running
    local services_running=true
    for service in apache2 php8.3-fpm mariadb; do
        if systemctl is-active --quiet $service; then
            warn "Service $service is running. It will be stopped during restore."
        else
            log "Service $service is already stopped"
        fi
    done
    
    # Check disk space
    local available_space=$(df "$RESTORE_DIR" | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$available_space" -lt 10 ]; then
        error "Insufficient disk space. Need at least 10GB, have ${available_space}GB"
    fi
    
    # Warn about data loss
    echo
    echo -e "${RED}⚠️  WARNING: This will restore your Moodle and Koha data!${NC}"
    echo -e "${RED}⚠️  Current data will be backed up but may be overwritten.${NC}"
    echo
    read -p "Are you sure you want to continue? Type 'yes' to proceed: " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "Restore cancelled by user"
        exit 0
    fi
}

# Create emergency backup of current state
create_emergency_backup() {
    log "Creating emergency backup of current state..."
    
    local emergency_dir="/var/backups/emergency/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$emergency_dir"
    
    # Quick database dumps
    info "Backing up current databases..."
    mysqldump -u root -p"$DB_ROOT_PASSWORD" --single-transaction --quick moodle 2>/dev/null | gzip > "$emergency_dir/moodle-current.sql.gz" || warn "Failed to backup current Moodle DB"
    mysqldump -u root -p"$DB_ROOT_PASSWORD" --single-transaction --quick koha_library 2>/dev/null | gzip > "$emergency_dir/koha-current.sql.gz" || warn "Failed to backup current Koha DB"
    
    # Save current configs
    info "Backing up current configurations..."
    tar -czf "$emergency_dir/configs-current.tar.gz" \
        "$SITES_DIRECTORY/moodle/config.php" \
        /etc/caddy/Caddyfile \
        /etc/apache2/sites-available/library.conf \
        /etc/koha/sites/library/koha-conf.xml 2>/dev/null || warn "Some config files not found"
    
    log "Emergency backup saved to: $emergency_dir"
    echo "$emergency_dir" > "$RESTORE_DIR/.emergency_backup_location"
}

# Download backup from B2
download_backup() {
    local backup_path="$1"
    local backup_file=$(basename "$backup_path")
    
    log "Downloading backup: $backup_file"
    
    # Download with progress
    rclone copy "$B2_REMOTE/$B2_PATH/$backup_path" "$RESTORE_DIR/" \
        --progress \
        --transfers 4 \
        --checkers 8
    
    if [ ! -f "$RESTORE_DIR/$backup_file" ]; then
        error "Failed to download backup!"
    fi
    
    # Verify download
    log "Verifying backup integrity..."
    if ! tar -tzf "$RESTORE_DIR/$backup_file" >/dev/null 2>&1; then
        error "Backup file is corrupted!"
    fi
    
    # Extract backup
    log "Extracting backup..."
    cd "$RESTORE_DIR"
    tar -xzf "$backup_file"
    
    # Verify expected directories exist
    for dir in databases files config; do
        if [ ! -d "$dir" ]; then
            error "Backup missing expected directory: $dir"
        fi
    done
    
    log "Backup extracted successfully"
}

# Stop services
stop_services() {
    log "Stopping services..."
    
    # Put Moodle in maintenance mode first
    if [ -f "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" ]; then
        sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" --enable || true
    fi
    
    # Stop services
    for service in apache2 php8.3-fpm; do
        systemctl stop $service || warn "Failed to stop $service"
    done
    
    log "Services stopped"
}

# Start services
start_services() {
    log "Starting services..."
    
    # Ensure MariaDB is running
    systemctl start mariadb || error "Failed to start MariaDB"
    
    # Start other services
    systemctl start apache2 || error "Failed to start Apache"
    systemctl start php8.3-fpm || error "Failed to start PHP-FPM"
    systemctl start caddy || warn "Failed to start Caddy"
    
    # Take Moodle out of maintenance mode
    if [ -f "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" ]; then
        sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" --disable || true
    fi
    
    log "Services started"
}

# Restore Moodle database
restore_moodle_database() {
    log "Restoring Moodle database..."
    
    local moodle_backup=$(ls "$RESTORE_DIR"/databases/moodle-*.sql.gz 2>/dev/null | head -1)
    
    if [ -z "$moodle_backup" ]; then
        error "Moodle database backup not found!"
    fi
    
    # Drop and recreate database
    mysql -u root -p"$DB_ROOT_PASSWORD" << EOF
DROP DATABASE IF EXISTS moodle;
CREATE DATABASE moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON moodle.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    # Restore database
    gunzip -c "$moodle_backup" | mysql -u root -p"$DB_ROOT_PASSWORD" moodle
    
    log "Moodle database restored"
}

# Restore Koha database
restore_koha_database() {
    log "Restoring Koha database..."
    
    # Check for koha-dump format first
    local koha_tarball=$(ls "$RESTORE_DIR"/databases/koha-*.tar.gz 2>/dev/null | head -1)
    local koha_sqlgz=$(ls "$RESTORE_DIR"/databases/koha-*.sql.gz 2>/dev/null | head -1)
    
    if [ -n "$koha_tarball" ]; then
        log "Found Koha tarball backup"
        
        # Extract koha-dump tarball
        local temp_dir="/tmp/koha-restore-$$"
        mkdir -p "$temp_dir"
        tar -xzf "$koha_tarball" -C "$temp_dir"
        
        # Find the SQL file inside
        local sql_file=$(find "$temp_dir" -name "*.sql.gz" -o -name "*.sql" | head -1)
        
        if [ -z "$sql_file" ]; then
            error "No SQL file found in Koha backup!"
        fi
        
        # Drop and restore
        koha-remove library --keep-mysql || warn "koha-remove failed"
        koha-create --create-db library || warn "koha-create failed"
        
        # Restore the database
        if [[ "$sql_file" == *.gz ]]; then
            gunzip -c "$sql_file" | koha-mysql library
        else
            koha-mysql library < "$sql_file"
        fi
        
        rm -rf "$temp_dir"
        
    elif [ -n "$koha_sqlgz" ]; then
        log "Found Koha SQL backup"
        
        # Direct SQL restore
        mysql -u root -p"$DB_ROOT_PASSWORD" << EOF
DROP DATABASE IF EXISTS koha_library;
CREATE DATABASE koha_library DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
EOF
        
        gunzip -c "$koha_sqlgz" | mysql -u root -p"$DB_ROOT_PASSWORD" koha_library
    else
        error "No Koha database backup found!"
    fi
    
    log "Koha database restored"
}

# Restore Moodle data files
restore_moodle_files() {
    log "Restoring Moodle data files..."
    
    local moodledata_backup=$(ls "$RESTORE_DIR"/files/moodledata-*.tar.gz 2>/dev/null | head -1)
    
    if [ -z "$moodledata_backup" ]; then
        warn "Moodle data files backup not found, skipping..."
        return
    fi
    
    # Backup current moodledata
    if [ -d "$SITES_DIRECTORY/data/moodledata" ]; then
        mv "$SITES_DIRECTORY/data/moodledata" "$SITES_DIRECTORY/data/moodledata.old.$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Extract new moodledata
    tar -xzf "$moodledata_backup" -C "$SITES_DIRECTORY/data/"
    
    # Fix permissions
    chown -R www-data:www-data "$SITES_DIRECTORY/data/moodledata"
    find "$SITES_DIRECTORY/data/moodledata" -type d -exec chmod 755 {} \;
    find "$SITES_DIRECTORY/data/moodledata" -type f -exec chmod 644 {} \;
    
    log "Moodle data files restored"
}

# Restore configuration files (optional)
restore_configs() {
    local config_backup=$(ls "$RESTORE_DIR"/config/configs-*.tar.gz 2>/dev/null | head -1)
    
    if [ -z "$config_backup" ]; then
        log "No configuration backup found, skipping..."
        return
    fi
    
    echo
    read -p "Do you want to restore configuration files? (y/N): " restore_conf
    
    if [[ "$restore_conf" =~ ^[Yy]$ ]]; then
        log "Restoring configuration files..."
        
        # Create backup of current configs
        local conf_backup_dir="/var/backups/configs-pre-restore-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$conf_backup_dir"
        
        # Backup current configs
        for conf in /etc/apache2/sites-available /etc/caddy/Caddyfile /etc/koha/sites; do
            if [ -e "$conf" ]; then
                cp -r "$conf" "$conf_backup_dir/" 2>/dev/null || true
            fi
        done
        
        log "Current configs backed up to: $conf_backup_dir"
        
        # Extract configs
        tar -xzf "$config_backup" -C /
        
        log "Configuration files restored"
    else
        log "Skipping configuration restore"
    fi
}

# Post-restore tasks
post_restore_tasks() {
    log "Performing post-restore tasks..."
    
    # Clear Moodle cache
    if [ -f "$SITES_DIRECTORY/moodle/admin/cli/purge_caches.php" ]; then
        info "Clearing Moodle cache..."
        sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/purge_caches.php"
    fi
    
    # Rebuild Koha search index
    info "Rebuilding Koha search index..."
    koha-rebuild-zebra -f -v library || warn "Koha zebra rebuild failed"
    
    # Update Moodle database if needed
    if [ -f "$SITES_DIRECTORY/moodle/admin/cli/upgrade.php" ]; then
        info "Checking for Moodle database updates..."
        sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/upgrade.php" --non-interactive || warn "Moodle upgrade check failed"
    fi
    
    # Reset permissions
    info "Resetting file permissions..."
    chown -R www-data:www-data "$SITES_DIRECTORY/moodle"
    chown -R www-data:www-data "$SITES_DIRECTORY/data/moodledata"
    
    log "Post-restore tasks completed"
}

# Verify restore
verify_restore() {
    log "Verifying restore..."
    
    local all_good=true
    
    # Check database connectivity
    if mysql -u root -p"$DB_ROOT_PASSWORD" -e "USE moodle; SELECT COUNT(*) FROM mdl_user;" >/dev/null 2>&1; then
        log "✓ Moodle database accessible"
    else
        warn "✗ Cannot access Moodle database"
        all_good=false
    fi
    
    if mysql -u root -p"$DB_ROOT_PASSWORD" -e "USE koha_library; SHOW TABLES;" >/dev/null 2>&1; then
        log "✓ Koha database accessible"
    else
        warn "✗ Cannot access Koha database"
        all_good=false
    fi
    
    # Check services
    for service in apache2 php8.3-fpm mariadb; do
        if systemctl is-active --quiet $service; then
            log "✓ $service is running"
        else
            warn "✗ $service is not running"
            all_good=false
        fi
    done
    
    # Check file accessibility
    if sudo -u www-data test -r "$SITES_DIRECTORY/moodle/config.php"; then
        log "✓ Moodle config accessible"
    else
        warn "✗ Moodle config not accessible"
        all_good=false
    fi
    
    if [ "$all_good" = true ]; then
        log "✅ All checks passed!"
        return 0
    else
        warn "⚠️ Some checks failed - manual intervention may be needed"
        return 1
    fi
}

# Main restore process
main() {
    log "=== Starting Moodle + Koha Restore Process ==="
    
    setup_directories
    load_db_credentials
    
    # Determine what to restore based on mode
    case "$RESTORE_MODE" in
        "list")
            list_backups
            exit 0
            ;;
        "latest")
            if [ -z "$RESTORE_TYPE" ]; then
                error "Backup type required for --latest mode"
            fi
            BACKUP_FILE=$(find_latest_backup "$RESTORE_TYPE")
            BACKUP_PATH="$RESTORE_TYPE/$BACKUP_FILE"
            log "Selected latest $RESTORE_TYPE backup: $BACKUP_FILE"
            ;;
        "date")
            if [ -z "$RESTORE_DATE" ]; then
                error "Date required for --date mode"
            fi
            BACKUP_PATH=$(find_backup_by_date "$RESTORE_DATE")
            log "Selected backup: $BACKUP_PATH"
            ;;
        "interactive")
            list_backups
            echo
            read -p "Enter backup type (daily/weekly/monthly): " backup_type
            read -p "Enter backup date (YYYYMMDD) or 'latest': " backup_date
            
            if [ "$backup_date" = "latest" ]; then
                BACKUP_FILE=$(find_latest_backup "$backup_type")
                BACKUP_PATH="$backup_type/$BACKUP_FILE"
            else
                BACKUP_PATH=$(find_backup_by_date "$backup_date")
            fi
            log "Selected backup: $BACKUP_PATH"
            ;;
    esac
    
    # Confirm and proceed
    pre_restore_checks
    create_emergency_backup
    download_backup "$BACKUP_PATH"
    stop_services
    
    # Restore components
    restore_moodle_database
    restore_koha_database
    restore_moodle_files
    restore_configs
    
    # Restart and verify
    start_services
    post_restore_tasks
    
    if verify_restore; then
        info "=== Restore Completed Successfully! ==="
        info "Emergency backup location: $(cat "$RESTORE_DIR/.emergency_backup_location")"
        info "Restore files location: $RESTORE_DIR"
        info ""
        info "Please test your sites:"
        info "- Moodle: https://your-moodle-domain"
        info "- Koha OPAC: https://your-koha-domain" 
        info "- Koha Staff: https://your-koha-staff-domain"
        info ""
        info "If everything works correctly, you can remove the emergency backup."
    else
        error "=== Restore completed with warnings - please check the issues above ==="
    fi
}

# Run main function
main

# Exit successfully
exit 0