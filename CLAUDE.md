# Instructions for AI agents (DarkROM / ROM Lab)

You are editing **DarkROM**, a custom ROM built only in the cloud.
Repo: `sniff-yt/rom-lab`, branch `main`.

## Hard rules

- **Never flash anything** to any device, and never write instructions that tell
  Dark to flash his phone (vivo V2502, bootloader locked).
- **No AOSP source builds.** We only modify Google's prebuilt images.
- **Edit `mods/` only.** Touch `scripts/` or `.github/` only to fix a real bug in them,
  and say so in the commit message.
- **Small changes.** One idea per commit, so a failed test points at one thing.
- **Commit straight to `main`** with a clear message (`props: set X`, `debloat: drop Y`).
- Don't claim something works until `test-latest` says PASS for your commit.

## How to make a change

| Want to… | Edit |
|---|---|
| set or change a system property | `mods/props.txt` — one `key=value` per line |
| bump name / version / description | `mods/rom.json` |
| remove a system app | `mods/debloat.txt` — `/system/app/Foo com.example.foo` |
| add an APK | `mods/apps/system/Foo.apk` or `mods/apps/priv-app/Foo.apk` |
| add or replace a file in /system | `mods/overlay/<path under /system>` |
| fix mode/owner/label of an overlay file | `mods/overlay-perms.txt` |

Notes:
- Only `/system/...` paths work. Apps in `/product` or `/system_ext` can't be removed yet.
- A prop also set in vendor/product `build.prop` may override ours; the test shows it.
- The test image is **x86_64**, the GSI is **arm64**. APKs with native code must match.
- New priv-apps that use privileged permissions need
  `mods/overlay/etc/permissions/privapp-permissions-<pkg>.xml`, or boot fails.
- Removing core apps (SystemUI, Settings, providers, Shell, Telecom…) will break boot.

## How to test

Pushing to `main` (any change outside `*.md`) runs the **test** workflow.
To run it by hand:

```bash
gh workflow run test.yml -R sniff-yt/rom-lab
gh run watch -R sniff-yt/rom-lab $(gh run list -R sniff-yt/rom-lab -w test -L 1 --json databaseId -q '.[0].databaseId')
```

It takes roughly 15–30 minutes. Do not start **build-gsi** unless asked; it is
heavy and is not boot-tested.

## How to read results

Release **`test-latest`** is replaced on every test run:
https://github.com/sniff-yt/rom-lab/releases/tag/test-latest

| File | Meaning |
|---|---|
| `summary.md` | PASS/FAIL, boot yes/no, table of every prop / debloat / file check |
| `results.json` | same, machine-readable |
| `screenshot-home.png`, `screenshot-about.png` | the booted ROM |
| `screenrecord.mp4` | ~8 s recording |
| `getprop.txt`, `packages.txt` | full prop dump and package list |
| `applied.txt`, `build.log` | what the scripts changed |
| `emulator.log.gz`, `logcat.txt.gz`, `emulator-tail.txt` | for debugging a failed boot |

Check the release title / `summary.md` commit matches your commit before trusting it.

```bash
gh release download test-latest -R sniff-yt/rom-lab -p summary.md -O - 
gh release download test-latest -R sniff-yt/rom-lab -p 'screenshot-*.png' -D /tmp/darkrom
```

The repo is meant to be public, so assets download without a login. If it is ever
made private, release assets need auth: use `gh release download` (logged in) or the
API with a token and `Accept: application/octet-stream`.

The same files are also uploaded as the workflow artifact `test-results`.

## If the test fails

1. Read `summary.md`: which stage (`unpack`, `apply-mods`, `repack`, `boot`, `checks`).
2. `boot` failed → read `emulator-tail.txt` / `logcat.txt.gz`. Usually the last change
   removed something needed or added a bad priv-app. Revert that change.
3. A single check failed → fix that line in `mods/` and push again.
