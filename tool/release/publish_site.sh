#!/bin/bash
# Builds the signed release APK and publishes it with the security page
# (docs/web) on Firebase Hosting.
#
#   tool/release/publish_site.sh          build, then deploy
#   tool/release/publish_site.sh --no-deploy
#
# Needs android/key.properties (release key, kept outside the repository).
set -euo pipefail
cd "$(dirname "$0")/../.."

[ -f android/key.properties ] || { echo "android/key.properties missing: the APK would be signed with debug keys" >&2; exit 1; }

flutter build apk --release
apk=build/app/outputs/flutter-apk/app-release.apk
site=build/site
rm -rf "$site"
mkdir -p "$site"
cp -R docs/web/. "$site/"
cp "$apk" "$site/onetime.apk"

version=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
bytes=$(stat -f%z "$apk" 2>/dev/null || stat -c%s "$apk")
sha=$(shasum -a 256 "$apk" | awk '{print $1}')
printf '{"version":"%s","bytes":%s,"sha256":"%s"}\n' "$version" "$bytes" "$sha" > "$site/apk.json"
echo "onetime.apk $version, $bytes bytes, sha256 $sha"

[ "${1:-}" = "--no-deploy" ] && exit 0
firebase deploy --only hosting --project onetime-bf68b
