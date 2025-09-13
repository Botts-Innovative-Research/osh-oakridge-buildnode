# OSCAR Build Node Change Log
All notable changes to this project will be documented in this file. 

## [2.2.1] - 2025-09-13
### Added
- Current PostGIS database module. (needs to be updated, but this provides a base for testing later versions of OSCAR)
- Dockerfiles and script to launch PostGIS instance.
### Changed
- Restructured repository, moving most directories that are unused in development under `dist`
### Fixed
- [#89](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/89) Removed vulnerable Log4j usage (Axis driver)

## [2.2] - 2025-07-30
Release 2.2 request, no updates since 1.3.7.


## [1.3.7] 2025-07-18

### Added
- [#80](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/80)
  FEATURE REQUEST: Changelog
### Changed
- ToggleButtons are disabled when selected to prevent no component showing (e.g. On event-preview when 'cps' chart is selected you can only toggle to 'nsigma' chart)
- [#85](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/85)
  Neutron Chart Tick Marks
- [#86](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/86)
  Remove "Adjudicated" Filter from Alarming Occupancy Table
### Fixed
- Navigate from Map to Lane View by clicking on point marker
- [#90](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/90)
  Aspect RPMS are not working in version 1.3.5
- [#91](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/91)
  OSCAR Viewer Stability
- [#94](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/94)
  Incorrect Video Timeframe Display Leading to Playback Failure
- Aspect alarming events should now appear with charts/video in the event-preview and event-details