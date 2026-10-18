# bronco — Project Infinity X 4.1 for the Motorola ThinkPhone

Build scripts, `repo` manifest, patches and OTA feed for this device.

```
scripts/build.sh          full build + OTA (runs inside the podman container, tree at /work)
scripts/container.sh      (re)create that container
scripts/make-patches.sh   regenerate patches/*.patch from the tree after editing a patched file
scripts/push-apk.sh       rebuild one APK and hot-swap it onto the running phone
scripts/measure-bars.sh   exact status bar / QS layout rects per screen state
scripts/publish.sh        upload a build to rom.flac.moe, rewrite bronco.json, push the feed
```

- `patches/` — one patch per repo; `build.sh` re-applies them idempotently after every
  `repo sync`, so upstream drift cannot silently undo a fix.
- `bronco.xml` — `repo` local manifest (copied into `.repo/local_manifests/`).
- `bronco.json` + `changelog/bronco.txt` — what the in-ROM Updater fetches.
- `docs/` — local notes (gitignored), entry point `../AGENTS.md`.

Layout of a working tree: the AOSP checkout contains this repo as `infinity/`. Sources
come from upstream (Infinity X manifest, LineageOS, TheMuppets).
