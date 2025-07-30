# Netdata Monitoring for Moodle + Koha Server

A secure installation script that sets up Netdata monitoring with automatic HTTPS, secure authentication, and specific monitoring for Moodle and Koha applications.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [1. DNS Setup (Cloudflare Example)](#1-dns-setup-cloudflare-example)
  - [2. Installation](#2-installation)
  - [3. During Installation](#3-during-installation)
  - [4. Access Your Dashboard](#4-access-your-dashboard)
- [What's Monitored](#whats-monitored)
  - [System Metrics](#system-metrics)
  - [Application-Specific](#application-specific)
  - [Custom Alarms](#custom-alarms)
- [Command-Line Tools](#command-line-tools)
  - [Quick Resource Check](#quick-resource-check)
- [Scaling Guidelines](#scaling-guidelines)
  - [When to Scale](#when-to-scale)
- [Troubleshooting](#troubleshooting)
  - [Can't Access Dashboard](#cant-access-dashboard)
  - [Reset Credentials](#reset-credentials)
- [Security Notes](#security-notes)
- [Files and Locations](#files-and-locations)
- [Maintenance](#maintenance)
  - [Update Netdata](#update-netdata)
  - [Modify Alarms](#modify-alarms)
  - [Change Credentials](#change-credentials)
- [Additional Resources](#additional-resources)
- [Support](#support)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Features

- 🔐 **Secure by Default**: Generates random usernames and strong passwords
- 🚀 **Zero-Config Installation**: Automated setup with minimal user input
- 📊 **Application-Specific Monitoring**: Tracks Apache, PHP-FPM, MariaDB, and Koha processes
- 🔒 **HTTPS with Let's Encrypt**: Automatic SSL via Caddy reverse proxy
- 📈 **Performance Insights**: Custom alarms for CPU, memory, disk, and service health
- 🛠️ **Resource Check Tool**: Quick command-line resource monitoring

## Prerequisites

- Ubuntu server with Moodle + Koha already installed
- Access to the server
- A domain name with DNS management access
- Caddy web server installed and running

## Quick Start

### 1. DNS Setup (Cloudflare Example)

Add an A record for your monitoring subdomain:

- **Type**: A
- **Name**: `monitor` (or your preferred subdomain)
- **Content**: Your server's IP address
- **Proxy status**: DNS only (gray cloud, NOT proxied)
- **TTL**: Auto

> ⚠️ **Important**: Do NOT enable Cloudflare proxy as it interferes with Netdata's WebSocket connections.

### 2. Installation

```bash
# Download the script
sudo wget -O netdata-install.sh https://raw.githubusercontent.com/cmcndola/monitoring-and-backups/main/scripts/netdata-install.sh

# Make it executable
sudo chmod +x netdata-install.sh

# Run the installation
sudo ./netdata-install.sh
```

### 3. During Installation

You'll be prompted for:

- **Monitoring domain**: Enter your full domain (e.g., `monitor.example.com`)

The script will automatically:

- Generate secure credentials (username like `swift-golden-eagle`)
- Install and configure Netdata
- Set up HTTPS with Caddy
- Configure monitoring for your specific stack

### 4. Access Your Dashboard

After installation completes:

1. **Retrieve your credentials**:

   ```bash
   sudo cat /root/netdata-credentials.txt
   ```

2. **Access the dashboard**:

   - URL: `https://monitor.yourdomain.com`
   - Username: (generated, e.g., `brave-silver-eagle`)
   - Password: (generated 20-character string)

3. **Secure your credentials**:
   - Save to a password manager
   - Delete the credentials file:
     ```bash
     sudo shred -vfz /root/netdata-credentials.txt
     ```

## What's Monitored

### System Metrics

- CPU usage and load average
- Memory usage and swap
- Disk I/O and space
- Network traffic

### Application-Specific

- **Apache**: Request rate, response times, worker status
- **PHP-FPM**: Process count, memory usage
- **MariaDB**: Queries, connections, performance
- **Koha**: Zebra indexer, background jobs
- **Services**: Health status of all critical services

### Custom Alarms

- Apache/PHP-FPM/MySQL process monitoring
- High CPU usage (>80% warning, >90% critical)
- High memory usage (>80% warning, >90% critical)
- Low disk space (<20% warning, <10% critical)

## Command-Line Tools

### Quick Resource Check

```bash
check-resources
```

Shows:

- Current CPU and memory usage
- Disk usage
- Top processes by CPU and memory
- Service status
- Active users and load average

## Scaling Guidelines

Based on monitoring data:

| Concurrent Users | Recommended Server     | Metrics to Watch     |
| ---------------- | ---------------------- | -------------------- |
| 1-50             | CX22 (2 vCPU, 4GB)     | CPU < 70%, RAM < 80% |
| 50-100           | CX22 (2 vCPU, 4GB)     | CPU < 80%, RAM < 85% |
| 100-500          | CX31 (2 vCPU, 8GB)     | CPU < 80%, RAM < 80% |
| 500+             | CX41+ (4+ vCPU, 16GB+) | All metrics < 80%    |

### When to Scale

- **CPU consistently >80%**: Need more vCPUs
- **Memory usage >85%**: Need more RAM
- **Disk I/O wait >20%**: Need faster storage (consider dedicated server)
- **Apache workers maxed**: Optimize configs or scale up

## Troubleshooting

### Can't Access Dashboard

1. **Check DNS**:

   ```bash
   dig monitor.yourdomain.com
   ```

2. **Check services**:

   ```bash
   sudo systemctl status netdata caddy
   ```

3. **Check Caddy config**:

   ```bash
   sudo caddy validate --config /etc/caddy/Caddyfile
   ```

4. **View logs**:
   ```bash
   sudo journalctl -u netdata -f
   sudo journalctl -u caddy -f
   ```

### Reset Credentials

Re-run the installation script to generate new credentials:

```bash
sudo netdata-install.sh
```

## Security Notes

- Credentials are randomly generated with high entropy
- HTTPS is enforced via Caddy
- Basic auth protects the dashboard
- Netdata runs with minimal privileges
- No data is sent to external servers (telemetry disabled)

## Files and Locations

- **Netdata Config**: `/etc/netdata/netdata.conf`
- **Custom Alarms**: `/etc/netdata/health.d/custom.conf`
- **Caddy Config**: `/etc/caddy/Caddyfile`
- **Credentials**: `/root/netdata-credentials.txt` (delete after saving)
- **Resource Check**: `/usr/local/bin/check-resources`

## Maintenance

### Update Netdata

```bash
cd /tmp
wget -O netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
sh netdata-kickstart.sh --stable-channel --disable-telemetry
```

### Modify Alarms

Edit `/etc/netdata/health.d/custom.conf` and restart:

```bash
sudo systemctl restart netdata
```

### Change Credentials

1. Generate new password hash:

   ```bash
   caddy hash-password
   ```

2. Edit Caddyfile:

   ```bash
   sudo vim /etc/caddy/Caddyfile
   ```

3. Update the basicauth section and reload:
   ```bash
   sudo systemctl reload caddy
   ```

## Additional Resources

- [Netdata Documentation](https://learn.netdata.cloud/)
- [Netdata Configuration Guide](https://learn.netdata.cloud/docs/agent/daemon/config)
- [Custom Alarms Guide](https://learn.netdata.cloud/docs/monitor/configure-alarms)

## Support

For issues specific to this installation:

1. Check the troubleshooting section
2. Review service logs
3. Ensure DNS is properly configured
4. Verify all prerequisites are met

For Netdata-specific issues, consult the [official documentation](https://learn.netdata.cloud/).
