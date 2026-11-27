# ROM Lab — DarkROM

DarkROM is a custom Android ROM built entirely in the cloud. An AI agent edits
the files in `mods/`, GitHub Actions applies them to Google's official images,
boots the result in an emulator, and posts screenshots.

Nothing here is flashed to a phone. There are no full AOSP source builds.

## How it works

1. Change something in `mods/` (props, debloat list, apps, overlay files).
2. Push to `main`.
3. The **test** workflow takes Google's Android 14 x86_64 emulator image, applies
   `mods/`, boots it headless, and checks that every change stuck.
4. Results go to the release **[test-latest](../../releases/tag/test-latest)**:
   `summary.md`, screenshots, a short screen recording, `getprop.txt`, `packages.txt`.

The **build-gsi** workflow (run by hand, or on a `v*` tag) applies the same
`mods/` to Google's arm64 GSI and publishes it to the release **gsi-latest**.
That build is not boot-tested.

## Folders

| Path | What it is |
|---|---|
| `mods/rom.json` | ROM name, version, description (become `ro.darkrom.*` props) |
| `mods/props.txt` | `key=value` lines written into `/system/build.prop` |
| `mods/debloat.txt` | paths to delete from `/system` (+ optional package name) |
| `mods/apps/` | APKs to add as system or priv apps (see its README) |
| `mods/overlay/` | files copied into `/system` (same folder layout) |
| `mods/overlay-perms.txt` | optional mode / owner / SELinux label fixes |
| `scripts/unpack`, `apply-mods`, `repack` | the image tools |
| `.github/workflows/` | `test.yml` and `build-gsi.yml` |

## Run the scripts yourself (Linux)

```bash
sudo apt-get install e2fsprogs android-sdk-libsparse-utils erofs-utils attr python3 openssl unzip
scripts/unpack  path/to/system.img  work      # or a .zip / super.img / sparse image
scripts/apply-mods work mods
scripts/repack  work  out/system.img
```

erofs images need `sudo` (to keep file owners and SELinux labels).

Only the `system` partition is changed. `product`, `vendor` and `system_ext`
are left alone. The image is re-signed with a throwaway AVB key on each build.

See `AGENTS.md` for the rules the AI agent follows.
