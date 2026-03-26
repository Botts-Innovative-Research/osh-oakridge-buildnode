const fs = require('fs');
let content = fs.readFileSync('SYSTEM_ARCHITECTURE.md', 'utf-8');
const newText = `
### Network Flows:
- **Client to OSH**: Clients interact with OSH through its REST API and Web UI on port \`8282\`. The client is now progressive web app (PWA) compatible and can be installed locally via a modern web browser.
- **Client Features**: The progressive web application contains specialized functionality such as offline caching, client-side WebID analysis, and camera integration for Spectroscopic QR Code scanning during Adjudication workflows.
- **OSH to PostGIS**: The OSH backend connects to the PostGIS database over the network (local or LAN) on port \`5432\`. This connection is secured via TLS and authenticated with SCRAM-SHA-256.`;

content = content.replace('### Network Flows:\n- **Client to OSH**: Clients interact with OSH through its REST API and Web UI on port `8282`.\n- **OSH to PostGIS**: The OSH backend connects to the PostGIS database over the network (local or LAN) on port `5432`. This connection is secured via TLS and authenticated with SCRAM-SHA-256.', newText.trim());

fs.writeFileSync('SYSTEM_ARCHITECTURE.md', content);
