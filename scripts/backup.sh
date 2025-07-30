#!/bin/bash

# Automated Backup Script for Moodle + Koha Server
# Backs up to Backblaze B2 using rclone with healthchecks.io monitoring
# Run this script via cron for automated backups

set -e

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
BACKUP_NAME="moodle-koha-$(hostname)"
DATE=$(date +%Y%m%d-%H%M%S)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
BACKUP_DIR="/var/backups/daily"
LOG_DIR="/var/log/backups"
LOG_FILE="$LOG_DIR/backup-$DATE.log"
SITES_DIRECTORY="${SITES_DIRECTORY:-/var/www}"
START_TIME=$(date +%s)

# Create log directory first
mkdir -p "$LOG_DIR"

# Logging functions (now safe to use LOG_FILE)
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

# B2 Configuration
B2_REMOTE="b2:your-bucket-name"  # Change this to your B2 remote name
B2_PATH="backups/$BACKUP_NAME"

# Healthchecks.io Configuration
HEALTHCHECK_URL="https://hc-ping.com/YOUR-CHECK-UUID"  # Change this to your healthchecks.io ping URL

# Retention policies
DAILY_RETENTION=7    # Keep 7 daily backups
WEEKLY_RETENTION=4   # Keep 4 weekly backups (Sunday)
MONTHLY_RETENTION=6  # Keep 6 monthly backups (1st of month)

# Trap to catch unexpected errors
trap 'handle_error $? $LINENO' ERR

handle_error() {
    local exit_code
    exit_code="$1"
    local line_number
    line_number="$2"
    local error_msg
    error_msg="Unexpected error at line $line_number (exit code: $exit_code)"
    error "$error_msg"
    ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
    exit "$exit_code"
}

# Function to ping healthchecks.io
ping_healthcheck() {
    local endpoint="${1:-}"  # Can be empty, "/start", or "/fail"
    local data="${2:-}"      # Optional data to send
    
    if [ -z "$HEALTHCHECK_URL" ] || [ "$HEALTHCHECK_URL" = "https://hc-ping.com/YOUR-CHECK-UUID" ]; then
        warn "Healthchecks.io not configured - skipping notification"
        return 0
    fi
    
    # Send ping with optional data
    if [ -n "$data" ]; then
        curl -fsS -m 10 --retry 3 --data-raw "$data" "${HEALTHCHECK_URL}${endpoint}" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${endpoint}" >/dev/null 2>&1 || true
    fi
}

# Function to format error for healthchecks
format_healthcheck_error() {
    local error_msg
    error_msg="$1"
    local log_tail
    log_tail=$(tail -n 20 "$LOG_FILE" 2>/dev/null || echo "No log available")
    
    cat << EOF
Backup Failed: $(hostname)
Time: $(date)
Error: $error_msg

Last 20 log lines:
$log_tail

Server Status:
$(df -h / | tail -1)
$(free -h | grep Mem)
Load: $(uptime | awk -F'load average:' '{print $2}')
EOF
}

# Database credentials (loaded from secure storage)
load_db_credentials() {
    if [ -f "$SITES_DIRECTORY/config/database-credentials.txt" ]; then
        # Extract MariaDB root password (look for "MariaDB Root:" then find the next "Password:" line)
        DB_ROOT_PASSWORD=$(grep -A3 "MariaDB Root:" "$SITES_DIRECTORY/config/database-credentials.txt" | grep "Password:" | head -1 | sed 's/Password: //')
        
        # Extract Moodle database password (look for "Moodle Database:" then find the next "Password:" line)
        MOODLE_DB_PASSWORD=$(grep -A3 "Moodle Database:" "$SITES_DIRECTORY/config/database-credentials.txt" | grep "Password:" | head -1 | sed 's/Password: //')
        
        # Debug output (remove in production)
        log "Loaded DB credentials successfully"
        
        # Verify we got the password
        if [ -z "$DB_ROOT_PASSWORD" ]; then
            error "Failed to extract MariaDB root password from credentials file"
            return 1
        fi
        
        return 0
    else
        error "Database credentials file not found at: $SITES_DIRECTORY/config/database-credentials.txt"
        return 1
    fi
}

