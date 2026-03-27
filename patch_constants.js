const fs = require('fs');
const constantsPath = 'web/oscar-viewer/src/lib/data/Constants.ts';
if (fs.existsSync(constantsPath)) {
    let constantsContent = fs.readFileSync(constantsPath, 'utf-8');
    if(!constantsContent.includes('export const WEB_ID_DEF')) {
        constantsContent += '\nexport const WEB_ID_DEF = "http://sensorml.com/ont/swe/property/WebID";\n';
        fs.writeFileSync(constantsPath, constantsContent);
    }
} else {
    fs.writeFileSync(constantsPath, 'export const WEB_ID_DEF = "http://sensorml.com/ont/swe/property/WebID";\n');
}
