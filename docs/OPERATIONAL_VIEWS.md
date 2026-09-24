# Operational views

Operational views let multiple workstations use one OSCAR deployment while each viewer loads only its assigned lanes. They do not create new users, roles, lane copies, or databases, and they do not change lane unique identifiers or historical data.

## Configure lanes

In the Lane System configuration, add one or more **Operational View Keys**. Keys must contain 1–63 lowercase letters, numbers, or hyphens and cannot begin or end with a hyphen. A lane can belong to more than one view.

For bulk configuration, the lane CSV export includes an `OperationalViews` column. Separate multiple keys with semicolons:

```text
north-gate;secondary
```

CSV files exported by earlier releases remain importable. Their lanes have no view assignment until an administrator adds one.

## Open a view

Use either URL form, replacing `north-gate` with the configured key:

```text
https://oscar.example/?view=north-gate
https://oscar.example/view/north-gate
```

The gateway redirects the second form to the first. OSCAR keeps the view parameter while navigating, opening event details, using the map, and handling alarm notifications.

The normal root URL remains the unscoped administrative/legacy view and loads every lane:

```text
https://oscar.example/
```

Invalid keys and valid keys with no assigned lanes fail closed and load no lane data. Scoped dashboards, events, maps, national statistics, and generated reports use only the lanes in the active view.

Operational views are a workstation presentation boundary, not an authorization boundary. Anyone authorized to use the unscoped root URL can still see all lanes. Use network controls and OSCAR authentication if view URLs must be restricted to particular workstations or users.
