const fs = require('fs');
let content = fs.readFileSync('changelog.md', 'utf-8');
const newText = `
## [Unreleased]
### Added
- Added Progressive Web App (PWA) capabilities, allowing the client to be installed as a local application with offline support.
- Integrated Spectroscopic QR Code scanning for Adjudication workflows.
- Added WebID analysis and result logging to the Adjudication Detail view.
`;

content = content.replace('## 3.0.0 2026-02-04', newText + '\n## 3.0.0 2026-02-04');
fs.writeFileSync('changelog.md', content);
