# OSH OAKRIDGE BUILDNODE

This repository combines all the OSH modules and dependencies to deploy the OSH server and client for ORNL.

## Requirements
- [Java 21](https://www.oracle.com/java/technologies/downloads/#java21)
- [Oakridge Build Node Repository](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode) 
- Node v22

## Installation
Clone the repository and update all submodules recursively

```bash
git clone git@github.com:Botts-Innovative-Research/osh-oakridge-buildnode.git --recursive
```
If you've already cloned without `--recursive`, run:
```bash
cd path/to/osh-oakridge-buildnode
git submodule update --init --recursive
```
## Build 
Navigate to the project directory:

```bash
cd path/to/osh-oakridge-buildnode
```

Run the build script (macOS/Linux):

```bash
./build-all.sh
```

Run the build script (Windows):

```bash
./build-all.bat
```

After the build completes, it can be located in `build/distributions/` 

## Deploy and Start OSH Node
1. Unzip the distribution using the command line or File Explorer:

    Option 1: Command Line
    ```bash
    unzip build/distributions/osh-node-oscar-1.0.zip
    cd osh-node-oscar-1.0/osh-node-oscar-1.0
    ```
   ```bash
    tar -xf build/distributions/osh-node-oscar-1.0.zip
    cd osh-node-oscar-1.0/osh-node-oscar-1.0
    ```
   Option 2: Use File Explorer
    1. Navigate to `path/to/osh-oakridge-buildnode/build/distributions/`
    2. Right-click `osh-node-oscar-1.0.zip`.
    3. Select **Extract All..**
    4. Choose your destination, (or leave the default) and extract.
1. Launch the OSH node:
   Run the launch script, "launch.sh" for linux/mac and "launch.bat" for windows.
2. Access the OSH Node
- Remote: **[ip-address]:8282/sensorhub/admin**
- Locally:  **http://localhost:8282/sensorhub/admin**

The default credentials to access the OSH Node are admin:admin. This can be changed in the Security section of the admin page.

For documentation on configuring a Lane System on the OSH Admin panel, please refer to the OSCAR Documentation provided in the Google Drive documentation folder.

## Deploy the Client
After configuring the Lanes on the OSH Admin Panel, you can navigate to the Clients endpoint:
- Remote: **[ip-address]:8282**
- Local: **http://localhost:8282/**

For documentation on configuring a server on the OSCAR Client refer to the OSCAR Documentation provided in the Google Drive documentation folder. 

# Release Checklist
- Version in `build.gradle`
- Version in `dist/config/standard/config.json`
- Make sure no `pgdata` in `dist/release/postgis`
- Build with `./build-all.sh` or `./build-all.bat`

# PostgreSQL Configuration
There are some tweaks that can be made to the PostgreSQL configuration to make it perform better.
Below is a list of suggested configuration parameters at varying levels of maximum system RAM.

`shared_buffers` - Should be around 25% of maximum RAM
`effective_cache_size` - Should be around 70-75% of maximum RAM
`work_mem` - 16MB to 64MB. Depends on maximum system memory and size of the load
`maintenance_work_mem` - 512MB to 2GB. Depends on the load, but it's OK to try high numbers