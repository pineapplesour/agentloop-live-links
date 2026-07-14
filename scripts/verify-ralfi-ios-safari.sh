#!/usr/bin/env bash

set -Eeuo pipefail

RALFI_URL="${RALFI_URL:?RALFI_URL is required}"
IOS_MAJOR="${IOS_MAJOR:-18}"
DEVICE_TYPE_NAME="${DEVICE_TYPE_NAME:-iPhone 16 Pro}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/ios-${IOS_MAJOR}}"
DEVICE_NAME="Ralfi iOS ${IOS_MAJOR} Safari"
SESSION_NAME="ralfi-ios-${IOS_MAJOR}-${GITHUB_RUN_ID:-local}"
UDID=""
APPIUM_PID=""

mkdir -p "$ARTIFACT_DIR"

run_with_timeout() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)
try:
    sys.exit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    print(f"Timed out after {timeout:.0f}s: {' '.join(command)}", file=sys.stderr)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    sys.exit(124)
PY
}

ab() {
  run_with_timeout 360 env \
    AGENT_BROWSER_PROVIDER=ios \
    AGENT_BROWSER_IOS_UDID="$UDID" \
    agent-browser --session "$SESSION_NAME" "$@"
}

ab_fast() {
  run_with_timeout 20 env \
    AGENT_BROWSER_PROVIDER=ios \
    AGENT_BROWSER_IOS_UDID="$UDID" \
    agent-browser --session "$SESSION_NAME" "$@"
}

capture_state() {
  local label="${1:-state}"
  if [[ -n "$UDID" ]]; then
    xcrun simctl io "$UDID" screenshot "$ARTIFACT_DIR/${label}-simulator.png" >/dev/null 2>&1 || true
  fi
  ab_fast screenshot "$ARTIFACT_DIR/${label}-safari.png" >/dev/null 2>&1 || true
  ab_fast snapshot -i >"$ARTIFACT_DIR/${label}-snapshot.txt" 2>&1 || true
  ab_fast console --json >"$ARTIFACT_DIR/${label}-console.json" 2>&1 || true
  ab_fast errors >"$ARTIFACT_DIR/${label}-errors.txt" 2>&1 || true
}

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    capture_state "failure"
  fi
  if [[ -n "$UDID" ]]; then
    ab_fast close >/dev/null 2>&1 || true
  fi
  if [[ -n "$APPIUM_PID" ]]; then
    kill "$APPIUM_PID" >/dev/null 2>&1 || true
    wait "$APPIUM_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$UDID" ]]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

echo "Selecting an iOS ${IOS_MAJOR}.x runtime and ${DEVICE_TYPE_NAME} simulator"
xcrun simctl list runtimes -j >"$ARTIFACT_DIR/runtimes.json"
xcrun simctl list devicetypes -j >"$ARTIFACT_DIR/device-types.json"

RUNTIME_ID="$({
  jq -r --arg prefix "${IOS_MAJOR}." '
    .runtimes[]
    | select(.isAvailable == true)
    | select(.name | startswith("iOS "))
    | select(.version | startswith($prefix))
    | [.version, .identifier]
    | @tsv
  ' "$ARTIFACT_DIR/runtimes.json" | sort -V | tail -n 1
} | cut -f 2)"

DEVICE_TYPE_ID="$(jq -r --arg name "$DEVICE_TYPE_NAME" '
  .devicetypes[] | select(.name == $name) | .identifier
' "$ARTIFACT_DIR/device-types.json" | head -n 1)"

if [[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "null" ]]; then
  echo "No available iOS ${IOS_MAJOR}.x runtime" >&2
  exit 1
fi
if [[ -z "$DEVICE_TYPE_ID" || "$DEVICE_TYPE_ID" == "null" ]]; then
  echo "No simulator device type named ${DEVICE_TYPE_NAME}" >&2
  exit 1
fi

UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
echo "Created $DEVICE_NAME at $UDID using $RUNTIME_ID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
open -Fn "$(xcode-select -p)/Applications/Simulator.app" \
  --args -CurrentDeviceUDID "$UDID" || true
sleep 3
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl list devices >"$ARTIFACT_DIR/devices.txt"

# agent-browser normally launches Appium with stdout/stderr pipes. A first-time
# WebDriverAgent build can fill those pipes and stall. Keep Appium's output
# draining into the uploaded artifact instead, then let agent-browser connect.
echo "Starting Appium with durable logs"
appium --relaxed-security --port 4723 >"$ARTIFACT_DIR/appium.log" 2>&1 &
APPIUM_PID=$!
APPIUM_READY=false
for _ in $(seq 1 60); do
  if curl --fail --silent http://127.0.0.1:4723/status >/dev/null; then
    APPIUM_READY=true
    break
  fi
  if ! kill -0 "$APPIUM_PID" >/dev/null 2>&1; then
    echo "Appium exited before becoming ready" >&2
    tail -n 120 "$ARTIFACT_DIR/appium.log" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "$APPIUM_READY" != true ]]; then
  echo "Appium did not become ready within 60 seconds" >&2
  tail -n 120 "$ARTIFACT_DIR/appium.log" >&2 || true
  exit 1
