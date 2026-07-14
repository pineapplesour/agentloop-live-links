#!/usr/bin/env bash

set -Eeuo pipefail

RALFI_URL="${RALFI_URL:?RALFI_URL is required}"
IOS_MAJOR="${IOS_MAJOR:-18}"
DEVICE_TYPE_NAME="${DEVICE_TYPE_NAME:-iPhone 16 Pro}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts/ios-${IOS_MAJOR}}"
DEVICE_NAME="${DEVICE_TYPE_NAME} Ralfi iOS ${IOS_MAJOR} Safari"
SESSION_NAME="ralfi-ios-${IOS_MAJOR}-${GITHUB_RUN_ID:-local}"
UDID=""
APPIUM_PID=""
BROWSER_SESSION_OPENED=false
TEST_SESSION_ID=""

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
    agent-browser --session "$SESSION_NAME" -p ios --device "$UDID" "$@"
}

ab_fast() {
  run_with_timeout 20 env \
    AGENT_BROWSER_PROVIDER=ios \
    AGENT_BROWSER_IOS_UDID="$UDID" \
    agent-browser --session "$SESSION_NAME" -p ios --device "$UDID" "$@"
}

open_safari_url() {
  local attempt
  for attempt in 1 2 3 4; do
    echo "Opening the target URL in Safari (attempt ${attempt}/4)"
    if run_with_timeout 45 xcrun simctl openurl "$UDID" "$RALFI_URL"; then
      return 0
    fi
    # A newly created iOS 18 simulator can report NSPOSIXErrorDomain 60 while
    # MobileSafari is still finishing its first-launch setup. Recheck the boot
    # barrier, reset only Safari, and retry instead of failing the product run.
    xcrun simctl bootstatus "$UDID" -b || true
    xcrun simctl terminate "$UDID" com.apple.mobilesafari >/dev/null 2>&1 || true
    sleep 5
  done
  echo "Safari could not open the target URL after four attempts" >&2
  return 1
}

wd_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local args=(
    --fail-with-body --silent --show-error --max-time 90
    --request "$method"
    --header 'Content-Type: application/json'
  )
  if [[ -n "$data" ]]; then
    args+=(--data-binary "$data")
  fi
  curl "${args[@]}" "http://127.0.0.1:4723${path}"
}

wd_eval() {
  local script="$1"
  local payload
  payload="$(jq -cn --arg script "$script" '{script:$script,args:[]}')"
  wd_request POST "/session/$TEST_SESSION_ID/execute/sync" "$payload"
}

wd_wait() {
  local label="$1"
  local script="$2"
  local timeout_seconds="${3:-90}"
  local deadline=$((SECONDS + timeout_seconds))
  local response=""
  while (( SECONDS < deadline )); do
    response="$(wd_eval "$script" 2>/dev/null || true)"
    if jq -e '.value == true' >/dev/null 2>&1 <<<"$response"; then
      return 0
    fi
    sleep 2
  done
  printf '%s\n' "$response" >"$ARTIFACT_DIR/wait-${label}-last-response.json"
  echo "Timed out waiting for ${label}" >&2
  return 1
}

wd_click() {
  local selector="$1"
  local response element_id
  response="$(wd_request POST "/session/$TEST_SESSION_ID/element" \
    "$(jq -cn --arg value "$selector" '{using:"css selector",value:$value}')")"
  element_id="$(jq -r '.value["element-6066-11e4-a52e-4f735466cecf"] // .value.ELEMENT // empty' <<<"$response")"
  if [[ -z "$element_id" ]]; then
    echo "Could not find WebDriver element: $selector" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  wd_request POST "/session/$TEST_SESSION_ID/element/$element_id/click" '{}' >/dev/null
}

wd_capture() {
  local label="$1"
  xcrun simctl io "$UDID" screenshot "$ARTIFACT_DIR/${label}-simulator.png" >/dev/null 2>&1 || true
  wd_request GET "/session/$TEST_SESSION_ID/screenshot" \
    | jq -r '.value // empty' \
    | openssl base64 -d -A \
    >"$ARTIFACT_DIR/${label}-safari.png" 2>/dev/null || true
  wd_request GET "/session/$TEST_SESSION_ID/source" \
    >"$ARTIFACT_DIR/${label}-source.json" 2>/dev/null || true
}

capture_state() {
  local label="${1:-state}"
  if [[ -n "$UDID" ]]; then
    xcrun simctl io "$UDID" screenshot "$ARTIFACT_DIR/${label}-simulator.png" >/dev/null 2>&1 || true
  fi
  if [[ "$BROWSER_SESSION_OPENED" == true ]]; then
    ab_fast screenshot "$ARTIFACT_DIR/${label}-safari.png" >/dev/null 2>&1 || true
    ab_fast snapshot -i >"$ARTIFACT_DIR/${label}-snapshot.txt" 2>&1 || true
    ab_fast console --json >"$ARTIFACT_DIR/${label}-console.json" 2>&1 || true
    ab_fast errors >"$ARTIFACT_DIR/${label}-errors.txt" 2>&1 || true
  fi
}

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    if [[ -n "$TEST_SESSION_ID" ]]; then
      wd_capture "failure"
    else
      capture_state "failure"
    fi
  fi
  if [[ -n "$UDID" && "$BROWSER_SESSION_OPENED" == true ]]; then
    ab_fast close >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEST_SESSION_ID" ]]; then
    wd_request DELETE "/session/$TEST_SESSION_ID" >/dev/null 2>&1 || true
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

