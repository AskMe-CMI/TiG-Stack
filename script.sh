#!/bin/bash
set -euo pipefail

# Global variables
OS=""
PKG_MGR=""
DISTRO=""

function log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

function error_exit {
    echo "[ERROR] $1" >&2
    exit 1
}

function check_os {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=${ID:-linux}
        DISTRO=${VERSION_CODENAME:-}
    else
        error_exit "/etc/os-release not found. Unsupported OS."
    fi

    if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
        PKG_MGR="apt-get"
    elif [[ "$OS" =~ ^(centos|rhel|almalinux|rocky|fedora)$ ]]; then
        PKG_MGR="dnf"
    else
        error_exit "Unsupported OS: $OS"
    fi
}

function install_docker {
    log "Installing Docker..."

    if [[ "$PKG_MGR" == "apt-get" ]]; then
        # Ubuntu/Debian
        sudo $PKG_MGR update
        sudo $PKG_MGR install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        
        # Remove old key if exists to ensure freshness
        sudo rm -f /etc/apt/keyrings/docker.gpg
        curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        # Add the repository to Apt sources:
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo $PKG_MGR update
        sudo $PKG_MGR install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif [[ "$PKG_MGR" == "dnf" ]]; then
        # CentOS/RHEL/Fedora/AlmaLinux/Rocky
        # Docker doesn't have specific repos for Alma/Rocky, they use CentOS
        if [[ "$OS" =~ ^(almalinux|rocky|rhel|centos)$ ]]; then
            DOCKER_REPO_OS="centos"
        else
            DOCKER_REPO_OS="$OS"
        fi
        
        sudo $PKG_MGR install -y dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/$DOCKER_REPO_OS/docker-ce.repo
        sudo $PKG_MGR install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    log "Starting Docker service..."
    sudo systemctl enable --now docker
    
    # Check if docker is running
    if ! systemctl is-active --quiet docker; then
         error_exit "Docker failed to start."
    fi
    
    log "Docker installed and running successfully."
}

function add_user_to_docker {
    log "Adding user $USER to docker group..."
    if ! getent group docker > /dev/null; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker "$USER"
}

function check_firewall {
    log "Checking firewall..."
    if command -v ufw >/dev/null; then
        if sudo ufw status | grep -q "Status: active"; then
            sudo ufw allow 22/tcp  # Always good to ensure SSH is allowed
            sudo ufw allow 8086/tcp # InfluxDB
            sudo ufw allow 3000/tcp # Grafana
            log "Configured UFW firewall rules."
        fi
    elif command -v firewall-cmd >/dev/null; then
        if sudo firewall-cmd --state &>/dev/null; then
            sudo firewall-cmd --permanent --add-port=8086/tcp
            sudo firewall-cmd --permanent --add-port=3000/tcp
            sudo firewall-cmd --reload
            log "Configured firewalld rules."
        fi
    fi
}

