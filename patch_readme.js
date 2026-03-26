const fs = require('fs');
let content = fs.readFileSync('README.md', 'utf-8');
const newText = `
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

## Deploy the Client`;

content = content.replace('## Deploy the Client', newText);
fs.writeFileSync('README.md', content);
