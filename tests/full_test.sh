#!/usr/bin/env bash
# End-to-end feature check. Needs Xvfb, aria2, yt-dlp, ffmpeg and python3.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
N=${DISPLAY_NUM:-59}
PORT=${TEST_PORT:-8765}
WORK=$(mktemp -d /tmp/zidm-test.XXXXXX)
mkdir -p "$WORK/home/Downloads" "$WORK/cfg" "$WORK/media"
ffmpeg -v error -f lavfi -i testsrc=duration=20:size=320x240:rate=10 \
  -f lavfi -i sine=frequency=440:duration=20 -c:v libx264 -pix_fmt yuv420p \
  -c:a aac -shortest -y "$WORK/media/clip.mp4" >/dev/null 2>&1
ffmpeg -v error -f lavfi -i testsrc=duration=2:size=160x120:rate=5 -c:v libx264 -pix_fmt yuv420p -y "$WORK/media/clip2.mp4" >/dev/null 2>&1
(cd "$WORK/media" && python3 -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/http.log" 2>&1) &
SERVER=$!
Xvfb ":$N" -screen 0 1366x900x24 >/dev/null 2>&1 &
XV=$!
sleep 1.5
pkill -x aria2c 2>/dev/null
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE DISPLAY=":$N" GDK_BACKEND=x11 \
  WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 \
  HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/cfg" ZIDM_SELFTEST=1 \
  "$ROOT/zig-out/bin/zidm" >"$WORK/app.log" 2>&1 &
APP=$!
sleep 22
kill $APP $SERVER $XV 2>/dev/null
pkill -x aria2c 2>/dev/null
grep -E 'ZIDM FULLTEST|CONSOLE JS ERROR|panic' "$WORK/app.log"
grep -q 'ZIDM FULLTEST PASS' "$WORK/app.log"
RESULT=$?
echo "workdir=$WORK"
exit $RESULT
