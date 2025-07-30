# Backup & Restore Setup Guide

## Overview

This guide sets up automated backups with:

- ✅ Separate backup and restore scripts
- ✅ Healthchecks.io monitoring (alerts on failure)
- ✅ Automated daily/weekly/monthly backups
- ✅ Secure B2 cloud storage
- ✅ Easy restore process

## Step 1: Set Up Healthchecks.io

### Create Your Healthcheck

1. **Sign up** at [healthchecks.io](https://healthchecks.io) (free tier is sufficient)

2. **Create a new check**:

   - Click "New Check"
   - Name: `Moodle+Koha Backup - your-server-name`
   - Schedule: **Simple**
   - Period: **1 day**
   - Grace Time: **3 hours** (allows time for large backups)

3. **Copy your ping URL**:

   ```
   https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

4. **Configure notifications**:
   - Add your email
   - Optional: Add Slack, Discord, Telegram, etc.

### Optional: Create Multiple Checks

For granular monitoring, create separate checks:

- Daily Backup (1 day period, 3 hour grace)
- Weekly Backup (7 day period, 6 hour grace)
- Monthly Backup (30 day period, 12 hour grace)

## Step 2: Install the Scripts

```bash
# Create scripts directory
sudo mkdir -p /usr/local/scripts

# Download backup script
sudo wget -O /usr/local/scripts/backup.sh \
  https://raw.githubusercontent.com/cmcndola/monitoring-and-backups/main/scripts/backup.sh

# Download restore script
sudo wget -O /usr/local/scripts/restore.sh \
  https://raw.githubusercontent.com/cmcndola/monitoring-and-backups/main/scripts/restore.sh

# Make executable
sudo chmod +x /usr/local/scripts/backup.sh
sudo chmod +x /usr/local/scripts/restore.sh
```

## Step 3: Configure the Scripts

### Update backup.sh

```bash
sudo vim /usr/local/scripts/backup.sh
```

Change these lines:

```bash
# B2 Configuration
B2_REMOTE="b2:your-bucket-name"  # Your actual B2 bucket

# Healthchecks.io Configuration
HEALTHCHECK_URL="https://hc-ping.com/your-uuid-here"  # Your ping URL
```

### Update restore.sh

```bash
sudo vim /usr/local/scripts/restore.sh
```

Change:

```bash
B2_REMOTE="b2:your-bucket-name"  # Same as backup.sh
```

## Step 4: Test the Backup

### Manual Test

```bash
# Run backup manually
sudo /usr/local/scripts/backup.sh

# Check healthchecks.io dashboard - should show success
# Check B2 bucket - should have new backup
```

### Verify Healthchecks.io

1. Go to your healthchecks.io dashboard
2. You should see:
   - Green status (successful ping)
   - Last ping time
   - Success message in log

## Step 5: Schedule Automated Backups

```bash
# Edit root's crontab
sudo crontab -e

# Add this line for daily backups at 2:30 AM
30 2 * * * /usr/local/scripts/backup.sh >/dev/null 2>&1
```

### Advanced: Different Schedules

For separate daily/weekly/monthly with different healthcheck URLs:

```bash
# Daily at 2:30 AM
30 2 * * * HEALTHCHECK_URL="https://hc-ping.com/daily-uuid" /usr/local/scripts/backup.sh

# Weekly on Sunday at 3:30 AM
30 3 * * 0 HEALTHCHECK_URL="https://hc-ping.com/weekly-uuid" /usr/local/scripts/backup.sh

# Monthly on 1st at 4:30 AM
30 4 1 * * HEALTHCHECK_URL="https://hc-ping.com/monthly-uuid" /usr/local/scripts/backup.sh
```

## Step 6: Test Failure Notifications

### Simulate a Failure

```bash
# Temporarily rename credentials file
sudo mv /var/www/config/database-credentials.txt /var/www/config/database-credentials.txt.bak

# Run backup (will fail)
sudo /usr/local/scripts/backup.sh

# Restore credentials
sudo mv /var/www/config/database-credentials.txt.bak /var/www/config/database-credentials.txt
```

You should receive:

- ❌ Failure notification from healthchecks.io
- 📧 Email/Slack/etc alert
- 📋 Error details in the notification

## Step 7: Using the Restore Script

### List Available Backups

```bash
sudo /usr/local/scripts/restore.sh --list
```

### Restore Latest Daily Backup

```bash
sudo /usr/local/scripts/restore.sh --latest daily
```

### Restore Specific Date

```bash
sudo /usr/local/scripts/restore.sh --date 20240115
```

### Interactive Restore

```bash
sudo /usr/local/scripts/restore.sh
# Follow the prompts
```

## Monitoring & Maintenance

### Check Backup Status

```bash
# View recent backup logs
ls -la /var/log/backups/

# Check last backup time
stat /var/run/last_backup_timestamp

# Monitor B2 storage usage
rclone size b2:your-bucket/backups/
```

### Add to Netdata Monitoring

If you have Netdata installed:

```bash
# Create backup age check
sudo cat >> /usr/local/bin/check-resources << 'EOF'

# Backup Status
echo
echo "Backup Status:"
if [ -f /var/run/last_backup_timestamp ]; then
    last_backup=$(stat -c %Y /var/run/last_backup_timestamp)
    current_time=$(date +%s)
    hours_ago=$(( (current_time - last_backup) / 3600 ))
    echo "  Last backup: $hours_ago hours ago"
else
    echo "  Last backup: Never"
fi
EOF
```

### Regular Maintenance

**Monthly**:

- Review backup logs
- Check B2 storage usage
- Verify healthchecks.io is working

**Quarterly**:

- Test restore process
- Review retention policies
- Update documentation

**Annually**:

- Full disaster recovery drill
- Review and optimize backup size
- Audit security settings

## Troubleshooting

### Backup Fails Silently

1. Check cron is running:

   ```bash
   sudo systemctl status cron
   ```

2. Check cron logs:

   ```bash
   sudo grep CRON /var/log/syslog | grep backup
   ```

3. Run manually with debugging:
   ```bash
   sudo bash -x /usr/local/scripts/backup.sh
   ```

### Healthchecks.io Not Receiving Pings

1. Test connectivity:

   ```bash
   curl -v https://hc-ping.com/your-uuid
   ```

2. Check URL is correct in script

3. Ensure server can reach internet

### B2 Upload Fails

1. Verify rclone config:

   ```bash
   sudo rclone config show
   sudo rclone lsd b2:your-bucket
   ```

2. Check credentials and permissions

3. Test with small file:
   ```bash
   echo "test" > /tmp/test.txt
   sudo rclone copy /tmp/test.txt b2:your-bucket/test/
   ```

## Security Best Practices

1. **Protect Scripts**:

   ```bash
   sudo chmod 700 /usr/local/scripts/backup.sh
   sudo chmod 700 /usr/local/scripts/restore.sh
   ```

2. **Secure B2 Credentials**:

   ```bash
   sudo chmod 600 /root/.config/rclone/rclone.conf
   ```

3. **Limit B2 Key Permissions**:

   - Use application key (not master key)
   - Restrict to specific bucket
   - Enable lifecycle rules

4. **Test Restore Regularly**:
   - Schedule quarterly restore tests
   - Document restore times
   - Practice full recovery

## Cost Optimization

With B2 pricing:

- Storage: $6/TB/month
- Download: $10/TB

Tips to minimize costs:

1. Exclude unnecessary files (cache, temp)
2. Use compression (already implemented)
3. Adjust retention periods
4. Monitor growth trends

## Next Steps

1. ✅ Scripts installed and configured
2. ✅ Healthchecks.io monitoring active
3. ✅ Automated backups scheduled
4. ✅ Restore process tested
5. 📅 Schedule quarterly restore drills
6. 📊 Add to your monitoring dashboard
