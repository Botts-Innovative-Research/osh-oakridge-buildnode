# Federation Provisioning with API Keys

This document describes how to set up federation between OSCAR nodes using the bifurcated authentication system (API Keys).

## 1. Provisioning an API Key for a Remote Node
To allow a remote OSCAR node (or any OGC/OSH client) to poll data from your node without interactive 2FA:

1.  **Access Admin UI**: Log in to your local OSCAR Admin UI (`/sensorhub/admin`).
2.  **Generate Key**:
    *   Navigate to the **Security** tab.
    *   Select the user account that the remote node will "act as" (e.g., `admin` or a dedicated service account).
    *   In the **API Keys** section, click **Generate Key**.
    *   Give it a name like `Remote-Node-Alpha`.
    *   **Copy the raw key immediately.**
3.  **Distribute Key**:
    *   Use the `provision-node.sh` or `provision-node.bat` script in the repository root to securely push the key to the remote node over Tailscale:
        ```bash
        ./provision-node.sh <remote-tailscale-name> <api-key>
        ```
    *   **Note**: Requires Tailscale SSH and Taildrop to be configured. See [Tailscale Security and Configuration](TAILSCALE_CONFIGURATION.md) for details.

## 2. Configuring your Node to Federate with another Node
If you have been given an API key from another OSCAR node and want to pull data from it:

1.  **Add a Client Module**:
    *   In your Admin UI, navigate to the **Clients** tab (or **Services** depending on the protocol).
    *   Add a new client (e.g., **ConSys API Client** or **SOS Client**).
2.  **Configure Connection**:
    *   Set the **Remote Host** or **Endpoint URL** to the target node's address.
    *   **Username**: Enter the username provided by the remote administrator.
    *   **Password**: Paste the **API Key** provided by the remote administrator into the password field.
3.  **Authentication Mode**:
    *   Since OSCAR supports bifurcated authentication, using the API Key in the password field will automatically bypass the TOTP requirement for that connection.
    *   Ensure **Enable TLS** is checked if the remote node uses HTTPS (standard).

## 3. Advanced: Using API Keys in Headers
Automated tools that do not support Basic Authentication can use the API key directly in HTTP headers:

*   **Header**: `Authorization: Bearer <your-api-key>`
*   **OR Custom Header**: `X-API-Key: <your-api-key>`

This is the preferred method for machine-to-machine polling of SOS/SPS endpoints.
