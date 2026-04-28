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
3. Use the connection details (host, port, username, password) when configuring the **PostGIS Database** connection settings in the OSCAR Admin Panel.
