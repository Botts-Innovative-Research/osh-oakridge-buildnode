# OSCAR Build Node Change Log
All notable changes to this project will be documented in this file. 

## 3.0.0-alpha.1 - 2025-11-xx
### Added
- Added docker compose and Dockerfile for OSCAR OSH node, allowing PostGIS and OSH to be run with one script.
### Changed
- Swapped default H2 database with default PostGIS database.

## 3.0.0-alpha - 2025-11-04
### Added
- [#19 Option to replace sitemap with site diagram](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/19)
- [#43 Implement Report Generation](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/43)
- [#48 Switched Database from H2 to PostgresSQL ](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/48)
- [#53 Streamlined Initial Configuration via Spreadsheet Import](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/53)
- Set up Sentry Testing
- Added Unit Tests for all drivers - (Rapiscan, Aspect, FFMpeg, Lane System)
- Set up Client testing using Cypress
- Added GitHub Actions for testing
### Changed
- [#106 Update client playback videostreams](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/106)
- Use local storage to save nodes configured on client server page.
-
### Removed
- [#89 Upgrade Log4j from EOL 1.x to a secure version](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/89)
### Fixed
- [#101 National View does not show the accurate data collected by each site](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/101)

## [2.3.1] - 2025-09-13
### Added
- Current PostGIS database module. (needs to be updated, but this provides a base for testing later versions of OSCAR)
- Dockerfiles and script to launch PostGIS instance.
### Changed
- Restructured repository, moving most directories that are unused in development under `dist`

## [2.3.0] 
Release 2.3.0 

### Added
- Added Deployment version to config.json

### Changed
- [#89](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/89)
Removed dependency to log4j

### Fixed
- [#90](https://github.com/Botts-Innovative-Research/osh-oakridge-buildnode/issues/90)
Aspect Charts:The prior issue mentioned the Aspect RPMs and the Admin Panel, but this encompasses Aspects issues on the client as well.
- [#]()
Update charts in client to display Rapiscan and Aspect charts 
- [#]()
  Node Form Fix: Updated NodeForm to check if node is reachable before adding it to the list of Nodes, so when configuring a node it will ensure that you can access that node before it continues processing and updating the UI.


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