const fs = require('fs');

let content = fs.readFileSync('include/osh-addons/services/sensorhub-service-mqtt-hivemq/build.gradle', 'utf-8');
content = content.replace(
    "exclude group: 'org.slf4j', module: 'slf4j-api'",
    "exclude group: 'org.slf4j', module: 'slf4j-api'\n    exclude group: 'org.bouncycastle'"
);
fs.writeFileSync('include/osh-addons/services/sensorhub-service-mqtt-hivemq/build.gradle', content);
