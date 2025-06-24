#!/bin/bash

# Usage: ./build_and_log.sh [device_id]

# Fail fast on any error
set -e

# Set your scheme and optional destination (edit as needed)
SCHEME="Lidar Scan"  # <-- Replace with your scheme name
DEFAULT_SIMULATOR="platform=iOS Simulator,name=iPhone 16"

DEVICE_ID=$1

if [ -n "$DEVICE_ID" ]; then
  DESTINATION="id=$DEVICE_ID"
else
  DESTINATION="$DEFAULT_SIMULATOR"
fi


echo "Using destination: $DESTINATION"

# Output file
LOGFILE="build.log"

echo "📥 Pulling latest changes..."
git pull

echo "🛠️  Building $SCHEME ..."
# Run xcodebuild and capture full output
BUILD_OUTPUT=$(mktemp)

xcodebuild -scheme "$SCHEME" -destination "$DESTINATION" clean build 2>&1 | tee "$BUILD_OUTPUT"

#xcodebuild -scheme "room-plan" -destination "platform=iOS Simulator,name=iPhone 16" clean build 2>&1 | tee "$BUILD_OUTPUT"

# Extract only errors to build.log
grep -i "error" "$BUILD_OUTPUT" > "$LOGFILE"

# Clean up temp file
rm "$BUILD_OUTPUT"


echo "✅ Done. Log saved to $LOGFILE"
