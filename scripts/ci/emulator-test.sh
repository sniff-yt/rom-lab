#!/usr/bin/env bash
# CI helper: build DarkROM on top of the emulator image, boot it headless,
# collect proof (screenshots, screen recording, getprop, package list) and
# write results/summary.md + results/results.json.
#
# Always exits 0 so the publish steps run; the verdict is in
# results/status ("pass" or "fail") and in summary.md.
#
# Env:
#   SYSIMG_DIR    SDK system image dir (contains system.img, VerifiedBootParams.textproto)
#   SYSIMG_PKG    sdkmanager package id, e.g. "system-images;android-34;google_apis;x86_64"
#   WORK_ROOT     scratch space (needs ~15 GB)
#   RESULTS       output folder
#   BOOT_TIMEOUT  seconds to wait for sys.boot_completed (default 600)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
: "${SYSIMG_DIR:?}" "${SYSIMG_PKG:?}" "${WORK_ROOT:?}" "${RESULTS:?}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
mkdir -p "$RESULTS" "$WORK_ROOT"
WD="$WORK_ROOT/wd"
MODSYS="$WORK_ROOT/sysimg"
STAGE="build"
BOOT="no"
NOTES=()
note() { NOTES+=("$*"); echo "NOTE: $*"; }

finish() {
  local status="$1"
  echo "$status" > "$RESULTS/status"
  python3 - "$RESULTS" "$status" "$STAGE" "$BOOT" "${NOTES[@]+"${NOTES[@]}"}" <<'PY'
import json, os, sys
res, status, stage, boot = sys.argv[1:5]
notes = sys.argv[5:]
def rows(name):
    p = os.path.join(res, name)
    if not os.path.exists(p):
        return []
    return [l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
props, removed, files = rows("check-props.tsv"), rows("check-removed.tsv"), rows("check-files.tsv")
sha = os.environ.get("GITHUB_SHA", "local")[:12]
run = ""
if os.environ.get("GITHUB_RUN_ID"):
    run = "%s/%s/actions/runs/%s" % (os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
                                     os.environ.get("GITHUB_REPOSITORY", ""), os.environ["GITHUB_RUN_ID"])
L = []
L.append("# DarkROM test: **%s**" % status.upper())
L.append("")
L.append("- Commit: `%s`" % sha)
if run:
    L.append("- Run: %s" % run)
L.append("- Image: `%s`" % os.environ.get("SYSIMG_PKG", "?"))
L.append("- Boot completed: **%s**" % boot)
if status != "pass":
    L.append("- Stopped at stage: **%s**" % stage)
for n in notes:
    L.append("- %s" % n)
def table(title, head, rs):
    if not rs:
        return
    L.append("")
    L.append("## " + title)
    L.append("")
    L.append("| " + " | ".join(head) + " |")
    L.append("|" + "---|" * len(head))
    for r in rs:
        L.append("| " + " | ".join(x.replace("|", "\\|") for x in r) + " |")
table("Props", ["result", "prop", "expected", "actual"], props)
table("Debloat", ["result", "path", "package", "detail"], removed)
table("Files (apps + overlay)", ["result", "path", "detail"], files)
L.append("")
L.append("## Files in this release")
L.append("")
for f in sorted(os.listdir(res)):
    L.append("- `%s`" % f)
open(os.path.join(res, "summary.md"), "w").write("\n".join(L) + "\n")
ok = lambda rs: sum(1 for r in rs if r and r[0] == "PASS")
json.dump({"status": status, "boot_completed": boot == "yes", "stage": stage, "commit": sha,
           "props": {"pass": ok(props), "total": len(props)},
           "debloat": {"pass": ok(removed), "total": len(removed)},
           "files": {"pass": ok(files), "total": len(files)}, "notes": notes},
          open(os.path.join(res, "results.json"), "w"), indent=2)
PY
  cat "$RESULTS/summary.md"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$RESULTS/summary.md" >> "$GITHUB_STEP_SUMMARY"; fi
  exit 0
}

# --- 1. build ----------------------------------------------------------------
STAGE="unpack"
"$REPO/scripts/unpack" "$SYSIMG_DIR/system.img" "$WD" 2>&1 | tee "$RESULTS/build.log" \
  || { note "unpack failed, see build.log"; finish fail; }
STAGE="apply-mods"
"$REPO/scripts/apply-mods" "$WD" "$REPO/mods" 2>&1 | tee -a "$RESULTS/build.log" \
  || { note "apply-mods failed, see build.log"; finish fail; }
cp "$WD/applied.txt" "$RESULTS/applied.txt"
STAGE="repack"
rm -rf "$MODSYS"; mkdir -p "$MODSYS"
# every file except the ones we rebuild is hard-linked from the SDK copy
for f in "$SYSIMG_DIR"/*; do
  case "$(basename "$f")" in
    system.img|VerifiedBootParams.textproto) ;;
    *) cp -al "$f" "$MODSYS/" 2>/dev/null || cp -a "$f" "$MODSYS/" ;;
  esac
done
"$REPO/scripts/repack" "$WD" "$MODSYS/system.img" 2>&1 | tee -a "$RESULTS/build.log" \
  || { note "repack failed, see build.log"; finish fail; }
[ -f "$MODSYS/system.img" ] || { note "repack produced no system.img"; finish fail; }
cp "$MODSYS/VerifiedBootParams.textproto" "$RESULTS/" 2>/dev/null || true
# free space before booting
rm -rf "$WD/super.img" "$WD/system.ext4" "$WD/orig"

# --- 2. boot -----------------------------------------------------------------
STAGE="boot"
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ACCEL="-accel on"
else
  ACCEL="-accel off"
  note "KVM not available on this runner: emulator runs without acceleration (very slow; boot may time out)"
fi
echo "no" | avdmanager create avd -n darkrom -k "$SYSIMG_PKG" --force >/dev/null 2>&1 \
  || { note "avdmanager create avd failed"; finish fail; }
CFG="$HOME/.android/avd/darkrom.avd/config.ini"
{
  echo "hw.ramSize=3072"
  echo "disk.dataPartition.size=4G"
  echo "hw.keyboard=yes"
  echo "hw.lcd.width=1080"
  echo "hw.lcd.height=2400"
  echo "hw.lcd.density=420"
} >> "$CFG"

# shellcheck disable=SC2086
emulator -avd darkrom -sysdir "$MODSYS" -no-window -gpu swiftshader_indirect -no-snapshot \
  -no-audio -no-boot-anim -camera-back none -camera-front none -wipe-data $ACCEL \
  -verbose -show-kernel > "$RESULTS/emulator.log" 2>&1 &
EMU_PID=$!

adb start-server >/dev/null 2>&1
start=$(date +%s)
while :; do
  if ! kill -0 "$EMU_PID" 2>/dev/null; then
    note "emulator process exited early; last lines of emulator.log are in the release"
    tail -n 60 "$RESULTS/emulator.log" > "$RESULTS/emulator-tail.txt"
    finish fail
  fi
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then break; fi
  if [ $(( $(date +%s) - start )) -ge "$BOOT_TIMEOUT" ]; then
    note "sys.boot_completed did not reach 1 within ${BOOT_TIMEOUT}s"
    adb logcat -d > "$RESULTS/logcat.txt" 2>/dev/null || true
    adb exec-out screencap -p > "$RESULTS/screenshot-timeout.png" 2>/dev/null || true
    [ -s "$RESULTS/screenshot-timeout.png" ] || rm -f "$RESULTS/screenshot-timeout.png"
    tail -n 200 "$RESULTS/emulator.log" > "$RESULTS/emulator-tail.txt"
    kill "$EMU_PID" 2>/dev/null
    finish fail
  fi
  sleep 5
done
BOOT="yes"
note "boot completed in $(( $(date +%s) - start ))s"

# --- 3. evidence -------------------------------------------------------------
STAGE="checks"
sleep 15
adb shell input keyevent 224 >/dev/null 2>&1   # wake
adb shell wm dismiss-keyguard >/dev/null 2>&1
adb shell input keyevent 3 >/dev/null 2>&1     # home
sleep 5
adb exec-out screencap -p > "$RESULTS/screenshot-home.png"
adb shell am start -a android.settings.DEVICE_INFO_SETTINGS >/dev/null 2>&1
sleep 6
adb exec-out screencap -p > "$RESULTS/screenshot-about.png"
adb shell input keyevent 3 >/dev/null 2>&1
adb shell screenrecord --time-limit 8 --size 540x1200 /data/local/tmp/rec.mp4 >/dev/null 2>&1 &
REC=$!
sleep 2
adb shell input swipe 540 2000 540 600 300 >/dev/null 2>&1   # open app drawer
sleep 3
adb shell input keyevent 3 >/dev/null 2>&1
wait "$REC" 2>/dev/null
sleep 1
adb pull /data/local/tmp/rec.mp4 "$RESULTS/screenrecord.mp4" >/dev/null 2>&1 || note "screenrecord could not be pulled"
for f in "$RESULTS"/screenshot-*.png; do [ -s "$f" ] || rm -f "$f"; done

adb shell getprop > "$RESULTS/getprop.txt" 2>/dev/null
adb shell pm list packages 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort > "$RESULTS/packages.txt"
adb logcat -d > "$RESULTS/logcat.txt" 2>/dev/null || true

FAILS=0
: > "$RESULTS/check-props.tsv"
while IFS='=' read -r k v; do
  [ -n "$k" ] || continue
  got="$(adb shell getprop "$k" 2>/dev/null | tr -d '\r')"
  if [ "$got" = "$v" ]; then r=PASS; else r=FAIL; FAILS=$((FAILS+1)); fi
  printf '%s\t%s\t%s\t%s\n' "$r" "$k" "$v" "${got:-(empty)}" >> "$RESULTS/check-props.tsv"
done < "$WD/expected-props.txt"

: > "$RESULTS/check-removed.tsv"
while read -r path pkg; do
  [ -n "$path" ] || continue
  detail=""
  r=PASS
  if adb shell "[ -e $path ]" >/dev/null 2>&1; then r=FAIL; detail="path still exists"; fi
  if [ "$pkg" != "-" ] && grep -qx "$pkg" "$RESULTS/packages.txt"; then
    r=FAIL; detail="${detail:+$detail; }package still installed"
  fi
  [ "$r" = PASS ] || FAILS=$((FAILS+1))
  printf '%s\t%s\t%s\t%s\n' "$r" "$path" "$pkg" "${detail:-gone}" >> "$RESULTS/check-removed.tsv"
done < "$WD/expected-removed.txt"

: > "$RESULTS/check-files.tsv"
while read -r path sum; do
  [ -n "$path" ] || continue
  got="$(adb shell sha256sum "$path" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)"
  if [ "$got" = "$sum" ]; then r=PASS; d="sha256 matches"; else r=FAIL; d="sha256 ${got:-missing}"; FAILS=$((FAILS+1)); fi
  printf '%s\t%s\t%s\n' "$r" "$path" "$d" >> "$RESULTS/check-files.tsv"
done < "$WD/expected-files.txt"

adb emu kill >/dev/null 2>&1 || kill "$EMU_PID" 2>/dev/null
sleep 3
gzip -f "$RESULTS/emulator.log" "$RESULTS/logcat.txt" 2>/dev/null || true

if [ "$FAILS" -eq 0 ]; then finish pass; else note "$FAILS check(s) failed"; finish fail; fi