# Create necessary directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"  # This is now redundant but kept for consistency
    mkdir -p "$BACKUP_DIR/databases"
    mkdir -p "$BACKUP_DIR/files"
    mkdir -p "$BACKUP_DIR/config"
}

# Function to check available disk space
check_disk_space() {
    local required_space
    required_space="$1"  # in MB
    local available_space
    available_space=$(df "$BACKUP_DIR" | awk 'NR==2 {print int($4/1024)}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        error "Insufficient disk space. Required: ${required_space}MB, Available: ${available_space}MB"
        return 1
    fi
    log "Disk space check passed. Available: ${available_space}MB"
    return 0
}

# Pre-backup health check
pre_backup_health_check() {
    log "Performing pre-backup health check..."
    
    local all_healthy=true
    
    # Check critical services
    for service in mariadb apache2 php8.3-fpm; do
        if ! systemctl is-active --quiet $service; then
            error "Service $service is not running!"
            all_healthy=false
        fi
    done
    
    # Check database connectivity
    if ! mysql -u root -p"$DB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
        error "Cannot connect to MariaDB!"
        all_healthy=false
    fi
    
    # Check if Moodle is accessible
    if [ -f "$SITES_DIRECTORY/moodle/config.php" ]; then
        log "✓ Moodle config found"
    else
        error "Moodle config.php not found!"
        all_healthy=false
    fi
    
    if [ "$all_healthy" = false ]; then
        error "Pre-backup health check failed!"
        return 1
    fi
    
    log "✓ All systems healthy"
    return 0
}

# Backup Moodle database
backup_moodle_database() {
    log "Backing up Moodle database..."
    
    # Put Moodle in maintenance mode
    if [ -f "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" ]; then
        sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" --enable || {
            warn "Failed to enable Moodle maintenance mode"
        }
    fi
    
    # Dump database
    if mysqldump -u root -p"$DB_ROOT_PASSWORD" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --databases moodle \
        2>"$LOG_DIR/moodle-dump-error.log" | gzip > "$BACKUP_DIR/databases/moodle-$DATE.sql.gz"; then
        log "Moodle database backup completed"
    else
        error "Moodle database dump failed. Check $LOG_DIR/moodle-dump-error.log"
        # Take Moodle out of maintenance mode before failing
        if [ -f "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" ]; then
            sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" --disable || true
        fi
        return 1
    fi
    
    # Take Moodle out of maintenance mode
    if [ -f "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" ]; then
        sudo -u www-data php "$SITES_DIRECTORY/moodle/admin/cli/maintenance.php" --disable || {
            warn "Failed to disable Moodle maintenance mode"
        }
    fi
    
    return 0
}

