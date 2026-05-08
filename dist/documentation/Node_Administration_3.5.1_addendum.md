# Node Administration 3.5.1 addendum

The existing **Node Administration** PDF remains useful for Admin UI tasks such as:

- starting and stopping modules
- adding users and roles
- configuring sensors, storage, and SOS services

No major Admin UI workflow changes were required for the 3.5.1 launch, monitoring, and packaging updates.

The operational changes for 3.5.1 are outside that PDF and are now covered in these updated deployment documents:

- `README.md`
- `OSCAR_launch_monitoring_guide.md`
- `MediaMTX_OSCAR_camera_proxy_guide.md`
- `OSCAR_System_Documentation_Manual_3.5.md`

Use the PDF for Admin Panel behavior, and use the updated deployment documents for:

- Java 21 and Docker prerequisites
- `.env` setup
- already-running OSCAR handling
- launch-mode selection: `launch-all` for efficient production, `monitor-oscar` for validation, troubleshooting, and system profiling
- monitoring and status scripts, including duplicate-monitor prevention
- fresh-install cleanup of older OSCAR releases
- MediaMTX-assisted camera deployment guidance

The updated `monitor-oscar.sh` and `monitor-oscar.bat` wrappers now include single-instance protection so a second live monitor launch is refused until the first one is stopped. Use these monitor wrappers when detailed diagnostic evidence is needed; use `launch-all.sh` or `launch-all.bat` for routine production operation to avoid unnecessary additional monitoring logs and snapshot artifacts.
