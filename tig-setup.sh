#!/bin/bash
set -euo pipefail

# =============================================================================
# TiG Stack Setup Script (Telegraf, InfluxDB, Grafana)
# Supports: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, Fedora, Oracle Linux, OpenSUSE/SLES
# =============================================================================

# --- Configuration ---
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

# Global state variables
OS=""
DISTRO=""
PKG_MGR=""
CMD_PKG_INSTALL=""
CMD_PKG_UPDATE=""

# --- Logging Helpers ---

function log() {
    echo -e "\033[0;32m[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1\033[0m"
}

function warn() {
    echo -e "\033[0;33m[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1\033[0m"
}

function error_exit {
    echo -e "\033[0;31m[ERROR] $1\033[0m" >&2
    exit 1
}

# --- System Detection ---

function detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=${ID:-linux}
        DISTRO=${VERSION_CODENAME:-}
    else
        error_exit "/etc/os-release not found. Unsupported OS."
    fi

    log "Detected OS: $OS ($VERSION_ID)"

    case "$OS" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            CMD_PKG_UPDATE="sudo apt-get update"
            CMD_PKG_INSTALL="sudo apt-get install -y"
            ;;
        centos|rhel|almalinux|rocky|fedora|ol)
            PKG_MGR="dnf"
            CMD_PKG_UPDATE="sudo dnf check-update || true" # dnf check-update returns 100 on updates avail
            CMD_PKG_INSTALL="sudo dnf install -y"
            ;;
        opensuse*|sles)
            PKG_MGR="zypper"
            CMD_PKG_UPDATE="sudo zypper refresh"
            CMD_PKG_INSTALL="sudo zypper install -y"
            ;;
        *)
            error_exit "Unsupported Operating System: $OS"
            ;;
    esac
}

# --- Dependency Management ---

function install_pkg() {
    local packages="$*"
    log "Installing packages: $packages"
    $CMD_PKG_INSTALL $packages
}

function check_and_install_deps() {
    log "Checking system dependencies..."
    local deps_missing=""
    
    # Map command names to package names where they differ
    declare -A cmd_map
    cmd_map=( ["openssl"]="openssl" ["curl"]="curl" ["gpg"]="gnupg" )

    # Adjust for specific distros if needed (e.g. some might name it differently)
    # For now, these are quite standard across the supported distros.

    for cmd in "${!cmd_map[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            deps_missing="$deps_missing ${cmd_map[$cmd]}"
        fi
    done

    if [ -n "$deps_missing" ]; then
        log "Missing dependencies found: $deps_missing"
        $CMD_PKG_UPDATE
        install_pkg $deps_missing
        
        # Verify
        for cmd in "${!cmd_map[@]}"; do
             if ! command -v "$cmd" &> /dev/null; then
                 # Try hashing to clear cache
                 hash -r
                 if ! command -v "$cmd" &> /dev/null; then
                     warn "Command '$cmd' still not found after installation. Proceeding with caution..."
                 fi
             fi
        done
    else
        log "All system dependencies met."
    fi
}

# --- Docker Installation ---

function install_docker() {
    if command -v docker &> /dev/null; then
        log "Docker is already installed."
        # Check for compose
        if docker compose version &>/dev/null; then
            return 0
        else
            log "Docker Compose plugin missing. Attempting to fix..."
        fi
    else
        log "Installing Docker..."
    fi

    case "$PKG_MGR" in
        apt-get)
            $CMD_PKG_UPDATE
            install_pkg ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            sudo rm -f /etc/apt/keyrings/docker.gpg
            curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            $CMD_PKG_UPDATE
            install_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        dnf)
            # Handle RHEL/CentOS derivatives mapping
            local docker_repo_os="$OS"
            if [[ "$OS" =~ ^(almalinux|rocky|rhel|ol)$ ]]; then
                docker_repo_os="centos"
            fi
            
            install_pkg dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/$docker_repo_os/docker-ce.repo
            install_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        zypper)
            # OpenSUSE / SLES 
            log "Configuring Docker for OpenSUSE/SLES..."
            sudo zypper addrepo --check --refresh https://download.docker.com/linux/sles/docker-ce.repo || true
            sudo zypper --gpg-auto-import-keys refresh
            
            # Try Docker CE first
            if ! sudo zypper install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
                warn "Failed to install Docker CE from official repo. Falling back to distro packages..."
                install_pkg docker
                
                # Check for compose
                if ! install_pkg docker-compose-plugin; then
                     warn "docker-compose-plugin package not found. Installing binary manually..."
                     install_manual_compose
                fi
            fi
            ;;
    esac

    # Post-install Setup
    log "Starting Docker service..."
    start_docker_service
    
    # Add user to group
    if ! getent group docker > /dev/null; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker "$USER"
    log "User $USER added to 'docker' group."
}