# Backup Koha database
backup_koha_database() {
    log "Backing up Koha database..."
    
    # Use koha-dump for proper Koha backup
    if koha-dump library; then
        # Move the dump to our backup directory
        if mv /var/spool/koha/library/*.tar.gz "$BACKUP_DIR/databases/koha-$DATE.tar.gz" 2>/dev/null; then
            log "Koha database backup completed"
            return 0
        else
            warn "koha-dump succeeded but could not find output file"
        fi
    fi
    
    # Fallback to manual dump if koha-dump fails
    warn "koha-dump failed, falling back to manual mysqldump"
    if mysqldump -u root -p"$DB_ROOT_PASSWORD" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --databases koha_library \
        2>"$LOG_DIR/koha-dump-error.log" | gzip > "$BACKUP_DIR/databases/koha-$DATE.sql.gz"; then
        log "Koha database backup completed (manual dump)"
        return 0
    else
        error "Koha database backup failed"
        return 1
    fi
}

# Backup Moodle files
backup_moodle_files() {
    log "Backing up Moodle data files..."
    
    # Create a tar archive of moodledata (excluding cache and temp)
    if tar -czf "$BACKUP_DIR/files/moodledata-$DATE.tar.gz" \
        -C "$SITES_DIRECTORY/data" \
        --exclude='moodledata/cache/*' \
        --exclude='moodledata/temp/*' \
        --exclude='moodledata/sessions/*' \
        --exclude='moodledata/localcache/*' \
        --exclude='moodledata/lock/*' \
        moodledata 2>"$LOG_DIR/moodledata-tar-error.log"; then
        log "Moodle data files backup completed"
        return 0
    else
        error "Moodle data files backup failed"
        return 1
    fi
}

# Backup configuration files
backup_configs() {
    log "Backing up configuration files..."
    
    # Create a tar archive of all config files
    if tar -czf "$BACKUP_DIR/config/configs-$DATE.tar.gz" \
        -C / \
        etc/apache2/sites-available \
        etc/caddy/Caddyfile \
        etc/koha/sites \
        etc/php/8.3/fpm/php.ini \
        etc/mysql/mariadb.conf.d \
        "$SITES_DIRECTORY/config" \
        "$SITES_DIRECTORY/moodle/config.php" 2>/dev/null; then
        log "Configuration files backup completed"
        return 0
    else
        warn "Some configuration files may be missing from backup"
        # This is a warning, not a failure, as some files might not exist
        return 0
    fi
}

# Backup system package list
backup_system_packages() {
    log "Backing up system package list..."
    
    # Save list of installed packages for disaster recovery
    dpkg --get-selections > "$BACKUP_DIR/config/packages-$DATE.list"
    apt-mark showmanual > "$BACKUP_DIR/config/packages-manual-$DATE.list"
    
    # Save repository information
    cp -r /etc/apt/sources.list* "$BACKUP_DIR/config/" 2>/dev/null || true
    
    log "System package list saved"
}

# Create backup metadata
create_metadata() {
    cat > "$BACKUP_DIR/backup-metadata-$DATE.json" << EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "hostname": "$(hostname)",
    "server_ip": "$(curl -s ifconfig.me 2>/dev/null || echo 'unknown')",
    "backup_type": "$(if [ "$DAY_OF_WEEK" = "7" ]; then echo "weekly"; elif [ "$(date +%d)" = "01" ]; then echo "monthly"; else echo "daily"; fi)",
    "backup_version": "1.0",
    "components": {
        "moodle_db": {
            "file": "moodle-$DATE.sql.gz",
            "size": "$(du -h "$BACKUP_DIR/databases/moodle-$DATE.sql.gz" 2>/dev/null | cut -f1)",
            "records": "$(mysql -u root -p"$DB_ROOT_PASSWORD" -Ne "SELECT COUNT(*) FROM moodle.mdl_user" 2>/dev/null || echo "unknown")"
        },
        "koha_db": {
            "file": "koha-$DATE.tar.gz",
            "size": "$(du -h "$BACKUP_DIR/databases/koha-$DATE."* 2>/dev/null | cut -f1 | head -1)"
        },
        "moodle_files": {
            "file": "moodledata-$DATE.tar.gz",
            "size": "$(du -h "$BACKUP_DIR/files/moodledata-$DATE.tar.gz" 2>/dev/null | cut -f1)"
        },
        "configs": {
            "file": "configs-$DATE.tar.gz",
            "size": "$(du -h "$BACKUP_DIR/config/configs-$DATE.tar.gz" 2>/dev/null | cut -f1)"
        }
    },
    "services": {
        "apache2": "$(systemctl is-active apache2)",
        "caddy": "$(systemctl is-active caddy)",
        "mariadb": "$(systemctl is-active mariadb)",
        "php-fpm": "$(systemctl is-active php8.3-fpm)",
        "koha-common": "$(systemctl is-active koha-common)"
    },
    "system": {
        "kernel": "$(uname -r)",
        "uptime_days": "$(awk '{print int($1/86400)}' /proc/uptime)",
        "load_average": "$(uptime | awk -F'load average:' '{print $2}')",
        "disk_usage": "$(df -h / | tail -1 | awk '{print $5}')"
    }
}
EOF
}

# Upload to B2
upload_to_b2() {
    log "Uploading backups to Backblaze B2..."
    
    # Determine backup type for folder structure
    local backup_type="daily"
    if [ "$DAY_OF_WEEK" = "7" ]; then
        backup_type="weekly"
    elif [ "$(date +%d)" = "01" ]; then
        backup_type="monthly"
    fi
    
    # Create a single archive of all backups
    log "Creating backup archive..."
    cd "$BACKUP_DIR"
    tar -czf "backup-$backup_type-$DATE.tar.gz" \
        "databases"/*-"$DATE".* \
        "files"/*-"$DATE".* \
        "config"/*-"$DATE".* \
        "backup-metadata-$DATE.json"
    
    # Upload to B2 with progress
    log "Uploading to B2..."
    if rclone copy \
        "backup-$backup_type-$DATE.tar.gz" \
        "$B2_REMOTE/$B2_PATH/$backup_type/" \
        --progress \
        --transfers 4 \
        --checkers 8 \
        --log-file="$LOG_FILE" \
        --log-level INFO; then
        log "Upload to B2 completed successfully"
        
        # Clean up local backup archive
        rm -f "backup-$backup_type-$DATE.tar.gz"
        return 0
    else
        error "Upload to B2 failed!"
        return 1
    fi
}

# Clean up old local backups
cleanup_local() {
    log "Cleaning up old local backups..."
    
    # Remove individual backup files older than 1 day
    find "$BACKUP_DIR" -name "*-20*.gz" -type f -mtime +1 -delete
    find "$BACKUP_DIR" -name "*-20*.json" -type f -mtime +1 -delete
    find "$BACKUP_DIR" -name "*-20*.list" -type f -mtime +1 -delete
    
    log "Local cleanup completed"
}

# Clean up old B2 backups based on retention policy
cleanup_b2() {
    log "Managing B2 backup retention..."
    
    # Daily backups - keep last 7
    log "Cleaning daily backups (keeping last $DAILY_RETENTION)..."
    rclone delete "$B2_REMOTE/$B2_PATH/daily/" \
        --min-age "${DAILY_RETENTION}d" \
        --include "backup-daily-*.tar.gz"
    
    # Weekly backups - keep last 4
    log "Cleaning weekly backups (keeping last $WEEKLY_RETENTION)..."
    rclone delete "$B2_REMOTE/$B2_PATH/weekly/" \
        --min-age "$((WEEKLY_RETENTION * 7))d" \
        --include "backup-weekly-*.tar.gz"
    
    # Monthly backups - keep last 6
    log "Cleaning monthly backups (keeping last $MONTHLY_RETENTION)..."
    rclone delete "$B2_REMOTE/$B2_PATH/monthly/" \
        --min-age "$((MONTHLY_RETENTION * 30))d" \
        --include "backup-monthly-*.tar.gz"
    
    log "B2 retention management completed"
}

# Send notification (optional - configure as needed)
send_notification() {
    local status=$1
    local message=$2
    
    # Example: Send to a log file that can be monitored
    echo "[$status] $message" >> "$LOG_DIR/backup-status.log"
    # Create timestamp file for monitoring
    date +%s > /var/run/last_backup_timestamp
    
    # You could add email, Slack, or other notifications here
}

# Help function
show_help() {
    cat << EOF
Moodle + Koha Backup Script

Usage: $0 [OPTIONS]

Options:
    --help                Show this help message
    --setup-healthchecks  Guide for setting up healthchecks.io
    --test-credentials    Test database credentials loading

Configuration:
    Edit this script to set:
    - B2_REMOTE: Your B2 bucket name
    - HEALTHCHECK_URL: Your healthchecks.io ping URL

Example:
    $0                    # Run backup
    $0 --help            # Show help
    $0 --setup-healthchecks  # Setup guide

EOF
}

# Setup healthchecks.io helper
setup_healthchecks() {
    echo "=== Healthchecks.io Setup Guide ==="
    echo
    echo "1. Go to https://healthchecks.io and create a free account"
    echo "2. Create a new check with these settings:"
    echo "   - Name: Moodle+Koha Backup - $(hostname)"
    echo "   - Schedule: Simple, every 1 day"
    echo "   - Grace Time: 3 hours (gives backup time to complete)"
    echo
    echo "3. Copy your ping URL and add it to this script:"
    echo "   HEALTHCHECK_URL=\"https://hc-ping.com/YOUR-CHECK-UUID\""
    echo
    echo "4. Configure alerts in healthchecks.io:"
    echo "   - Email notifications"
    echo "   - Slack/Discord/Telegram webhooks"
    echo "   - SMS (premium feature)"
    echo
    echo "5. Optional: Set up multiple checks for different backup types"
    echo "   - Daily backup check (grace: 3 hours)"
    echo "   - Weekly backup check (grace: 6 hours)"
    echo "   - Monthly backup check (grace: 12 hours)"
    echo
    read -r -p "Press Enter to continue..."
}

# Test credentials loading
test_credentials() {
    echo "=== Testing Database Credentials Loading ==="
    echo
    
    setup_directories
    
    if load_db_credentials; then
        echo "✓ Credentials loaded successfully"
        echo "MariaDB root password length: ${#DB_ROOT_PASSWORD} characters"
        echo "Moodle DB password length: ${#MOODLE_DB_PASSWORD} characters"
        echo
        echo "Testing MariaDB connection..."
        if mysql -u root -p"$DB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
            echo "✓ MariaDB connection successful"
        else
            echo "✗ MariaDB connection failed"
            echo "This means the password extraction isn't working correctly"
        fi
    else
        echo "✗ Failed to load credentials"
        echo
        echo "Contents of credentials file:"
        if [ -f "$SITES_DIRECTORY/config/database-credentials.txt" ]; then
            cat "$SITES_DIRECTORY/config/database-credentials.txt"
        else
            echo "Credentials file not found at: $SITES_DIRECTORY/config/database-credentials.txt"
        fi
    fi
}

# Parse command line arguments
case "$1" in
    --test-credentials)
        test_credentials
        exit 0
        ;;
    --help)
        show_help
        exit 0
        ;;
    --setup-healthchecks)
        setup_healthchecks
        exit 0
        ;;
    "")
        # No arguments, continue with backup
        ;;
    *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
esac

# Main backup process
main() {
    # Signal start of backup
    ping_healthcheck "/start"
    
    log "=== Starting backup process ==="
    
    # Setup
    setup_directories
    
    # Load credentials with error handling
    if ! load_db_credentials; then
        local error_msg="Failed to load database credentials"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        exit 1
    fi
    
    # Pre-backup health check
    if ! pre_backup_health_check; then
        local error_msg="System not ready for backup"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        exit 1
    fi
    
    # Check disk space (require at least 5GB free)
    if ! check_disk_space 5000; then
        local error_msg="Insufficient disk space for backup"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        send_notification "FAILED" "$error_msg"
        exit 1
    fi
    
    # Perform backups with error handling
    if ! backup_moodle_database; then
        local error_msg="Moodle database backup failed"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        exit 1
    fi
    
    if ! backup_koha_database; then
        local error_msg="Koha database backup failed"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        exit 1
    fi
    
    if ! backup_moodle_files; then
        local error_msg="Moodle files backup failed"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        exit 1
    fi
    
    if ! backup_configs; then
        local error_msg="Configuration backup failed"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        exit 1
    fi
    
    # Additional backups
    backup_system_packages
    create_metadata
    
    # Upload to B2
    if upload_to_b2; then
        # Clean up if upload successful
        cleanup_local
        cleanup_b2
        
        # Calculate duration
        local duration=$(($(date +%s) - START_TIME))
        
        # Send success ping with summary
        local summary=$(cat << EOF
Backup completed successfully
Host: $(hostname)
Type: $([ "$DAY_OF_WEEK" = "7" ] && echo "weekly" || ([ "$(date +%d)" = "01" ] && echo "monthly" || echo "daily"))
Duration: $duration seconds
Size: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
EOF
)
        ping_healthcheck "" "$summary"
        
        log "=== Backup completed successfully ==="
        send_notification "SUCCESS" "Backup completed successfully"
    else
        local error_msg="Backup failed during B2 upload"
        error "$error_msg"
        ping_healthcheck "/fail" "$(format_healthcheck_error "$error_msg")"
        send_notification "FAILED" "$error_msg"
        exit 1
    fi
    
    # Log summary
    info "Backup summary:"
    info "- Total size: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "unknown")"
    info "- Duration: $duration seconds"
    info "- Log file: $LOG_FILE"
    info "- B2 location: $B2_REMOTE/$B2_PATH"
}

# Run main function
main

# Exit successfully
exit 0