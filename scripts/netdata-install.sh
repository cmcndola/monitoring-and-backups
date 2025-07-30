#!/bin/bash

# Netdata Installation Script for Moodle + Koha Server
# This script installs Netdata with specific monitoring for your applications

set -e

# Colours for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

info() {
    echo -e "${BLUE}[SETUP]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)"
   exit 1
fi

# Function to generate random username
generate_random_username() {
    # Arrays of words for username generation
    local adjectives=("happy" "swift" "brave" "clever" "mighty" "gentle" "fierce" "quiet" "bold" "eager" "noble" "sharp" "smooth" "bright" "fresh" "crisp" "solid" "warm" "cool" "strong")
    local nouns=("falcon" "river" "mountain" "forest" "ocean" "thunder" "phoenix" "gorilla" "eagle" "tiger" "wolf" "bear" "hawk" "storm" "cloud" "star" "moon" "sun" "tree" "rock")
    local colors=("blue" "green" "red" "silver" "golden" "purple" "orange" "crystal" "cosmic" "electric" "mystic" "shadow" "light" "dark" "iron")
    
    # Select random words
    local adj=${adjectives[$RANDOM % ${#adjectives[@]}]}
    local color=${colors[$RANDOM % ${#colors[@]}]}
    local noun=${nouns[$RANDOM % ${#nouns[@]}]}
    
    # Combine with hyphens
    echo "${adj}-${color}-${noun}"
}

# Function to generate secure password
generate_secure_password() {
    # Generate a 20-character password with special characters
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-20
}

info "Installing Netdata for server monitoring..."

# Generate secure credentials
log "Generating secure credentials for Netdata access..."
NETDATA_USERNAME=$(generate_random_username)
NETDATA_PASSWORD=$(generate_secure_password)

# Save credentials to a secure file
CREDS_FILE="/root/netdata-credentials.txt"
cat > "$CREDS_FILE" << EOF
Netdata Monitoring Credentials
Generated: $(date)
==============================
Username: ${NETDATA_USERNAME}
Password: ${NETDATA_PASSWORD}
==============================
Keep these credentials secure!
EOF
chmod 600 "$CREDS_FILE"

log "Credentials saved to: $CREDS_FILE"

# Install Netdata using the official installer
log "Downloading and running Netdata installer..."
wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
sh /tmp/netdata-kickstart.sh --stable-channel --disable-telemetry

# Configure Netdata for your specific setup
log "Configuring Netdata for Moodle + Koha monitoring..."

# Create custom configuration directory
mkdir -p /etc/netdata/python.d/
mkdir -p /etc/netdata/go.d/

# Configure web access (bind to all interfaces for remote access)
cat > /etc/netdata/netdata.conf << 'EOF'
[global]
    # Reduce memory usage on small server
    page cache size = 32
    dbengine multihost disk space = 256
    
[web]
    # Allow access from any IP (we'll secure with Caddy)
    bind to = 0.0.0.0
    
    # Use a non-standard port to avoid conflicts
    default port = 19999
    
    # Enable gzip compression
    enable gzip compression = yes
    
[plugins]
    # Enable important plugins for your stack
    apps = yes
    cgroups = yes
    tc = no
    idlejitter = no
    
[health]
    # Enable health monitoring
    enabled = yes
    
    # Reduce noise - only alert on important issues
    default repeat warning = 30m
    default repeat critical = 10m
EOF

# Monitor specific processes for Moodle and Koha
cat > /etc/netdata/apps_groups.conf << 'EOF'
# Netdata process grouping configuration
# Format: group_name: process names

# Web Servers
apache: apache2
caddy: caddy

# PHP
php: php-fpm8.3 php8.3

# Databases
mysql: mysqld mariadb

# Koha specific
koha: koha-* zebrasrv

# System
system: systemd networkd resolved
sshd: sshd
cron: cron

# Package management
apt: apt dpkg
EOF

# Configure MySQL monitoring
log "Setting up MySQL monitoring..."
# Load DB password from the environment or config file
if [ -f /var/www/config/database-credentials.txt ]; then
    DB_ROOT_PASSWORD=$(grep "Password:" /var/www/config/database-credentials.txt | grep "MariaDB Root" -A1 | tail -1 | awk '{print $2}')
fi

if [ -n "$DB_ROOT_PASSWORD" ]; then
    mysql -u root -p"${DB_ROOT_PASSWORD}" << 'EOF' 2>/dev/null || true
CREATE USER IF NOT EXISTS 'netdata'@'localhost';
GRANT USAGE, REPLICATION CLIENT, PROCESS ON *.* TO 'netdata'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    warn "Could not find MariaDB root password. Skipping MySQL monitoring setup."
fi

# Create MySQL config for Netdata
cat > /etc/netdata/go.d/mysql.conf << 'EOF'
jobs:
  - name: local
    dsn: netdata@unix(/var/run/mysqld/mysqld.sock)/
EOF

# Configure Apache monitoring (for Koha)
log "Configuring Apache monitoring..."
cat > /etc/apache2/mods-available/status.conf << 'EOF'
<IfModule mod_status.c>
    <Location /server-status>
        SetHandler server-status
        Require local
    </Location>
    ExtendedStatus On
</IfModule>
EOF

# Enable Apache status module
a2enmod status
systemctl reload apache2

# Configure systemd monitoring
cat > /etc/netdata/go.d/systemdunits.conf << 'EOF'
jobs:
  - name: systemd
    include:
      - apache2.service
      - caddy.service
      - mariadb.service
      - php8.3-fpm.service
      - koha-common.service
      - cron.service
EOF

# Add Caddy reverse proxy configuration for Netdata
log "Adding Netdata to Caddy configuration..."

# Get the monitoring domain from user
echo
read -r -p "Enter domain for Netdata monitoring (e.g., monitor.example.com): " MONITOR_DOMAIN

# Generate password hash for Caddy
log "Generating password hash for Caddy basic auth..."
# Create a temporary script to handle the password hashing
cat > /tmp/hash_password.sh << 'EOF'
#!/bin/bash
# Caddy expects passwords to be hashed with bcrypt
# We'll use htpasswd from apache2-utils which should already be installed
password="$1"
# Use htpasswd to generate bcrypt hash, extract just the hash part
htpasswd -nbB temp_user "$password" | cut -d: -f2
EOF
chmod +x /tmp/hash_password.sh

# Generate the password hash
HASHED_PASSWORD=$(/tmp/hash_password.sh "$NETDATA_PASSWORD")
rm /tmp/hash_password.sh

# Backup current Caddyfile
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup-netdata

# Add Netdata configuration to Caddyfile
cat >> /etc/caddy/Caddyfile << EOF

# Netdata Monitoring Dashboard
${MONITOR_DOMAIN} {
    reverse_proxy localhost:19999
    
    # Basic authentication for security
    basicauth /* {
        # Generated secure credentials
        ${NETDATA_USERNAME} ${HASHED_PASSWORD}
    }
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }
    
    encode gzip
    
    log {
        format console
    }
}
EOF

# Reload Caddy
systemctl reload caddy

# Configure Netdata alarms for your specific needs
log "Configuring custom alarms..."

# Create custom alarm configuration
cat > /etc/netdata/health.d/custom.conf << 'EOF'
# Custom alarms for Moodle + Koha server

# Alert if Apache is down
alarm: apache_process
    on: apps.processes
    os: linux
    lookup: min -1m unaligned of apache
    units: processes
    every: 10s
    crit: $this == 0
    info: Apache web server is not running
    to: sysadmin

# Alert if PHP-FPM is down
alarm: php_fpm_process
    on: apps.processes
    os: linux
    lookup: min -1m unaligned of php
    units: processes
    every: 10s
    crit: $this == 0
    info: PHP-FPM is not running
    to: sysadmin

# Alert if MySQL is down
alarm: mysql_process
    on: apps.processes
    os: linux
    lookup: min -1m unaligned of mysql
    units: processes
    every: 10s
    crit: $this == 0
    info: MySQL/MariaDB is not running
    to: sysadmin

# Alert on high memory usage (>85%)
alarm: ram_usage
    on: system.ram
    os: linux
    lookup: average -1m percentage of used
    units: %
    every: 10s
    warn: $this > 80
    crit: $this > 90
    info: System RAM usage is high
    to: sysadmin

# Alert on high CPU usage (>85% for 5 minutes)
alarm: cpu_usage
    on: system.cpu
    os: linux
    lookup: average -5m percentage of user,system,nice,softirq,irq,guest,steal
    units: %
    every: 1m
    warn: $this > 80
    crit: $this > 90
    info: System CPU usage is high
    to: sysadmin

# Alert on low disk space (<10% free)
alarm: disk_space_root
    on: disk.space
    os: linux
    families: /
    lookup: average -1m percentage of avail
    units: %
    every: 1m
    warn: $this < 20
    crit: $this < 10
    info: Root filesystem space is low
    to: sysadmin
EOF

# Restart Netdata to apply all configurations
log "Restarting Netdata..."
systemctl restart netdata
systemctl enable netdata

# Create a simple resource check script
log "Creating resource monitoring script..."
cat > /usr/local/bin/check-resources << EOF
#!/bin/bash
# Quick resource check for Moodle + Koha server

echo "=== Server Resource Status ==="
echo
echo "CPU Usage:"
top -bn1 | grep "Cpu(s)" | awk '{print "  Total: " 100-$8 "%"}'
echo
echo "Memory Usage:"
free -h | grep "^Mem:" | awk '{print "  Total: " \$2 "\n  Used: " \$3 " (" int(\$3/\$2 * 100) "%)\n  Available: " \$7}'
echo
echo "Disk Usage:"
df -h / | tail -1 | awk '{print "  Total: " \$2 "\n  Used: " \$3 " (" \$5 ")\n  Available: " \$4}'
echo
echo "Top 5 CPU Processes:"
ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "  %-20s %5s%%\n", \$11, \$3}'
echo
echo "Top 5 Memory Processes:"
ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "  %-20s %5s%%\n", \$11, \$4}'
echo
echo "Service Status:"
for service in apache2 caddy mariadb php8.3-fpm koha-common; do
    if systemctl is-active --quiet \$service; then
        echo "  ✓ \$service"
    else
        echo "  ✗ \$service (not running)"
    fi
done
echo
echo "Active Users: \$(who | wc -l)"
echo "Load Average: \$(uptime | awk -F'load average:' '{print \$2}')"
echo
echo "For detailed monitoring, visit: https://${MONITOR_DOMAIN}"
echo "(Credentials stored in: $CREDS_FILE)"
EOF

chmod +x /usr/local/bin/check-resources

# Display summary
echo
echo "=============================================="
echo -e "${GREEN}✅ Netdata Monitoring Installed Successfully!${NC}"
echo "=============================================="
echo
echo -e "${RED}🔐 IMPORTANT - SECURE CREDENTIALS GENERATED:${NC}"
echo "Username: ${NETDATA_USERNAME}"
echo "Password: ${NETDATA_PASSWORD}"
echo
echo "These credentials have been saved to:"
echo "  ${CREDS_FILE}"
echo
echo -e "${BLUE}📊 Access Methods:${NC}"
echo "1. Web Dashboard: https://${MONITOR_DOMAIN}"
echo "   Use the credentials shown above"
echo
echo "2. Direct Access: http://<server-ip>:19999"
echo "   (Only if firewall allows port 19999)"
echo
echo "3. Quick Check: Run 'check-resources' command"
echo
echo -e "${BLUE}📈 What to Monitor for Scaling:${NC}"
echo "• CPU Usage > 80% consistently → Need more vCPUs"
echo "• Memory Usage > 85% → Need more RAM"
echo "• Disk I/O Wait > 20% → Need faster storage"
echo "• Apache/PHP workers maxed → Need optimization or scaling"
echo
echo -e "${BLUE}🔍 Key Metrics for Your Setup:${NC}"
echo "• System Overview → Overall health"
echo "• Applications → Apache, PHP, MySQL performance"
echo "• Users → Active Moodle/Koha sessions"
echo "• MySQL → Query performance and connections"
echo "• Apache → Request rate and response times"
echo
echo -e "${YELLOW}💡 Performance Tips:${NC}"
echo "• Current server: 2 vCPU, 4GB RAM"
echo "• Can handle ~50-100 concurrent users"
echo "• For 100-500 users: Upgrade to CX31 (2 vCPU, 8GB)"
echo "• For 500+ users: Consider CX41 or higher"
echo
echo "DNS Setup Required:"
echo "  ${MONITOR_DOMAIN} → $(curl -s ifconfig.me 2>/dev/null || echo '<server-ip>')"
echo
echo -e "${YELLOW}⚠️  Security Notes:${NC}"
echo "• Keep the credentials file secure: $CREDS_FILE"
echo "• Consider moving credentials to a password manager after viewing"
echo "• The password is randomly generated and highly secure"
echo "• You can regenerate credentials by re-running this script"
echo "=============================================="

log "Netdata installation complete!"