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
NATIVE_SETUP_SESSION_ID=""

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

wd_send_keys() {
  local selector="$1"
  local value="$2"
  local response element_id payload
  response="$(wd_request POST "/session/$TEST_SESSION_ID/element" \
    "$(jq -cn --arg value "$selector" '{using:"css selector",value:$value}')")"
  element_id="$(jq -r '.value["element-6066-11e4-a52e-4f735466cecf"] // .value.ELEMENT // empty' <<<"$response")"
  if [[ -z "$element_id" ]]; then
    echo "Could not find WebDriver input element: $selector" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  payload="$(jq -cn --arg text "$value" '{text:$text,value:($text|split(""))}')"
  wd_request POST "/session/$TEST_SESSION_ID/element/$element_id/value" "$payload" >/dev/null
}

wd_select_webkit_option() {
  local selector="$1"
  local option_value="$2"
  # In actual iOS Safari, WebDriver's click on this two-option select changes
  # the WebKit value (captured in the native accessibility tree), but the
  # simulator driver omits the DOM change event. Preserve the real click and
  # dispatch only that missing event; never assign select.value in JavaScript.
  wd_click "$selector"
  if ! wd_wait webkit-option-clicked \
    "return document.querySelector('$selector')?.value === '$option_value';" 5; then
    wd_click "$selector option[value=\"$option_value\"]"
    wd_wait webkit-option-clicked-fallback \
      "return document.querySelector('$selector')?.value === '$option_value';" 5
  fi
  wd_eval "return (() => { const select=document.querySelector('$selector'); select.dispatchEvent(new Event('input',{bubbles:true})); select.dispatchEvent(new Event('change',{bubbles:true})); return select.value; })();" >/dev/null
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
  if [[ -n "$NATIVE_SETUP_SESSION_ID" ]]; then
    wd_request DELETE "/session/$NATIVE_SETUP_SESSION_ID" >/dev/null 2>&1 || true
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

# iOS 26 shows a first-run Safari coach mark over an otherwise loaded page.
# While that native popover is present, Web Inspector can report no connected
# applications even though the product is visibly rendered. Attach to Safari
# in native context first and dismiss only the system Close control. This keeps
# the subsequent product assertions in the real Safari web context.
cat >"$ARTIFACT_DIR/native-safari-setup-request.json" <<EOF
{
  "capabilities": {
    "alwaysMatch": {
      "platformName": "iOS",
      "appium:automationName": "XCUITest",
      "appium:deviceName": "${DEVICE_TYPE_NAME}",
      "appium:udid": "${UDID}",
      "appium:platformVersion": "${RUNTIME_VERSION}",
      "appium:bundleId": "com.apple.mobilesafari",
      "appium:noReset": true,
      "appium:shouldTerminateApp": false,
      "appium:forceAppLaunch": false,
      "appium:useNewWDA": false,
      "appium:wdaLaunchTimeout": 180000,
      "appium:wdaStartupRetries": 1,
      "appium:showXcodeLog": true
    }
  }
}
EOF

echo "Checking for a native Safari first-run coach mark"
if curl \
  --fail-with-body \
  --silent \
  --show-error \
  --max-time 300 \
  --request POST \
  --header 'Content-Type: application/json' \
  --data-binary "@$ARTIFACT_DIR/native-safari-setup-request.json" \
  http://127.0.0.1:4723/session \
  >"$ARTIFACT_DIR/native-safari-setup-response.json"; then
  NATIVE_SETUP_SESSION_ID="$(jq -r '.value.sessionId // .sessionId // empty' "$ARTIFACT_DIR/native-safari-setup-response.json")"
  if [[ -n "$NATIVE_SETUP_SESSION_ID" ]]; then
    wd_request GET "/session/$NATIVE_SETUP_SESSION_ID/source" \
      >"$ARTIFACT_DIR/native-safari-source.xml" 2>/dev/null || true
    CLOSE_RESPONSE="$(wd_request POST "/session/$NATIVE_SETUP_SESSION_ID/element" \
      "$(jq -cn \
        --arg value "type == 'XCUIElementTypeButton' AND (label == 'Close' OR name == 'Close' OR label == '닫기' OR name == '닫기')" \
        '{using:"-ios predicate string",value:$value}')" 2>/dev/null || true)"
    CLOSE_ELEMENT_ID="$(jq -r '.value["element-6066-11e4-a52e-4f735466cecf"] // .value.ELEMENT // empty' <<<"$CLOSE_RESPONSE")"
    if [[ -n "$CLOSE_ELEMENT_ID" ]]; then
      echo "Dismissing the native Safari first-run coach mark"
      wd_request POST "/session/$NATIVE_SETUP_SESSION_ID/element/$CLOSE_ELEMENT_ID/click" '{}' >/dev/null
      sleep 2
    fi
    wd_request DELETE "/session/$NATIVE_SETUP_SESSION_ID" >/dev/null 2>&1 || true
    NATIVE_SETUP_SESSION_ID=""
  fi
fi

open_safari_url
sleep 8

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
      "appium:webviewConnectTimeout": 60000,
      "appium:webviewConnectRetries": 60,
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

echo "Waiting for automatic administrator entry and the preserved arrival transition"
wd_wait ralfi-chat 'return !!document.querySelector("#panel.show #chat-input") && !!document.querySelector("#atrium-controls-toggle");' 120
wd_capture "01-auto-admin-main-hall-chat"
wd_eval 'return (() => {
  const visible = (node) => !!(node && getComputedStyle(node).display !== "none" && node.getBoundingClientRect().width > 0 && node.getBoundingClientRect().height > 0);
  const forbidden = ["#zone-menu", "#integrated-workspace", "#video-consultation-shell", "#atrium-menu-suggestions", "#atrium-action-cards"];
  const forbiddenVisible = forbidden.filter((selector) => visible(document.querySelector(selector)));
  return {
    url: location.href,
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    touchPoints: navigator.maxTouchPoints,
    viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
    documentWidth: document.documentElement.scrollWidth,
    title: document.title,
    bodyClasses: document.body.className,
    accountSelectorCount: document.querySelectorAll("[data-action=DEV_QUICK_LOGIN]").length,
    roleGatePresent: !!document.querySelector("#care-role-gate"),
    chatVisible: visible(document.querySelector("#panel.show #chat-input")),
    forbiddenVisible,
    actionCards: document.querySelectorAll("[data-atrium-action-card]").length,
    menuSuggestions: document.querySelectorAll("[data-atrium-menu-section]").length,
    signOutVisible: visible(document.querySelector(".atrium-chat-sign-out[data-action=\"AUTH_SIGN_OUT\"]")),
    signOutLabel: document.querySelector(".atrium-chat-sign-out[data-action=\"AUTH_SIGN_OUT\"]")?.textContent?.trim() || "",
    locale: document.documentElement.lang,
    model: document.querySelector("#atrium-text-model")?.value || null,
    promptVisible: visible(document.querySelector("#atrium-prompt-btn")),
    panelBackground: getComputedStyle(document.querySelector("#panel .panel-card")).backgroundColor,
    architecturalWindows: window.__maeumAtriumDecoration?.state?.().architecturalWindows || []
  };
})()' >"$ARTIFACT_DIR/diagnostics.json"
wd_wait chat-only-contract 'return (() => { const visible=(n)=>!!(n&&getComputedStyle(n).display!=="none"&&n.getBoundingClientRect().width>0&&n.getBoundingClientRect().height>0); const signOut=document.querySelector(".atrium-chat-sign-out[data-action=\"AUTH_SIGN_OUT\"]"); const prompt=document.querySelector("#atrium-prompt-btn"); const bg=getComputedStyle(document.querySelector("#panel .panel-card")).backgroundColor; const channels=(bg.match(/[\d.]+/g)||[]).map(Number); const alpha=channels.length>=4?channels[channels.length-1]:1; return document.documentElement.scrollWidth<=window.innerWidth+1 && alpha>=.74 && alpha<=.82 && document.body.classList.contains("ralfi-chat-only") && visible(document.querySelector("#panel.show #chat-input")) && visible(signOut) && !!prompt && document.querySelectorAll("[data-action=DEV_QUICK_LOGIN]").length===0 && !document.querySelector("#care-role-gate") && !visible(document.querySelector("#zone-menu")) && !visible(document.querySelector("#integrated-workspace")) && !visible(document.querySelector("#video-consultation-shell")) && document.querySelectorAll("[data-atrium-action-card]").length===0 && document.querySelectorAll("[data-atrium-menu-section]").length===0; })();' 90

