# Tailscale Security and Configuration for OSCAR Federation

This document explains the requirements and security considerations for using Tailscale to provision API keys between OSCAR nodes.

## 1. Tailscale Requirements

To use the automated provisioning scripts (`provision-node.sh` and `provision-node.bat`), the following Tailscale features must be configured on both the **Central Station** (Source) and the **Federated Node** (Target).

### A. Taildrop (File Sharing)
The scripts use `tailscale file cp` to transfer the API key.
*   **Action**: Ensure Taildrop is enabled in your Tailscale network (Tailnet) settings.
*   **Target Node**: Must be online and capable of receiving files.

### B. Tailscale SSH
The scripts use `tailscale ssh` to move the key into the final configuration directory and set appropriate permissions.
*   **Target Node**: Must have Tailscale SSH enabled.
    *   On Linux: `tailscale up --ssh`
    *   On Windows: Enabled via the Tailscale UI or CLI.
*   **Access Controls (ACLs)**: Your Tailnet ACLs must allow the administrator (Source) to SSH into the Target node.

### C. Tailnet ACL Configuration
You should restrict access so that only authorized administrators can push keys. Example ACL snippet:
```json
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["group:admin"],
      "dst":    ["tag:oscar-node"],
      "users":  ["root", "oscar-user"]
    }
  ]
}
```

## 2. Administrator Responsibilities

### Within Tailscale
1.  **Tagging**: Tag OSCAR nodes (e.g., `tag:oscar-node`) to apply specific security policies.
2.  **Key Expiry**: Disable key expiry for long-lived federated nodes or ensure a process is in place to renew node keys.
3.  **SSH Policies**: Audit who has SSH access to the nodes via Tailscale.

### Within OSCAR
1.  **API Key ownership**: Assign API keys to service accounts with the **minimum necessary permissions** (Least Privilege). Do not use the primary `admin` account for machine-to-machine federation if possible.
2.  **Key Revocation**: If a node is decommissioned or a Tailnet key is compromised, immediately **Revoke** the API key in the OSCAR Admin UI.
3.  **Audit Logs**: Monitor OSCAR logs for unusual API activity associated with specific API keys.

## 3. How the Provisioning Process Works (Technical Flow)

1.  **Local Generation**: The admin generates a random 32-byte API key in the OSCAR Admin UI.
2.  **Hash Storage**: OSCAR stores only the PBKDF2 hash of this key.
3.  **Secure Transfer**:
    *   The `provision-node` script writes the raw key to a temporary local file.
    *   `tailscale file cp` encrypts and transfers the file directly to the target node over the Tailnet (WireGuard).
4.  **Remote Placement**:
    *   `tailscale ssh` executes a command on the target to move the file from the Tailscale "received" folder to `/opt/sensorhub/secrets/api_key` (Linux) or `C:\ProgramData\SensorHub\secrets\api_key` (Windows).
    *   Permissions are set to `600` (read/write by owner only) to prevent local exposure.
5.  **Cleanup**: The temporary local file is deleted immediately.

## 4. Troubleshooting

*   **"Permission Denied" (SSH)**: Check your Tailscale ACLs and ensure the source user has permission to SSH into the target as the specified user.
*   **"File not found"**: Ensure Taildrop is enabled. On some systems, you may need to manually accept the file if Tailscale is not configured to auto-receive.
*   **Connection Timeout**: Verify both nodes are logged into the same Tailnet and are visible to each other (`tailscale status`).