fi

curl --fail --location --silent --show-error "$RALFI_URL" -o /dev/null

echo "Opening the public Ralfi build in Mobile Safari"
ab open "$RALFI_URL"
ab wait --load domcontentloaded
ab wait '[data-action="DEV_QUICK_LOGIN"][data-account="client1"]'
capture_state "01-login"

echo "Using the predefined Kim Minji client account"
ab click '[data-action="DEV_QUICK_LOGIN"][data-account="client1"]'
ab wait '#btn-enter'
capture_state "02-quick-login"

echo "Entering the atrium through the visible user path"
ab click '#btn-enter'
ab wait '#skip'
ab click '#skip'
ab wait '.zone-card[data-zone-key="match"]'
ab wait --fn "window.__maeumAtriumLoaderMode === 'ios-webgl-iife'"
ab wait --fn "window.__maeumAtriumVisualMode === 'webgl'"
ab wait --fn "window.__maeumRenderStats && window.__maeumRenderStats.frames > 0"
capture_state "03-atrium-hub"

echo "Opening Counseling Confirmation from the actual atrium card"
ab click '.zone-card[data-zone-key="match"]'
ab wait '#panel.show'
ab wait --text '상담 확인'
capture_state "04-counseling-confirmation"

ab eval '(() => {
  const canvas = document.querySelector("#webgl canvas");
  let centerPixel = null;
  let webglVersion = null;
  if (canvas) {
    const gl = canvas.getContext("webgl2") || canvas.getContext("webgl");
    if (gl) {
      const pixel = new Uint8Array(4);
      gl.readPixels(
        Math.max(0, Math.floor(gl.drawingBufferWidth / 2)),
        Math.max(0, Math.floor(gl.drawingBufferHeight / 2)),
        1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel
      );
      centerPixel = Array.from(pixel);
      webglVersion = gl.getParameter(gl.VERSION);
    }
  }
  const panel = document.querySelector("#panel");
  const card = document.querySelector("#panel-card");
  return JSON.stringify({
    url: location.href,
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    touchPoints: navigator.maxTouchPoints,
    viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
    documentWidth: document.documentElement.scrollWidth,
    loaderMode: window.__maeumAtriumLoaderMode || null,
    forceStatic: window.__maeumForceStaticAtrium === true,
    visualMode: window.__maeumAtriumVisualMode || null,
    rendererProfile: window.__maeumAtriumRendererProfile || null,
    webglError: window.__maeumAtriumWebGLError || null,
    renderStats: window.__maeumRenderStats || null,
    webglVersion,
    centerPixel,
    panelDisplay: panel ? getComputedStyle(panel).display : null,
    panelOpacity: panel ? getComputedStyle(panel).opacity : null,
    panelVisible: !!(panel && panel.classList.contains("show")),
    panelTextIncludesCounselingConfirmation: !!(card && card.textContent.includes("상담 확인")),
    panelBackdropFilter: card ? getComputedStyle(card).backdropFilter : null,
    bodyClasses: document.body.className
  });
})()' >"$ARTIFACT_DIR/diagnostics.json.txt"

ab wait --fn "document.documentElement.scrollWidth <= window.innerWidth + 1"
ab wait --fn "document.querySelector('#panel.show') !== null"
ab wait --fn "document.querySelector('#panel-card') && document.querySelector('#panel-card').textContent.includes('상담 확인')"
ab wait --fn "window.__maeumAtriumVisualMode === 'webgl' && window.__maeumForceStaticAtrium !== true"
ab wait --fn "!window.__maeumAtriumWebGLError"
ab wait --fn "(() => { const c=document.querySelector('#webgl canvas'); if(!c)return false; const g=c.getContext('webgl2')||c.getContext('webgl'); if(!g)return false; const p=new Uint8Array(4); g.readPixels(Math.floor(g.drawingBufferWidth/2),Math.floor(g.drawingBufferHeight/2),1,1,g.RGBA,g.UNSIGNED_BYTE,p); return p[3] > 0 && (p[0]+p[1]+p[2]) > 0; })()"

cat >"$ARTIFACT_DIR/result.json" <<EOF
{
  "status": "passed",
  "ios_major": "${IOS_MAJOR}",
  "device": "${DEVICE_TYPE_NAME}",
  "runtime": "${RUNTIME_ID}",
  "user_path": [
    "public URL",
    "Kim Minji predefined account",
    "enter counseling room",
    "skip arrival",
    "3D atrium hub",
    "Counseling Confirmation"
  ]
}
EOF

echo "Ralfi Mobile Safari user path passed on iOS ${IOS_MAJOR}.x"