RUNTIME_VERSION="$(jq -r --arg id "$RUNTIME_ID" '
  .runtimes[] | select(.identifier == $id) | .version
' "$ARTIFACT_DIR/runtimes.json" | head -n 1)"

if [[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "null" ]]; then
  echo "No available iOS ${IOS_MAJOR}.x runtime" >&2
  exit 1
fi
if [[ -z "$DEVICE_TYPE_ID" || "$DEVICE_TYPE_ID" == "null" ]]; then
  echo "No simulator device type named ${DEVICE_TYPE_NAME}" >&2
  exit 1
fi

# agent-browser 0.31.2 parses --device but does not copy it into the iOS launch
# request. Make the requested simulator the only iPhone Pro candidate so its
# current default selector cannot silently choose a preinstalled stale UDID.
xcrun simctl list devices -j >"$ARTIFACT_DIR/initial-devices.json"
while IFS= read -r existing_udid; do
  if [[ -n "$existing_udid" ]]; then
    xcrun simctl delete "$existing_udid" >/dev/null 2>&1 || true
  fi
done < <(jq -r '
  .devices[][]
  | select(.name | startswith("iPhone"))
  | select(.name | contains("Pro"))
  | .udid
' "$ARTIFACT_DIR/initial-devices.json")

UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
echo "Created $DEVICE_NAME at $UDID using $RUNTIME_ID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
open -Fn "$(xcode-select -p)/Applications/Simulator.app" \
  --args -CurrentDeviceUDID "$UDID" || true
sleep 3
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl list devices >"$ARTIFACT_DIR/devices.txt"

echo "Prebuilding WebDriverAgent for iOS ${RUNTIME_VERSION}"
if ! run_with_timeout 900 \
  appium driver run xcuitest build-wda -- \
    --sdk="$RUNTIME_VERSION" \
    --name="$DEVICE_NAME" \
    >"$ARTIFACT_DIR/wda-build.log" 2>&1; then
  echo "WebDriverAgent prebuild failed" >&2
  tail -n 160 "$ARTIFACT_DIR/wda-build.log" >&2 || true
  exit 1
fi

# agent-browser normally launches Appium with stdout/stderr pipes. A first-time
# WebDriverAgent build can fill those pipes and stall. Keep Appium's output
# draining into the uploaded artifact instead, then let agent-browser connect.
echo "Starting Appium with durable logs"
appium \
  --relaxed-security \
  --port 4723 \
  --default-capabilities '{"appium:wdaLaunchTimeout":180000,"appium:wdaStartupRetries":1,"appium:showXcodeLog":true,"appium:useNewWDA":false}' \
  >"$ARTIFACT_DIR/appium.log" 2>&1 &
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

# A brand-new simulator opens Safari on its Privacy Report start page, which
# does not expose a debuggable web application to Web Inspector. Load the real
# target before creating the first Appium Safari session so XCUITest can attach
# to an actual web context instead of timing out during session creation.
open_safari_url
sleep 8
xcrun simctl io "$UDID" screenshot "$ARTIFACT_DIR/prewarm-target.png" >/dev/null 2>&1 || true

cat >"$ARTIFACT_DIR/prewarm-request.json" <<EOF
{
  "capabilities": {
    "alwaysMatch": {
      "platformName": "iOS",
      "browserName": "Safari",
      "appium:automationName": "XCUITest",
      "appium:deviceName": "${DEVICE_TYPE_NAME}",
      "appium:udid": "${UDID}",
      "appium:platformVersion": "${RUNTIME_VERSION}",
      "appium:noReset": true,
      "appium:safariInitialUrl": "${RALFI_URL}",
      "appium:useNewWDA": false,
      "appium:wdaLaunchTimeout": 180000,
      "appium:wdaStartupRetries": 1,
      "appium:showXcodeLog": true
    }
  }
}
EOF

echo "Prewarming the WebDriverAgent session"
if ! curl \
  --fail-with-body \
  --silent \
  --show-error \
  --max-time 420 \
  --request POST \
  --header 'Content-Type: application/json' \
  --data-binary "@$ARTIFACT_DIR/prewarm-request.json" \
  http://127.0.0.1:4723/session \
  >"$ARTIFACT_DIR/prewarm-response.json"; then
  echo "WebDriverAgent prewarm failed" >&2
  tail -n 220 "$ARTIFACT_DIR/appium.log" >&2 || true
  exit 1
fi

PREWARM_SESSION_ID="$(jq -r '.value.sessionId // .sessionId // empty' "$ARTIFACT_DIR/prewarm-response.json")"
if [[ -z "$PREWARM_SESSION_ID" ]]; then
  echo "WebDriverAgent prewarm returned no session id" >&2
  cat "$ARTIFACT_DIR/prewarm-response.json" >&2
  exit 1
fi
curl \
  --fail-with-body \
  --silent \
  --show-error \
  --max-time 60 \
  --request DELETE \
  "http://127.0.0.1:4723/session/$PREWARM_SESSION_ID" \
  >"$ARTIFACT_DIR/prewarm-delete-response.json"
curl --silent --show-error --max-time 10 \
  http://127.0.0.1:8100/status \
  >"$ARTIFACT_DIR/wda-status-after-prewarm.json" || true

# Keep a live Safari web context available for agent-browser's second session.
# agent-browser 0.31.2 does not forward custom Safari startup capabilities.
open_safari_url
sleep 5

echo "Opening the public Ralfi build in Mobile Safari"
ab open "$RALFI_URL"
BROWSER_SESSION_OPENED=true
xcrun simctl io "$UDID" screenshot "$ARTIFACT_DIR/agent-browser-open-simulator.png" >/dev/null 2>&1 || true
ab_fast close >/dev/null 2>&1 || true
BROWSER_SESSION_OPENED=false

# agent-browser 0.31.2 currently creates a fresh Appium session for each iOS
# CLI command, so chained wait/click commands cannot reliably share one web
# context. Keep the actual user path in one standards-based WebDriver session
# on the exact Safari instance that agent-browser opened above.
open_safari_url
sleep 3
echo "Creating the persistent Mobile Safari user-path session"
wd_request POST /session "$(<"$ARTIFACT_DIR/prewarm-request.json")" \
  >"$ARTIFACT_DIR/test-session-response.json"
TEST_SESSION_ID="$(jq -r '.value.sessionId // .sessionId // empty' "$ARTIFACT_DIR/test-session-response.json")"
if [[ -z "$TEST_SESSION_ID" ]]; then
  echo "The persistent Safari session returned no session id" >&2
  cat "$ARTIFACT_DIR/test-session-response.json" >&2
  exit 1
fi

wd_wait login-gate 'return document.readyState !== "loading" && !!document.querySelector("#care-role-gate .role-card") && !!document.querySelector("[data-action=\"DEV_QUICK_LOGIN\"][data-account=\"client1\"]");' 120
wd_capture "01-login"

echo "Using the predefined Kim Minji client account"
wd_click '[data-action="DEV_QUICK_LOGIN"][data-account="client1"]'
wd_wait quick-login 'return !document.querySelector("#care-role-gate") && !!document.querySelector("#btn-enter");' 120
wd_capture "02-quick-login"

echo "Entering the atrium through the visible user path"
wd_click '#btn-enter'
wd_wait arrival-skip 'return !!document.querySelector("#skip") && getComputedStyle(document.querySelector("#skip")).display !== "none";' 60
wd_click '#skip'
wd_wait atrium-hub 'return !!document.querySelector(".zone-card[data-zone-key=\"match\"]") && window.__maeumAtriumLoaderMode === "ios-webgl-iife" && window.__maeumAtriumVisualMode === "webgl" && !!window.__maeumRenderStats && window.__maeumRenderStats.frames > 0;' 120
wd_capture "03-atrium-hub"

echo "Opening Counseling Confirmation from the actual atrium card"
wd_click '.zone-card[data-zone-key="match"]'
wd_wait counseling-confirmation 'return !!document.querySelector("#panel.show") && !!document.querySelector("#panel-card") && document.querySelector("#panel-card").textContent.includes("상담 확인");' 120
wd_capture "04-counseling-confirmation"

wd_eval 'return (() => {
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
  return {
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
  };
})()' >"$ARTIFACT_DIR/diagnostics.json"

wd_wait final-contract 'return document.documentElement.scrollWidth <= window.innerWidth + 1 && !!document.querySelector("#panel.show") && !!document.querySelector("#panel-card") && document.querySelector("#panel-card").textContent.includes("상담 확인") && window.__maeumAtriumVisualMode === "webgl" && window.__maeumForceStaticAtrium !== true && !window.__maeumAtriumWebGLError && (() => { const c=document.querySelector("#webgl canvas"); if(!c)return false; const g=c.getContext("webgl2")||c.getContext("webgl"); if(!g)return false; const p=new Uint8Array(4); g.readPixels(Math.floor(g.drawingBufferWidth/2),Math.floor(g.drawingBufferHeight/2),1,1,g.RGBA,g.UNSIGNED_BYTE,p); return p[3] > 0 && (p[0]+p[1]+p[2]) > 0; })();' 90

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
