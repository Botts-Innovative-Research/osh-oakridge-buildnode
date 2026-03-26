# OSH OAKRIDGE BUILDNODE

This repository combines all the OSH modules and dependencies to deploy the OSH server and client for ORNL.

## Requirements
- [Java 21](https://www.oracle.com/java/technologies/downloads/#java21)
- [Oakridge Build Node Repository](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode) 
- Node v22
- [Docker](https://docs.docker.com/get-docker/) (Required to run the PostGIS database system)

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
    # Note: Replace <version> with the current version, e.g. 3.0.0
    unzip build/distributions/osh-node-oscar-<version>.zip
    cd osh-node-oscar-<version>/osh-node-oscar-<version>
    ```
   ```bash
    # Note: Replace <version> with the current version, e.g. 3.0.0
    tar -xf build/distributions/osh-node-oscar-<version>.zip
    cd osh-node-oscar-<version>/osh-node-oscar-<version>
    ```
   Option 2: Use File Explorer
    1. Navigate to `path/to/osh-oakridge-buildnode/build/distributions/`
    2. Right-click `osh-node-oscar-<version>.zip` (where `<version>` is the current release version, e.g. `3.0.0`).
    3. Select **Extract All..**
    4. Choose your destination, (or leave the default) and extract.
1. Launch the OSH node and PostGIS Database:
   The database management system is handled through Docker. The default launch scripts automatically build and run a PostGIS container using the `Dockerfile` located in `dist/release/postgis`, and then start the OSH node.
   Run the launch script, `launch-all.sh` (or `launch.sh` within the `osh-node-oscar` folder directly if the database is already running) for linux, `launch-all-arm.sh` (or `launch-arm.sh` if it exists) for mac, and `launch-all.bat` (or `launch.bat`) for windows.
2. Access the OSH Node
- Remote: **[ip-address]:8282/sensorhub/admin**
- Locally:  **http://localhost:8282/sensorhub/admin**

### First-Time Setup
On first boot, OSCAR enters an **Uninitialized State** and requires configuration via a Setup Wizard.
1. Navigate to `http://localhost:8282/` or `http://localhost:8282/sensorhub/admin`.
2. You will be automatically redirected to the **Setup Wizard**.
3. **Create an Admin Password**: Set a strong password for the `admin` account.
4. **Configure TOTP**:
   - Scan the displayed QR code with an authenticator app (Google Authenticator, Authy, etc.).
   - **Important**: Save the secret key shown in the wizard!
   - Use the **Test Code** form to verify your setup before proceeding.
5. Once complete, you will be redirected to the Admin UI login.

### Logging In
After initialization, use the following credentials:
- **Username**: `admin`
- **Password**: The password you set during the Setup Wizard.
- **Two-Factor Authentication**:
  - If your browser or client supports it, enter your password as usual and provide the 6-digit TOTP code when prompted.
  - If you are prompted for a single login by the browser and can't provide a TOTP code separately, enter your password followed by a colon and the code (e.g., `mypassword:123456`).

**Language Selection**
The user can select different languages for the Admin UI by using the language drop-down menu located in the top right corner of the Admin UI toolbar. Selecting a new language will instantly switch the UI localization.

**Two-Factor Authentication (2FA)**
2FA is mandatory for the administrator account and can be configured for other users to add an extra layer of security. To set this up for additional users:
1. Log in to the Admin UI as `admin`.
2. Navigate to the **Security** section.
3. Edit a user profile and set up Two-Factor Authentication. A popup window will appear with a QR code generated locally on the server.
4. Scan the QR code with an authenticator app (like Google Authenticator or Authy) to complete the setup.

**Importing/Exporting Lane Configurations via CSV**
Configurations for Lane Systems can be bulk managed via spreadsheet (CSV).
1. Log in to the Admin UI.
2. Navigate to **Services -> OSCAR Service**.
3. Within the configuration form for the OSCAR service, locate the property for spreadsheet configuration (`spreadsheetConfigPath`).
4. To export, click the download button to retrieve the current configurations as a CSV file.
5. To import, upload your modified CSV file through the provided upload mechanism in the service configuration to apply new or updated lane setups.

For documentation on configuring a Lane System on the OSH Admin panel, please refer to the OSCAR Documentation provided in the Google Drive documentation folder.


## Progressive Web App (PWA)
The OSCAR Viewer can now be installed as a Progressive Web App (PWA) on compatible devices (mobile, tablet, and desktop) for offline-capable or app-like experiences.
To install it:
1. Navigate to the OSCAR Viewer in a supported browser (e.g., Chrome, Safari).
2. Look for the "Install App" or "Add to Home Screen" option in the browser menu.

## WebID Analysis and Spectroscopic QR Scanning
The OSCAR Viewer now features integrated Spectroscopic QR Code scanning for WebID analysis in the Adjudication workflows.
- During an adjudication, users can open the **QR Scanner** to scan spectroscopic QR codes via their device camera.
- Scanned items can be configured with a Detector Response Function (DRF) or used to synthesize background data.
- The system parses the scanned QR code to perform WebID Analysis, displaying results in the **WebID Analysis Results Log** within the adjudication panel.
- All WebID UI elements are localized and adapt to the user's selected language.

## Deploy the Client
After configuring the Lanes on the OSH Admin Panel, you can navigate to the Clients endpoint:
- Remote: **[ip-address]:8282**
- Local: **http://localhost:8282/**

For documentation on configuring a server on the OSCAR Client refer to the OSCAR Documentation provided in the Google Drive documentation folder. 

## Security and Federation
- [Security Architecture](SECURITY_ARCHITECTURE.md)
- [System Architecture](SYSTEM_ARCHITECTURE.md)
- [Federation Provisioning (API Keys)](docs/FEDERATION_PROVISIONING.md)
- [Tailscale Security and Configuration](docs/TAILSCALE_CONFIGURATION.md)

# Release Checklist
- Version in `build.gradle`
- Version in `dist/config/standard/config.json`
- Make sure no `pgdata` in `dist/release/postgis`
- Build with `./build-all.sh` or `./build-all.bat`

