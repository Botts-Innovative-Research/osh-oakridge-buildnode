const fs = require('fs');
let content = fs.readFileSync('web/oscar-viewer/src/app/_components/adjudication/AdjudicationDetail.tsx', 'utf-8');

// Adding useLanguage import
content = content.replace(
    'import { useBreakpoint } from "@/app/providers";',
    'import { useBreakpoint } from "@/app/providers";\nimport { useLanguage } from "@/contexts/LanguageContext";'
);

// Updating function signature to use t
content = content.replace(
    'export default function AdjudicationDetail(props: { event: EventTableData }) {\n    const { isMobile, isSmallTablet } = useBreakpoint();',
    'export default function AdjudicationDetail(props: { event: EventTableData }) {\n    const { t } = useLanguage();\n    const { isMobile, isSmallTablet } = useBreakpoint();'
);

// Replacing exact translations
content = content.replace(/>\s*Adjudication\s*<\/Typography>/g, '>\n                {t(\'adjudicationTitle\')}\n            </Typography>');
content = content.replace(/<Typography variant="h5">Adjudication Report Form<\/Typography>/g, '<Typography variant="h5">{t(\'adjudicationReportForm\')}</Typography>');
content = content.replace(/label="Vehicle ID"/g, 'label={t(\'vehicleId\')}');
content = content.replace(/label="Notes"/g, 'label={t(\'notes\')}');

content = content.replace(/setAdjSnackMsg\("Cannot find observation for adjudication."\);/g, 'setAdjSnackMsg(t(\'cannotFindObservation\'));');
content = content.replace(/setAdjSnackMsg\("Adjudication command failed."\)/g, 'setAdjSnackMsg(t(\'adjudicationFail\'));');
content = content.replace(/setAdjSnackMsg\("Adjudication successful for Count: " \+ props.event.occupancyCount\);/g, 'setAdjSnackMsg(t(\'adjudicationSuccess\') + props.event.occupancyCount);');
content = content.replace(/setAdjSnackMsg\("Adjudication error."\)/g, 'setAdjSnackMsg(t(\'adjudicationFail\'));');

content = content.replace(/>\s*Upload Files\s*<input/g, '>\n                            {t(\'uploadFiles\')}\n                            <input');
content = content.replace(/>\s*QR Scanner\s*<\/Button>/g, '>\n                            {t(\'qrStartScan\')}\n                        </Button>');
content = content.replace(/>\s*Submit\s*<\/Button>/g, '>\n                            {t(\'submit\')}\n                        </Button>');

content = content.replace(/<DialogTitle sx=\{\{textAlign: 'center', pb: 1\}\}>\s*Spectroscopic QR Code Scanner\s*<\/DialogTitle>/g, '<DialogTitle sx={{textAlign: \'center\', pb: 1}}>\n                    {t(\'webIdQrAnalysis\')}\n                </DialogTitle>');
content = content.replace(/>\s*Done Scanning\s*<\/Button>/g, '>\n                            {t(\'doneScanning\') || "Done Scanning"}\n                        </Button>');

fs.writeFileSync('web/oscar-viewer/src/app/_components/adjudication/AdjudicationDetail.tsx', content);
