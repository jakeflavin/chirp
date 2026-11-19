#!/bin/zsh
# Builds a signed, notarized Chirp.dmg for a tag, and the sparkle.json the update feed is made from
# (Scripts/appcast.py). Used by .github/workflows/release.yml, and by hand when CI is down (Docs/RELEASING.md).
#
# Usage: Scripts/release.sh v0.3.0-beta.1
#
# Needs, in the environment:
#   APPLE_TEAM_ID         the team of the Developer ID Application certificate (in the keychain)
#   SIGNING_KEYCHAIN      optional: the keychain that holds it (CI makes a temporary one)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key for notarytool,
#     or NOTARY_PROFILE: a notarytool keychain profile (xcrun notarytool store-credentials)
#   SPARKLE_KEY_PATH      optional: the Sparkle private key as a file; without it sign_update uses the "chirp" key in the keychain
#   BUILD_NUMBER          optional: the build number (CI passes its run number); default: a timestamp
#   SIGN_IDENTITY         optional: the signing certificate; default "Developer ID Application". Any other identity
#                         (for example "Apple Development") makes a build that isn't notarized: macOS asks people to
#                         right-click › Open the first time. Only for when a Developer ID isn't available yet.
#   DERIVED_DATA          optional: the build folder; default .dd-release
set -euo pipefail
cd "${0:A:h:h}"

tag=${1:?usage: Scripts/release.sh vX.Y.Z[-beta.N]}
[[ $tag == v<->.<->.<->* ]] || { echo "The tag must look like v1.2.3 or v1.2.3-beta.1"; exit 1; }
version=${tag#v}
build=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
if [[ $version == *-beta* ]]; then channel=Beta; else channel=; fi
identity=${SIGN_IDENTITY:-Developer ID Application}
[[ $identity == "Developer ID Application"* ]] && notarized=1 || notarized=0
derived=${DERIVED_DATA:-.dd-release}
out=build/release
rm -rf $out && mkdir -p $out

echo "==> Building Chirp $version ($build), channel: ${channel:-stable}"
Scripts/bootstrap.sh
xcodebuild -project Chirp.xcodeproj -scheme Chirp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived \
  -skipMacroValidation -skipPackagePluginValidation \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build CHIRP_CHANNEL=$channel \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=$APPLE_TEAM_ID \
  OTHER_CODE_SIGN_FLAGS="--timestamp${SIGNING_KEYCHAIN:+ --keychain $SIGNING_KEYCHAIN}" \
  build | grep -E "error:|warning: .*Sign|BUILD (SUCCEEDED|FAILED)" || true
app=$derived/Build/Products/Release/Chirp.app
[[ -d $app ]] || { echo "The build failed."; exit 1; }
codesign --verify --deep --strict $app
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' $app/Contents/Info.plist | grep -q . || { echo "The update key is missing from the build."; exit 1; }

notarize() {
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit "$1" --keychain-profile $NOTARY_PROFILE --wait
  else
    xcrun notarytool submit "$1" --key $NOTARY_KEY_PATH --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER --wait
  fi
}

if (( notarized )); then
  echo "==> Notarizing the app"
  ditto -c -k --keepParent $app $out/Chirp.zip
  notarize $out/Chirp.zip
  xcrun stapler staple $app
else
  echo "==> Not notarized: signed with $identity"
fi

echo "==> Making the disk image"
# dmgbuild writes the window's layout (Scripts/dmg) into the image, so Finder doesn't need to be scripted.
venv=build/dmg-venv
[[ -x $venv/bin/dmgbuild ]] || { python3 -m venv $venv && $venv/bin/pip install -q dmgbuild==1.6.5; }
$venv/bin/dmgbuild -s Scripts/dmg/settings.py -D app=$app -D assets=Scripts/dmg Chirp $out/Chirp.dmg >/dev/null 2>&1
[[ -f $out/Chirp.dmg ]] || { echo "Making the disk image failed."; exit 1; }
keychain=(); [[ -n ${SIGNING_KEYCHAIN:-} ]] && keychain=(--keychain $SIGNING_KEYCHAIN)
codesign --sign "$identity" --timestamp $keychain $out/Chirp.dmg
if (( notarized )); then
  notarize $out/Chirp.dmg
  xcrun stapler staple $out/Chirp.dmg
  spctl --assess --type open --context context:primary-signature -v $out/Chirp.dmg
fi

echo "==> Signing the update"
sign_update=$(find $derived/SourcePackages/artifacts -name sign_update -type f -perm +111 | head -1)
if [[ -n ${SPARKLE_KEY_PATH:-} ]]; then key=(--ed-key-file $SPARKLE_KEY_PATH); else key=(--account chirp); fi
signature=$($sign_update $key $out/Chirp.dmg)
python3 - "$out/sparkle.json" "$version" "$build" "${channel:l}" "$signature" "$notarized" <<'EOF'
import json, re, sys
path, version, build, channel, signature, notarized = sys.argv[1:]
fields = dict(re.findall(r'(\S+?)="([^"]*)"', signature))
json.dump({"version": version, "build": build, "channel": channel or None,
           "edSignature": fields["sparkle:edSignature"], "length": int(fields["length"]),
           "minimumSystemVersion": "26.0", "notarized": bool(int(notarized))}, open(path, "w"), indent=2)
EOF
rm -f $out/Chirp.zip
echo "==> Done: $out/Chirp.dmg and $out/sparkle.json"
