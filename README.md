# bronco — Project Infinity X 4.1 for the Motorola ThinkPhone

Build scripts, `repo` manifest and OTA feed for this device.

- `scripts/build.sh` — builds the ROM. Idempotent: re-applies every local fix on a freshly synced tree. Run it inside the build container with the tree at `/work`, or set `BRONCO_BUILD_ROOT`.
- `bronco.xml` — `repo` local manifest.
- `bronco.json` — OTA feed for the in-ROM updater.

Sources come from upstream (Infinity X manifest, LineageOS, TheMuppets)
