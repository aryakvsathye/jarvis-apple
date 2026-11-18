#!/bin/bash
# Get the latest JARVIS app from GitHub and put it on the iPhone, without opening Xcode.
#   ~/jarvis-apple/scripts/rebuild.sh            pull, generate the project, build, install on the phone, open it
#   ~/jarvis-apple/scripts/rebuild.sh --open     pull and generate, then open Xcode instead (to press ⌘R yourself)
#   ~/jarvis-apple/scripts/rebuild.sh --team     choose the signing team again
# The phone must be unlocked, and connected by cable or on the same Wi-Fi (paired in Xcode once). With free signing the
# app stops opening after 7 days: run this again to re-sign it.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE=com.aryakvsathye.jarvis
CONF="$HOME/.config/jarvis-apple"
mkdir -p "$CONF"
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- the signing team (kept on the Mac, not in git)
pick_team() {
  local teams
  teams=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null |
    awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{print c | "openssl x509 -noout -subject -nameopt multiline"; close("openssl x509 -noout -subject -nameopt multiline")}' |
    awk -F' = ' '/organizationalUnitName/{print $2}' | sort -u)
  local n; n=$(printf '%s\n' "$teams" | grep -c . || true)
  if [ "$n" = 1 ]; then
    echo "$teams" > "$CONF/team"
  else
    [ "$n" = 0 ] || { echo "Signing teams on this Mac:"; printf '  %s\n' $teams; }
    echo "Team ID (Xcode → Settings → Accounts → your team; or developer.apple.com → Membership):"
    read -r t; [ -n "$t" ] || die "No team given."
    echo "$t" > "$CONF/team"
  fi
  echo "Signing with team $(cat "$CONF/team") (saved in $CONF/team)"
}
[ "${1:-}" = --team ] && { pick_team; shift; }
[ -s "$CONF/team" ] || pick_team
TEAM=$(cat "$CONF/team")

# ---------------------------------------------------------------- 1. the latest code
step "1/5  Getting the latest from GitHub"
[ -z "$(git status --porcelain -- . ':!JARVIS.xcodeproj' ':!JARVIS/Info.plist' ':!build')" ] ||
  die "There are local changes here (git status). Not pulling over them."
git checkout -q main
git pull -q --ff-only || die "Couldn't pull. Check the network, or git status."
echo "Now at $(cat VERSION) ($(git log -1 --format='%s' | cut -c1-70))"

# ---------------------------------------------------------------- 2. the Xcode project
step "2/5  Making the Xcode project"
command -v xcodegen >/dev/null || { echo "Installing XcodeGen…"; brew install xcodegen; }
xcodegen generate --quiet

if [ "${1:-}" = --open ]; then
  open JARVIS.xcodeproj
  echo "Opened Xcode: pick the team under Signing & Capabilities if asked, choose the phone, press ⌘R."
  exit 0
fi

# ---------------------------------------------------------------- 3. the phone
step "3/5  Finding the iPhone"
J=$(mktemp); trap 'rm -f "$J"' EXIT
xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1 || die "Couldn't list devices (is Xcode installed and opened once?)."
UDID=$(/usr/bin/python3 - "$J" "${JARVIS_DEVICE:-}" <<'PY'
import json, sys
want = sys.argv[2].lower()
ds = json.load(open(sys.argv[1]))["result"]["devices"]
def ok(d):
    hp, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    return hp.get("platform") == "iOS" and hp.get("reality") == "physical" and cp.get("pairingState") == "paired" \
        and cp.get("tunnelState") != "unavailable"
ds = [d for d in ds if ok(d)]
if want:
    ds = [d for d in ds if want in d["deviceProperties"].get("name", "").lower()]
if ds:
    print(ds[0]["hardwareProperties"]["udid"], ds[0]["deviceProperties"].get("name", "iPhone"), sep="\t")
PY
)
[ -n "$UDID" ] || die "No paired iPhone in reach. Unlock it, plug it in (or same Wi-Fi), and trust this Mac if asked."
NAME=${UDID#*$'\t'}; UDID=${UDID%%$'\t'*}
echo "Building for $NAME"

# ---------------------------------------------------------------- 4. build and sign
step "4/5  Building and signing (a minute or two; the first time longer)"
LOG="$CONF/last-build.log"
if ! xcodebuild -project JARVIS.xcodeproj -scheme JARVIS -configuration Debug \
     -destination "id=$UDID" -derivedDataPath build -allowProvisioningUpdates \
     DEVELOPMENT_TEAM="$TEAM" build >"$LOG" 2>&1; then
  grep -E "error:|Signing|provision" "$LOG" | sort -u | tail -8
  die "The build failed. Whole log: $LOG   (signing trouble: run with --team, or --open and fix it in Xcode)"
fi
APP=build/Build/Products/Debug-iphoneos/JARVIS.app
[ -d "$APP" ] || die "Built, but no app found at $APP."

# ---------------------------------------------------------------- 5. install and open
step "5/5  Installing on $NAME"
xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null || die "Couldn't install. Is the phone unlocked?"
if xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >/dev/null 2>&1; then
  echo "Done: JARVIS $(cat VERSION) is open on $NAME."
else
  echo "Installed JARVIS $(cat VERSION). Open it on the phone (it couldn't be opened from here: unlock the phone)."
fi
echo "If iOS says the developer isn't trusted: Settings → General → VPN & Device Management → trust it."
