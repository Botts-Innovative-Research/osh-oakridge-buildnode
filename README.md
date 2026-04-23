# OSH OAKRIDGE BUILDNODE

This repository combines all the OSH modules and dependencies to deploy the OSH server and client for ORNL.

## Requirements
- [Java 21.0.10+](https://www.oracle.com/java/technologies/downloads/#java21)
- Docker engine
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

# Releasing a New Version

## Release Checklist
Before releasing, ensure the following on the `dev` branch:
1. Update `version` in `build.gradle` to match the release version (e.g. `"3.2.0"`)
2. Update `deploymentName` in `dist/config/standard/config.json` to `"OSCAR <version>"` (e.g. `"OSCAR 3.2.0"`)
3. Ensure there is no `pgdata` directory in `dist/release/postgis`
4. Verify the build succeeds locally with `./build-all.sh` or `./build-all.bat`

## Release Steps
1. **Merge `dev` into `main`:**
   ```bash
   git checkout main
   git pull origin main
   git merge dev
   git push origin main
   ```
   Alternatively, create a pull request from `dev` → `main` on GitHub and merge it.

2. **Tag the release on `main`:**
   ```bash
   git checkout main
   git pull origin main
   git tag v<version>    # e.g. git tag v3.2.0
   git push origin v<version>
   ```

3. **The release workflow runs automatically.** It will:
   - Validate that the tag is on the `main` branch
   - Verify version numbers match the tag in `build.gradle` and `config.json`
   - Check that `pgdata` does not exist in the release directory
   - Build the project (Gradle + oscar-viewer)
   - Package the source code with all submodules included
   - Create a GitHub Release with the build artifact and source archive

# PostgreSQL Configuration
There are some tweaks that can be made to the PostgreSQL configuration to make it perform better.
Below is a list of suggested configuration parameters at varying levels of maximum system RAM.

`shared_buffers` - Should be around 25% of maximum RAM
`effective_cache_size` - Should be around 70-75% of maximum RAM
`work_mem` - 16MB to 64MB. Depends on maximum system memory and size of the load
`maintenance_work_mem` - 512MB to 2GB. Depends on the load, but it's OK to try high numbers

# Secure Node Over TLS (HTTPS)
In order to secure the OSH node over TLS, you must generate a Java keystore with an SSL certificate.

Below is the command to generate a keystore with a self-signed certificate.

`keytool -genkeypair -alias <alias_name> -keyalg RSA -keysize 2048 -validity <days> -keystore <keystore_filename>.jks -storepass <keystore_password> -keypass <key_password> -dname "CN=<Common Name>, OU=<Organizational Unit>, O=<Organization>, L=<Locality>, ST=<State>, C=<Country>" -ext "SAN=<Subject Alternative Name>"`

Then, in your OSH config (`config.json`), or in the Admin Panel under `Network` -> `HTTP Server`, you must specify the key store path, password, key alias, and HTTPS port.

An example of the `config.json`'s HTTP Server config is shown below:

```json
{
    "objClass": "org.sensorhub.impl.service.HttpServerConfig",
    "httpPort": 8282,
    "httpsPort": 8443,
    "servletsRootUrl": "/sensorhub",
    "authMethod": "BASIC",
    "keyStorePath": "osh-keystore.jks",
    "keyStorePassword": "changeit",
    "keyAlias": "oscar-key",
    "trustStorePath": ".keystore/ssl_trust",
    "enableCORS": true,
    "id": "5cb05c9c-9e08-4fa1-8731-ffaa5846bdc1",
    "autoStart": true,
    "moduleClass": "org.sensorhub.impl.service.HttpServer",
    "name": "HTTP Server"
}
```

You can also edit this information in the OSH launch scripts at `osh-node-oscar/launch.(sh|bat)`

```shell
java -Xms6g -Xmx6g -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError \
	-Dlogback.configurationFile=./logback.xml \
	-cp "lib/*" \
	-Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" \
	-Djavax.net.ssl.keyStore="./osh-keystore.jks" \
	-Djavax.net.ssl.keyStorePassword="changeit" \
	-Djavax.net.ssl.trustStore="$SCRIPT_DIR/trustStore.jks" \
	-Djavax.net.ssl.trustStorePassword="changeit" \
	-Djava.library.path="./nativelibs" \
	com.botts.impl.security.SensorHubWrapper ./config.json ./db

```