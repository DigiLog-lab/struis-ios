xcodebuild build-for-testing -project strius.xcodeproj -scheme strius -destination "id=$SIMULATOR_UDID" -derivedDataPath "$DERIVED_DATA" ARCHS=arm64 STRUIS_AUTH_REQUIRED=YES -quiet 2>&1 | grep -E " error:|BUILD FAILED" | head; xcrun simctl ui $SIMULATOR_UDID appearance dark; rm -rf "$RUNNER_TEMP/shots.xcresult"; xcodebuild test-without-building -project strius.xcodeproj -scheme strius -destination "id=$SIMULATOR_UDID" -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$RUNNER_TEMP/shots.xcresult" -only-testing:striusUITests/OnboardingScreenshotUITests/testIPhonePlanCheck 2>&1 | grep -E "error:|TEST EXECUTE" | grep -v IDEScheme | tail -10; rm -rf "$RUNNER_TEMP/att"; mkdir -p "$RUNNER_TEMP/att"; xcrun xcresulttool export attachments --path "$RUNNER_TEMP/shots.xcresult" --output-path "$RUNNER_TEMP/att" >/dev/null 2>&1; python3 -c "
import json,shutil,sys;d=sys.argv[1];o=sys.argv[2];m=json.load(open(d+\"/manifest.json\"))
for t in m:
  for a in t[\"attachments\"]:
    n=a.get(\"suggestedHumanReadableName\",\"\")
    if n.startswith(\"h\") and a[\"exportedFileName\"].endswith(\".png\"): shutil.copy(d+\"/\"+a[\"exportedFileName\"],o+\"/\"+n.split(\"_0_\")[0]+\".png\")
" "$RUNNER_TEMP/att" "$DEVBOX_FILES"; ls "$DEVBOX_FILES"
