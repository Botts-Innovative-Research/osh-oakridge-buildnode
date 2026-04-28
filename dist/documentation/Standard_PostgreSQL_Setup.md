# Standard PostgreSQL Database Setup

If you are deploying OSCAR with a standard, standalone PostgreSQL database (rather than the default Dockerized option), follow these steps to initialize and configure the database properly.

## Prerequisites

- PostgreSQL (version 16 recommended, matching the Docker image)
- PostGIS extensions installed on the database server

## Step 1: Create the Database

Connect to your PostgreSQL instance as a superuser (e.g., `postgres`) and create the `gis` database:

```sql
CREATE DATABASE gis;
```

## Step 2: Configure System Parameters

Set the required `max_connections` limit:

```sql
ALTER SYSTEM SET max_connections = 1024;
```

_Note: You will need to reload or restart the PostgreSQL service for system-level parameter changes to take effect._

## Step 3: Enable PostGIS and Required Extensions

Connect to the newly created `gis` database. If using `psql`, you can do this by running:

```sql
\connect gis;
```

Then, run the following SQL commands to enable the necessary extensions required by the OSCAR system:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
```

## Step 4: Configure User Credentials and Access

Ensure your database is accessible to the OSCAR application:

1. Configure appropriate host-based authentication in your `pg_hba.conf` file to allow the OSCAR server to connect.
2. Ensure the user connecting to the database has sufficient privileges on the `gis` database.

## Step 5: Configure OSCAR Database Connection

Once the database is set up, you must configure OSCAR to connect to it. This can be done in one of two ways:

### Option A: Edit `config.json` Directly (Pre-launch)

Before starting the OSCAR application, you can edit the `dist/config/standard/config.json` file. Locate the configuration module for `SystemDriverDatabaseConfig` containing the `PostgisObsSystemDatabaseConfig` and update the connection details.

Find the block that looks similar to this:

```json
{
  "objClass": "org.sensorhub.impl.database.system.SystemDriverDatabaseConfig",
  "dbConfig": {
    "objClass": "org.sensorhub.impl.datastore.postgis.database.PostgisObsSystemDatabaseConfig",
    "url": "localhost:5432",
    "dbName": "gis",
    "login": "postgres",
    "password": "postgres",
    "idProviderType": "SEQUENTIAL",
    "autoCommitPeriod": 10,
    "useBatch": false,
    "id": "bfbd6d58-1a4a-40b4-999d-381a1489cbb5",
    "autoStart": false,
    "moduleClass": "org.sensorhub.impl.datastore.postgis.database.PostgisObsSystemDatabase"
  },
  // ... other fields
  "name": "PostGIS Database"
}
```

Update the following fields to match your standalone database configuration:

- `url`: The hostname or IP address of your PostgreSQL server and the port (e.g., `db.example.com:5432`).
- `dbName`: The database name (should be `gis` if you followed Step 1).
- `login`: The username for the database.
- `password`: The password for the database user.

### Option B: Use the OSCAR Admin Panel GUI (Post-launch)

If OSCAR is already running (and potentially failing to connect to its default database), you can update the settings through the web administration interface:

1. Log in to the OSCAR Admin Panel (e.g., `http://localhost:8282/sensorhub/admin`).
2. Navigate to the **Databases** tab.
3. Click on the **PostGIS Database** module.
4. Update the **URL**, **Database Name**, **Login**, and **Password** fields with your standalone database details.
5. Save the configuration and restart the module.