echo "Checking the preserved tools, default Ralfi text model, and mobile prompt drawer"
wd_click '#atrium-controls-toggle'
wd_wait preserved-tools 'return (() => { const prompt=document.querySelector("#atrium-prompt-btn"); const select=document.querySelector("#atrium-text-model"); return !!document.querySelector("#atrium-voice-btn") && !!document.querySelector("#atrium-history-btn") && !!document.querySelector("#atrium-project-btn") && !!prompt && !prompt.hidden && select?.value==="live"; })();' 60
wd_click '#atrium-prompt-btn'
wd_wait prompt-open 'return document.querySelector(".atrium-chat-main")?.classList.contains("prompt-drawer-open") && !!document.querySelector("#atrium-prompt-content");' 90
wd_eval 'return (() => { const drawer=document.querySelector(".atrium-live-drawer.prompt"); const composer=document.querySelector(".chat-input-row"); drawer.scrollTop=drawer.scrollHeight; const d=drawer.getBoundingClientRect(); const c=composer.getBoundingClientRect(); const ids=["atrium-prompt-save","atrium-prompt-clear","atrium-prompt-publish"]; return {drawer:{top:d.top,bottom:d.bottom,clientHeight:drawer.clientHeight,scrollHeight:drawer.scrollHeight,scrollTop:drawer.scrollTop,overflowY:getComputedStyle(drawer).overflowY},composer:{top:c.top,bottom:c.bottom,visible:c.top>=0&&c.bottom<=innerHeight},buttons:ids.map(id=>{const n=document.getElementById(id);const r=n.getBoundingClientRect();return{id,top:r.top,bottom:r.bottom,visible:r.top>=d.top&&r.bottom<=d.bottom&&r.bottom<=innerHeight}})}; })()' >"$ARTIFACT_DIR/prompt-mobile-diagnostics.json"
wd_wait prompt-scroll-contract 'return (() => { const drawer=document.querySelector(".atrium-live-drawer.prompt"); const composer=document.querySelector(".chat-input-row"); const c=composer.getBoundingClientRect(); const buttons=["atrium-prompt-save","atrium-prompt-clear","atrium-prompt-publish"].map(id=>document.getElementById(id)?.getBoundingClientRect()); return getComputedStyle(drawer).overflowY==="auto" && c.top>=0 && c.bottom<=innerHeight && buttons.every(r=>r&&r.top>=drawer.getBoundingClientRect().top&&r.bottom<=drawer.getBoundingClientRect().bottom&&r.bottom<=innerHeight); })();' 30
wd_capture "02-mobile-prompt-scrolled"

