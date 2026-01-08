[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N41E59SA)

# TIG Stack – Monitoring System with Telegraf, InfluxDB, and Grafana

This repository provides an automated setup for deploying a TIG Stack—**Telegraf**, **InfluxDB**, and **Grafana**—using **Docker** and **Docker Compose**. It's designed to help you quickly build a modern, efficient monitoring system for collecting, storing, and visualizing time-series data.

---

## What's Included

- **Telegraf** – Agent for collecting and reporting system and application metrics  
- **InfluxDB** – High-performance time-series database for storing metrics  
- **Grafana** – Powerful visualization and dashboard platform  
- **Setup Script (`tig-setup.sh`)** – Automatically installs the latest versions of Docker and Docker Compose, then sets up the entire TIG stack

The setup also generates the following environment files to securely store credentials and tokens:

- `.env.influxdb-admin-username`  
- `.env.influxdb-admin-password`  
- `.env.influxdb-admin-token`

---

## Getting Started
### 1. Clone repository

```bash
git clone https://github.com/R2Dino/tig-stack.git
```
### 2. Make the setup script executable:

```bash
chmod +x tig-setup.sh
```

### 3. Execute script
```bash
./tig-setup.sh
```
### 4. Change Default Password of Grafana
Open web browser and connect to grafana via port 3000

Example: https://localhost:3000

Default user: admin

Default password: admin
