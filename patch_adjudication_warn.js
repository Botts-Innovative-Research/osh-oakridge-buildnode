const fs = require('fs');

let content = fs.readFileSync('web/oscar-viewer/src/app/_components/adjudication/AdjudicationDetail.tsx', 'utf-8');

// remove useBreakpoint import entirely
content = content.replace('import { useBreakpoint } from "@/app/providers";', '');
content = content.replace('const { isMobile, isSmallTablet } = useBreakpoint();', '');

fs.writeFileSync('web/oscar-viewer/src/app/_components/adjudication/AdjudicationDetail.tsx', content);

let constantsContent = fs.readFileSync('web/oscar-viewer/src/lib/data/Constants.ts', 'utf-8');
if(!constantsContent.includes('export const WEB_ID_DEF')) {
    constantsContent += '\nexport const WEB_ID_DEF = "http://sensorml.com/ont/swe/property/WebID";\n';
    fs.writeFileSync('web/oscar-viewer/src/lib/data/Constants.ts', constantsContent);
}