function install_manual_compose() {
    local DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker/cli-plugins}
    sudo mkdir -p $DOCKER_CONFIG
    sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) -o $DOCKER_CONFIG/docker-compose
    sudo chmod +x $DOCKER_CONFIG/docker-compose
    sudo ln -sf $DOCKER_CONFIG/docker-compose /usr/local/bin/docker-compose
}

function start_docker_service() {
    # 1. Systemd Check
    if sudo systemctl --version >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        sudo systemctl enable --now docker
        return
    fi
    
    # 2. Legacy Service Check
    if command -v service >/dev/null; then
        log "Systemd not active. Trying 'service' command..."
        sudo service docker start || true
    fi
    
    # 3. Validation & WSL Help
    if ! sudo docker info >/dev/null 2>&1; then
        if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null; then
             echo ""
             error_exit "Docker failed to start.
--------------------------------------------------------------------------------
DETECTED WSL ENVIRONMENT WITHOUT SYSTEMD
You must enable systemd for Docker to work correctly.

1. Edit wsl.conf:  sudo nano /etc/wsl.conf
2. Add these lines:
   [boot]
   systemd=true
3. Restart WSL:    wsl --shutdown (in PowerShell)
--------------------------------------------------------------------------------"
        fi
        error_exit "Docker failed to start. Please check system logs."
    fi
}

function check_firewall() {
    if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
        log "Configuring UFW..."
        sudo ufw allow 8086/tcp
        sudo ufw allow 3000/tcp
    elif command -v firewall-cmd >/dev/null && sudo firewall-cmd --state &>/dev/null; then
        log "Configuring Firewalld..."
        sudo firewall-cmd --permanent --add-port=8086/tcp
        sudo firewall-cmd --permanent --add-port=3000/tcp
        sudo firewall-cmd --reload
    fi
}

# --- Configuration Generators ---

