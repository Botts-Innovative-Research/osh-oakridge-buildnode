# OSCAR System Architecture

## Overview
OSCAR (Open Source Central Alarm Station) is a monitoring system for radiation portal monitors based on the OpenSensorHub (OSH) framework.

## Component Network Flow and Ports

### Components:
- **OSH Backend**: Java-based core application.
- **PostGIS Database**: PostgreSQL with PostGIS extensions for persistent storage.
- **Client Web UI**: React/Frontend viewer.

### Default Port Configuration:
- **OSH Backend API (HTTP)**: `8282`
- **OSH Backend Admin UI**: `8282`
- **PostGIS Database**: `5432`
- **MQTT Server (HiveMQ)**: WebSockets on `/mqtt` (via proxy on port `8282`)

### Network Flows:
- **Client to OSH**: Clients interact with OSH through its REST API and Web UI on port `8282`.
- **OSH to PostGIS**: The OSH backend connects to the PostGIS database over the network (local or LAN) on port `5432`. This connection is secured via TLS and authenticated with SCRAM-SHA-256.

## Deployment and Lifecycle Commands

### Main Launch Scripts:
Located in `dist/release/`:
- `launch-all.sh`: Starts the PostGIS container and the OSH backend (Linux/macOS).
- `launch-all-arm.sh`: Starts the PostGIS container and the OSH backend (ARM64, e.g., Mac M1/M2/M3).
- `launch-all.bat`: Starts the PostGIS container and the OSH backend (Windows).

### Standalone Database Scripts:
Located in `dist/release/postgis/`:
- `run-postgis.sh`: Starts the PostGIS container independently (Linux/macOS).
- `run-postgis-arm.sh`: Starts the PostGIS container independently (ARM64).
- `run-postgis.bat`: Starts the PostGIS container independently (Windows).

## Database Utilities
Cross-platform scripts are provided in the repository root for maintenance:
- `backup.sh/bat`: Safely creates a database dump.
- `restore.sh/bat`: Restores the database from a dump.

These utilities respect the `DB_HOST` and `POSTGRES_PASSWORD_FILE` environment variables.
