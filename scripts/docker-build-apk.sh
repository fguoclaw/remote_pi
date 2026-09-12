#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Share Docker caches from the primary worktree, not each linked worktree.
MAIN_ROOT="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree / { sub(/^worktree /, ""); print; exit }')"
MAIN_ROOT="${MAIN_ROOT:-$ROOT}"
IMAGE="${FLUTTER_DOCKER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
MODE="${1:-debug}"
CACHE_DIR="$MAIN_ROOT/dockercache"
PUB_CACHE="$CACHE_DIR/pub"
GRADLE_CACHE="$CACHE_DIR/gradle"
ANDROID_CACHE="$CACHE_DIR/android-sdk"
ANDROID_PLATFORMS="$ANDROID_CACHE/platforms"
ANDROID_BUILD_TOOLS="$ANDROID_CACHE/build-tools"
ANDROID_NDK="$ANDROID_CACHE/ndk"
ANDROID_CMAKE="$ANDROID_CACHE/cmake"
ANDROID_LICENSES="$ANDROID_CACHE/licenses"

case "$MODE" in
  debug|release) ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 2
    ;;
esac

# Do not mount $ANDROID_CACHE over /opt/android-sdk-linux wholesale.
# That would hide the SDK command-line tools already present in the Flutter
# image and make Flutter report "No Android SDK found". Cache only the heavy
# downloaded subdirs while keeping the image's base SDK/tools visible.
mkdir -p \
  "$PUB_CACHE" \
  "$GRADLE_CACHE" \
  "$ANDROID_PLATFORMS" \
  "$ANDROID_BUILD_TOOLS" \
  "$ANDROID_NDK" \
  "$ANDROID_CMAKE" \
  "$ANDROID_LICENSES"

tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args=(-it)
fi

# ${tty_args[@]+...} instead of plain "${tty_args[@]}": macOS ships bash 3.2,
# where expanding an empty array under `set -u` aborts with
# "tty_args[@]: unbound variable". The guarded form is 3.2-safe and still
# works on bash 4/5.
docker run --rm ${tty_args[@]+"${tty_args[@]}"} \
  -v "$ROOT":/work \
  -v "$PUB_CACHE":/root/.pub-cache \
  -v "$GRADLE_CACHE":/root/.gradle \
  -v "$ANDROID_PLATFORMS":/opt/android-sdk-linux/platforms \
  -v "$ANDROID_BUILD_TOOLS":/opt/android-sdk-linux/build-tools \
  -v "$ANDROID_NDK":/opt/android-sdk-linux/ndk \
  -v "$ANDROID_CMAKE":/opt/android-sdk-linux/cmake \
  -v "$ANDROID_LICENSES":/opt/android-sdk-linux/licenses \
  -w /work/app \
  "$IMAGE" \
  bash -lc "yes | flutter doctor --android-licenses >/dev/null && flutter pub get && flutter build apk --$MODE"
