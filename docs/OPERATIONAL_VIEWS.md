# Operational views

Operational views let multiple workstations use one OSCAR deployment while each viewer loads only its assigned lanes. They do not create new users, roles, lane copies, or databases, and they do not change lane unique identifiers or historical data.

## Configure lanes

In the Lane System configuration, add one or more **Operational View Keys**. Keys must contain 1–63 lowercase letters, numbers, or hyphens and cannot begin or end with a hyphen. A lane can belong to more than one view.

For bulk configuration, the lane CSV export includes an `OperationalViews` column. Separate multiple keys with semicolons:

```text
north-gate;secondary
```

CSV files exported by earlier releases remain importable. Their lanes have no view assignment until an administrator adds one.

When importing a lane CSV in **SensorHub Admin → Services → OSCAR Service Module**, a successful
upload loads the lanes immediately and records the persistent bucket object key in the edited
service configuration. Click **Apply Changes**, then the global **Save** action, confirm **Yes**
in the dialog, and wait for **SensorHub Configuration Saved**. Merely opening the confirmation
dialog does not persist the configuration. Perform one
supported OSCAR restart and verify that the live Lane, RPM, and camera modules return; finding the
lane UIDs in historical database results alone is not a persistence check. If Apply Changes and
Save are omitted, the uploaded runtime modules are not an accepted durable configuration.

## Open a view

Use either URL form, replacing `north-gate` with the configured key:

```text
https://oscar.example/?view=north-gate
https://oscar.example/view/north-gate
```

The gateway redirects the second form to the first. OSCAR keeps the view parameter while navigating, opening event details, using the map, and handling alarm notifications.

Event UUID searches and copied Event Details links also retain the active view. A canonical link includes the encoded observation ID and source node, for example `event-details?eventId=<id>&nodeId=<node>&view=north-gate`. The Viewer resolves that ID only against occupancy streams belonging to lanes visible in the active view; a UUID from another view fails closed instead of revealing the event.

The normal root URL remains the unscoped administrative/legacy view and loads every lane:

```text
https://oscar.example/
```

Invalid keys and valid keys with no assigned lanes fail closed and load no lane data. Scoped dashboards, events, maps, national statistics, generated reports, alarm transfer, and Status of Health use only the lanes in the active view.

The Viewer preserves `?view=<key>` when the operator selects the Status of Health icon. Consequently, `/health/` shows all discovered lanes, while `/health/?view=north-gate` shows every lane assigned to `north-gate`. Connection, fault, and occupancy status is refreshed for only those visible lanes on entry and every 30 seconds. Requests contain at most 10 health streams, and the Viewer allows no more than two health requests in flight across all configured nodes.

Operational views are a workstation presentation boundary, not an authorization boundary. Anyone authorized to use the unscoped root URL can still see all lanes. Use network controls and OSCAR authentication if view URLs must be restricted to particular workstations or users.