echo "Checking minimize/restore and the two fixed main-hall windows"
wd_click '#atrium-prompt-btn'
wd_click '#atrium-chat-minimize'
wd_wait minimized 'return document.querySelector("#panel")?.classList.contains("chat-minimized") && !document.querySelector("#panel .panel-body")?.offsetParent;' 30
wd_capture "03-main-hall-minimized"
wd_wait windows-and-minimized 'return (() => { const windows=window.__maeumAtriumDecoration?.state?.().architecturalWindows||[]; const card=document.querySelector("#panel.chat-minimized .panel-card")?.getBoundingClientRect(); return windows.length===2 && windows[0].x<0 && windows[1].x>0 && card&&card.right<=innerWidth+1&&card.bottom<=innerHeight+1; })();' 30
wd_click '#atrium-chat-minimize'
wd_wait restored 'return !document.querySelector("#panel")?.classList.contains("chat-minimized") && !!document.querySelector("#chat-input")?.offsetParent;' 30

echo "Checking in-chat Korean/English controls and restoring Korean"
wd_click '.atrium-chat-locale button[data-locale="en"]'
wd_wait locale-en 'return document.documentElement.lang==="en" && document.querySelector("#chat-input")?.placeholder.startsWith("Write anything");' 60
wd_click '.atrium-chat-locale button[data-locale="ko-KR"]'
wd_wait locale-ko 'return document.documentElement.lang==="ko" && document.querySelector("#chat-input")?.placeholder.includes("편하게");' 60
wd_capture "04-restored-korean-chat"

cat >"$ARTIFACT_DIR/result.json" <<EOF
{
  "status": "passed",
  "ios_major": "${IOS_MAJOR}",
  "device": "${DEVICE_TYPE_NAME}",
  "runtime": "${RUNTIME_ID}",
  "user_path": [
    "public URL",
    "automatic administrator session without account selection",
    "preserved arrival transition",
    "Ralfi window over the main hall",
    "two fixed architectural windows",
    "minimize and restore",
    "Korean and English in-chat controls",
    "default Ralfi live text model",
    "administrator prompt drawer with reachable mobile controls",
    "disabled counseling, settings, permissions, suggestions, and action cards"
  ]
}
EOF

echo "Ralfi main-hall chat Mobile Safari user path passed on iOS ${IOS_MAJOR}.x"
