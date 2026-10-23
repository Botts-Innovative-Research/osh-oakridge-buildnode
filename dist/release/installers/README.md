# Offline prerequisite bundle

The official offline bundle builder places vendor-supplied, checksum-verified Windows installers in
this directory. Installer binaries are deliberately not stored in source control.

```text
installers/
  windows-x86_64/
    Docker Desktop Installer.exe
    wsl.<version>.x64.msi
```

OSCAR 3.9.2 storage deployment is not supported on macOS; no macOS prerequisite
payload is part of a supported release bundle.

Run `tools/offline/build-offline-bundle.ps1 -BundleProfile Both -CreateArchive` on a connected build workstation to create both Windows production artifacts. `offline-full` contains the approved installers and container images; `offline-images` omits the installers for hosts with an existing Docker runtime. Component versions, official URLs, and SHA-256 values are pinned in `tools/offline/components.windows-x86_64.json`. The offline OSCAR CLI never downloads software or container images.

The release workflow does not build, validate, or publish an Ubuntu offline artifact. Supported
Ubuntu deployments use the connected release with Docker Engine and the Compose plugin already
installed. The Bash setup code can consume a site-prepared
`installers/ubuntu-24.04-x86_64/*.deb` set, but that is an operator-qualified fallback and must not be
described as official release media.

Only redistribute installers when the vendor license permits it. Docker Desktop requires a paid subscription for government entities; the OSCAR CLI does not accept that agreement on the administrator's behalf. Document the source URL, version, architecture, SHA-256 digest, download date, and license with every approved release bundle.
