#!/usr/bin/env bash
# emulator.sh — start/stop the localmind-test AVD and drive the installed app.
#
# Usage:
#   emulator.sh start                 boot headless and wait for sys.boot_completed
#   emulator.sh stop                  kill the emulator
#   emulator.sh install [apk]          adb install -r (default: arm64 release APK)
#   emulator.sh launch                start pro.momin.localmind/.MainActivity
#   emulator.sh shot <png>             screenshot to a file
#   emulator.sh tap <x> <y>            tap in 1080x2400 device coordinates
#   emulator.sh text <text>            type text (spaces escaped)
#   emulator.sh key <keycode>          send a key event (66 = Enter, 4 = Back)
#   emulator.sh swipe <x1> <y1> <x2> <y2> [ms]
#   emulator.sh logs [n]               crash/flutter log tail (default 60)
set -u

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
AVD="${AVD_NAME:-localmind-test}"
APK="${APK_PATH:-build/app/outputs/flutter-apk/app-arm64-v8a-release.apk}"
PKG="${PACKAGE:-pro.momin.localmind}"
LOG="${EMULATOR_LOG:-/private/var/folders/2g/y0szl8p53cs137_3tbdpz0jw0000gn/T/opencode/emulator.log}"

case "${1:-}" in
  start)
    pgrep -f "emulator.*-avd $AVD" >/dev/null && { echo "already running"; exit 0; }
    nohup "$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim \
      -gpu swiftshader_indirect > "$LOG" 2>&1 &
    echo "emulator starting (log: $LOG)"
    "$ADB" wait-for-device
    for _ in $(seq 1 60); do
      [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
        && { echo "BOOTED"; exit 0; }
      sleep 5
    done
    echo "boot timed out"; exit 1
    ;;
  stop)
    "$ADB" emu kill
    ;;
  install)
    "$ADB" install -r "${2:-$APK}"
    ;;
  launch)
    "$ADB" logcat -c
    "$ADB" shell am start -n "$PKG/.MainActivity"
    ;;
  shot)
    "$ADB" exec-out screencap -p > "${2:?usage: shot <png>}"
    echo "screenshot: $2"
    ;;
  tap)
    "$ADB" shell input tap "${2:?x}" "${3:?y}"
    ;;
  text)
    escaped="${2:?usage: text <text>}"
    escaped="${escaped// /%s}"
    "$ADB" shell input text "$escaped"
    ;;
  key)
    "$ADB" shell input keyevent "${2:?usage: key <keycode>}"
    ;;
  swipe)
    "$ADB" shell input swipe \
      "${2:?x1}" "${3:?y1}" "${4:?x2}" "${5:?y2}" "${6:-300}"
    ;;
  logs)
    "$ADB" logcat -d 2>/dev/null \
      | grep -iE "FATAL|AndroidRuntime|E/flutter|$PKG" | tail -"${2:-60}"
    ;;
  *)
    echo "usage: emulator.sh start|stop|install [apk]|launch|shot <png>|tap <x> <y>|text <text>|key <code>|swipe <x1> <y1> <x2> <y2> [ms]|logs [n]" >&2
    exit 2
    ;;
esac