function generate_env() {
    log "Generating Environment Variables..."
    
    # Credentials
    if [ ! -f .env.influxdb-admin-username ]; then
        read -p "InfluxDB Admin Username: " admuser
        echo "$admuser" > .env.influxdb-admin-username
    fi
    
    if [ ! -f .env.influxdb-admin-password ]; then
        while true; do
            read -s -p "InfluxDB Admin Password (8+ chars): " admpass
            echo
            if [ ${#admpass} -ge 8 ]; then break; fi
            warn "Password too short."
        done
        echo "$admpass" > .env.influxdb-admin-password
    fi
    
    if [ ! -f .env.influxdb-admin-token ]; then
        echo "$(openssl rand -hex 32)" > .env.influxdb-admin-token
        log "Generated new InfluxDB Token."
    fi
    
    # Settings (Memory only for current run, unless persisted)
    if [ -z "${INFLUX_ORG:-}" ]; then
        read -p "InfluxDB Org Name [docs]: " input_org
        export INFLUX_ORG=${input_org:-docs}
    fi
    
    if [ -z "${INFLUX_BUCKET:-}" ]; then
        read -p "InfluxDB Bucket Name [home]: " input_bucket
        export INFLUX_BUCKET=${input_bucket:-home}
    fi
}

function gen_configs() {
    log "Generating Config Files..."
    mkdir -p influxdb/data influxdb/config
    mkdir -p telegraf-config/telegraf.d

    # Telegraf
    if [ ! -f telegraf-config/telegraf.conf ]; then
        cat <<EOF > telegraf-config/telegraf.conf
[global_tags]
  server_name = "$(hostname)"
[agent]
  interval = "30s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = "0s"
  hostname = ""
  omit_hostname = false
EOF
    fi

    if [ ! -f telegraf-config/telegraf.d/100-inputs.conf ]; then
        cat <<EOF > telegraf-config/telegraf.d/100-inputs.conf
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false
[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]
[[inputs.diskio]]
[[inputs.mem]]
[[inputs.net]]
[[inputs.system]]
EOF
    fi
    
    # Telegraf Output (Regen if force or missing)
    if [ -f .env.influxdb-admin-token ]; then
        local token=$(cat .env.influxdb-admin-token)
        cat <<EOF > telegraf-config/telegraf.d/000-influxdb.conf
[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "$token"
  organization = "${INFLUX_ORG:-docs}"
  bucket = "${INFLUX_BUCKET:-home}"
EOF
    fi
    
    # Docker Compose
    cat <<EOF > docker-compose.yml
services:
  influxdb:
    image: influxdb:latest
    container_name: influxdb
    ports: ["8086:8086"]
    environment:
      INFLUXDB_HTTP_AUTH_ENABLED: "true"
      DOCKER_INFLUXDB_INIT_MODE: setup
      DOCKER_INFLUXDB_INIT_USERNAME_FILE: /run/secrets/influxdb-admin-username
      DOCKER_INFLUXDB_INIT_PASSWORD_FILE: /run/secrets/influxdb-admin-password
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN_FILE: /run/secrets/influxdb-admin-token
      DOCKER_INFLUXDB_INIT_ORG: ${INFLUX_ORG:-docs}
      DOCKER_INFLUXDB_INIT_BUCKET: ${INFLUX_BUCKET:-home}
    secrets:
      - influxdb-admin-username
      - influxdb-admin-password
      - influxdb-admin-token
    volumes:
      - ./influxdb/data:/var/lib/influxdb2
      - ./influxdb/config:/etc/influxdb2
    restart: unless-stopped

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    ports: ["3000:3000"]
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - influxdb
    restart: unless-stopped

  telegraf:
    image: telegraf:latest
    container_name: telegraf
    depends_on:
      - influxdb
    volumes:
      - ./telegraf-config/telegraf.d:/etc/telegraf/telegraf.d:ro
      - ./telegraf-config/telegraf.conf:/etc/telegraf/telegraf.conf:ro
    restart: unless-stopped

volumes:
  influxdb-data:
  influxdb-config:
  grafana-data:

secrets:
  influxdb-admin-username:
    file: .env.influxdb-admin-username
  influxdb-admin-password:
    file: .env.influxdb-admin-password
  influxdb-admin-token:
    file: .env.influxdb-admin-token

networks:
  default:
    name: tig-network
EOF
}

# --- Health Checks ---

function wait_for_services() {
    log "Pulling and Starting Services..."
    sudo docker compose pull
    sudo docker compose up -d

    log "Waiting for InfluxDB health..."
    local retries=30
    local count=0
    until curl -s "http://localhost:8086/health" | grep -q '"status":"pass"'; do
        sleep 2
        echo -n "."
        count=$((count+1))
        if [ $count -ge $retries ]; then
            echo ""
            error_exit "Timeout waiting for InfluxDB to start."
        fi
    done
    echo ""
    log "InfluxDB is Healthy."
}

# --- Main ---

log "Starting TiG Stack Setup..."
detect_os
check_and_install_deps
install_docker
check_firewall

# Setup App
generate_env
gen_configs
wait_for_services

log "========================================================"
log "Installation Finished Successfully."
log "Grafana:  http://localhost:3000 (default: admin/admin)"
log "InfluxDB: http://localhost:8086"
log "Token:    $(cat .env.influxdb-admin-token)"
log "========================================================"