function generate_docker_compose {
    log "Generating docker-compose.yml..."
    # Always regenerate to ensure variables are updated
    cat <<EOF | tee docker-compose.yml > /dev/null
services:

  influxdb:
    image: influxdb:latest
    container_name: influxdb
    ports:
      - "8086:8086"
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
    ports:
      - "3000:3000"
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

function create_folder {
    local m_path=$1
    mkdir -p "$m_path"
}

function gen_telegraf {
    create_folder telegraf-config
    create_folder telegraf-config/telegraf.d
    
    # 1. Main Config with Global Tags
    if [ ! -f telegraf-config/telegraf.conf ]; then
        log "Creating basic Telegraf config..."
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

    # 2. System Inputs (CPU, Mem, Disk, Net)
    # Fixes "no inputs found" error
    if [ ! -f telegraf-config/telegraf.d/100-inputs.conf ]; then
        log "Creating system metrics inputs..."
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

    # 3. Output to InfluxDB
    if [ -f .env.influxdb-admin-token ]; then
        RDTOKEN=$(cat .env.influxdb-admin-token)
        # Use globally set INFLUX_ORG and INFLUX_BUCKET
        if [ ! -f telegraf-config/telegraf.d/000-influxdb.conf ] || [ "$FORCE_REGEN" == "true" ]; then
            log "Configuring Telegraf output..."
             
            cat <<EOF > telegraf-config/telegraf.d/000-influxdb.conf
[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "$RDTOKEN"
  organization = "${INFLUX_ORG:-docs}"
  bucket = "${INFLUX_BUCKET:-home}"
EOF
        fi
    fi
}

function gen_influxdb {
    create_folder influxdb
    create_folder influxdb/data
    create_folder influxdb/config
}

function generate_envfile {
    if [ ! -f .env.influxdb-admin-username ]; then
        read -p "InfluxDB admin username: " admuser
        echo "$admuser" > .env.influxdb-admin-username
    fi

    if [ ! -f .env.influxdb-admin-password ]; then
        while true; do
            read -s -p "InfluxDB admin password (8-72 chars): " admpass
            echo
            len=${#admpass}
            if [ "$len" -ge 8 ] && [ "$len" -le 72 ]; then
                break
            else
                echo "Password length must be between 8 and 72 characters."
            fi
        done
        echo "$admpass" > .env.influxdb-admin-password
    fi
    
    if [ ! -f .env.influxdb-admin-token ]; then
        INFLUX_TOKEN=$(openssl rand -hex 32)
        echo "$INFLUX_TOKEN" > .env.influxdb-admin-token
		log "Generated InfluxDB Token: success"
        
    fi
    
    # Prompt for Org and Bucket here to ensure they are available for both compose and telegraf
    # We don't save these to files unless we want to persist them across runs, 
    # but for now we'll just prompt if not set.
    if [ -z "${INFLUX_ORG:-}" ]; then
        read -p "InfluxDB Organization Name [docs]: " input_org
        INFLUX_ORG=${input_org:-docs}
    fi
    
    if [ -z "${INFLUX_BUCKET:-}" ]; then
        read -p "InfluxDB Bucket Name [home]: " input_bucket
        INFLUX_BUCKET=${input_bucket:-home}
    fi
}



function rundocker {
    log "Pulling Docker images..."
    sudo docker compose pull
    
    log "Starting TIG Stack with Docker Compose..."
    sudo docker compose up -d
}

function checkup_influx {
    log "Waiting for InfluxDB to be ready..."
    INFLUXCNF="./telegraf-config/telegraf.d/000-influxdb.conf"
    
    # Attempt to read creds
    local user=$(cat .env.influxdb-admin-username)
    local pass=$(cat .env.influxdb-admin-password)
    local token=$(cat .env.influxdb-admin-token)
    
    # Try to extract from config if available, otherwise default
    local org="docs"
    local bket="home"
    if [ -f "$INFLUXCNF" ]; then
        org_grep=$(grep -E '^\s*organization\s*=' "$INFLUXCNF" | sed -E 's/.*=\s*"(.*)"/\1/')
        bket_grep=$(grep -E '^\s*bucket\s*=' "$INFLUXCNF" | sed -E 's/.*=\s*"(.*)"/\1/')
        [ -n "$org_grep" ] && org=$org_grep
        [ -n "$bket_grep" ] && bket=$bket_grep
    fi

    HOST_URL="http://localhost:8086"
    
    # Wait loop
    local retries=30
    local count=0
    until curl -s "$HOST_URL/health" | grep -q '"status":"pass"'; do
        sleep 2
        echo -n "."
        count=$((count+1))
        if [ $count -ge $retries ]; then
            echo
            log "Timeout waiting for InfluxDB."
            return 1
        fi
    done
    echo
    log "InfluxDB is healthy."

    # NOTE: With DOCKER_INFLUXDB_INIT_* env vars, the setup happens automatically on first run.
    # explicit 'influx setup' command might fail if it's already set up.
    # We check if we can ping it with the token.
    
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Token $token" "$HOST_URL/api/v2/orgs")
    if [[ "$http_code" == "200" ]]; then
       log "InfluxDB authenticated successfully."
    else
       log "Automatic setup might be running or manual setup required."
       # Optional: could force setup here if needed, but the init vars usually handle it.
    fi
}

# Main Execution Logic

check_os

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    install_docker
    add_user_to_docker
    check_firewall
    log "Docker installation complete."
    log "NOTE: You may need to log out and log back in for group membership to take effect."
    
    # If we just installed docker, we might not be able to run docker commands without sudo yet (in this shell)
    # We can try to use 'sg' or just warn the user.
else
    log "Docker is already installed."
    # Ensure compose plugin is there
    if ! docker compose version &>/dev/null; then
         log "Docker Compose plugin not found. Attempting to install..."
         install_docker
    fi
fi

# Proceed with TIG stack setup

generate_envfile
gen_influxdb
gen_telegraf
generate_docker_compose
rundocker
checkup_influx

log "========================================================"
log "Installation Finished."
log "Grafana: http://localhost:3000 (default: admin/admin)"
log "InfluxDB: http://localhost:8086"
log "InfluxDB Token: $INFLUX_TOKEN"
log "Credentials stored in .env.* files."
log "========================================================"