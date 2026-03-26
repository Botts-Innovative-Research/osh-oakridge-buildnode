const fs = require('fs');
let content = fs.readFileSync('web/oscar-viewer/src/app/_components/adjudication/WebIdAnalysis.tsx', 'utf-8');

content = content.replace(
    'import { EventType } from "osh-js/source/core/event/EventType";\n',
    'import { EventType } from "osh-js/source/core/event/EventType";\nimport { useLanguage } from "@/contexts/LanguageContext";\n'
);

if(!content.includes('import { useLanguage }')) {
    content = content.replace(
        'import {EventType} from "osh-js/source/core/event/EventType";\n',
        'import {EventType} from "osh-js/source/core/event/EventType";\nimport { useLanguage } from "@/contexts/LanguageContext";\n'
    );
}

content = content.replace(
    'export default function WebIdAnalysis(props: {\n    event: EventTableData;\n}) {\n\n    const laneMapRef = useContext(DataSourceContext).laneMapRef;',
    'export default function WebIdAnalysis(props: {\n    event: EventTableData;\n}) {\n    const { t } = useLanguage();\n    const laneMapRef = useContext(DataSourceContext).laneMapRef;'
);

content = content.replace(
    /<Typography variant="h5">\s*WebID Analysis Results Log\s*<\/Typography>/g,
    '<Typography variant="h5">{t(\'webIdAnalysisLog\') || "WebID Analysis Results Log"}</Typography>'
);

fs.writeFileSync('web/oscar-viewer/src/app/_components/adjudication/WebIdAnalysis.tsx', content);
