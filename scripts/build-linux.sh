#!/usr/bin/env bash
set -euo pipefail

# Build reproducible Linux artifacts (Flatpak + tar.xz + SHA256SUMS) directly
# from an official cake-tech/cake_wallet release tag.
#
# Usage:
#   ./scripts/build-linux.sh <tag> [out_dir]
#
# Optional environment variables:
#   UPSTREAM_REPO           Git URL of official upstream (default: https://github.com/cake-tech/cake_wallet.git)
#   WORK_DIR                Working checkout directory (default: $PWD/src)
#   PRUNE_DOCKER            If "true", remove extracted deps image before pulling Flutter builder (recommended on CI)
#   CAKE_BUILD_SECRETS_JSON Optional JSON object with persistent build salts/keys so upgrades stay compatible across releases

TAG="${1:?Usage: $0 <tag> [out_dir]}"
OUT_DIR="$(mkdir -p "${2:-$PWD/dist}" && cd "${2:-$PWD/dist}" && pwd)"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/cake-tech/cake_wallet.git}"
WORK_DIR="${WORK_DIR:-$PWD/src}"
PRUNE_DOCKER="${PRUNE_DOCKER:-false}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

log() {
  echo ""
  echo "================================================================"
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
  echo "================================================================"
}

log "1/6 Cloning official upstream tag ${TAG} from ${UPSTREAM_REPO}"
rm -rf "$WORK_DIR"
git clone --depth 1 --branch "$TAG" "$UPSTREAM_REPO" "$WORK_DIR"
UPSTREAM_COMMIT="$(git -C "$WORK_DIR" rev-parse HEAD)"
echo "Upstream tag    : ${TAG}"
echo "Upstream commit : ${UPSTREAM_COMMIT}"

# Detect the official Cake Wallet Docker builder image dynamically from upstream
BUILDER_IMAGE=""
if [[ -f "$WORK_DIR/scripts/linux/docker/Dockerfile.base" ]]; then
  BUILDER_IMAGE="$(grep -Eo 'ghcr\.io/cake-tech/cake_wallet:[^[:space:]]+' "$WORK_DIR/scripts/linux/docker/Dockerfile.base" | head -n 1 || true)"
fi
if [[ -z "$BUILDER_IMAGE" && -f "$WORK_DIR/scripts/linux/build_cake_release.sh" ]]; then
  BUILDER_IMAGE="$(grep -Eo 'ghcr\.io/cake-tech/cake_wallet:[^[:space:]"]+' "$WORK_DIR/scripts/linux/build_cake_release.sh" | head -n 1 || true)"
fi
if [[ -z "$BUILDER_IMAGE" && -f "$WORK_DIR/docs/builds/LINUX.md" ]]; then
  BUILDER_IMAGE="$(grep -Eo 'ghcr\.io/cake-tech/cake_wallet:[^[:space:]`]+' "$WORK_DIR/docs/builds/LINUX.md" | head -n 1 || true)"
fi
if [[ -z "$BUILDER_IMAGE" ]]; then
  echo "ERROR: Could not detect official Docker builder image from upstream repository." >&2
  exit 1
fi
echo "Builder image   : ${BUILDER_IMAGE}"

log "2/6 Extracting prebuilt Linux native dependencies from GHCR"
DEPS_IMAGE_USED="built-from-source"
if [[ -x "$WORK_DIR/scripts/linux/docker/build.sh" ]]; then
  set +e
  CW_DOCKER_REGISTRY="ghcr.io/cake-tech/cake_wallet" \
  CW_DOCKER_USE_CLOUD="true" \
    "$WORK_DIR/scripts/linux/docker/build.sh" --extract
  EXTRACT_RC=$?
  set -e

  if [[ $EXTRACT_RC -eq 0 ]]; then
    DEPS_IMAGE_USED="$(cat /tmp/cakewallet_docker 2>/dev/null || echo 'ghcr-prebuilt')"
    echo "Extracted official prebuilt native dependencies: ${DEPS_IMAGE_USED}"
  else
    echo "Prebuilt final image not found on GHCR for ${TAG}; falling back to local build (no push)."
    CW_DOCKER_REGISTRY="ghcr.io/cake-tech/cake_wallet" \
    CW_DOCKER_USE_CLOUD="" \
      "$WORK_DIR/scripts/linux/docker/build.sh"
    DEPS_IMAGE_USED="local-fallback"
  fi

  if [[ "$PRUNE_DOCKER" == "true" ]]; then
    echo "Reclaiming Docker disk space after extracting native dependencies..."
    if [[ -f /tmp/cakewallet_docker ]]; then
      docker rmi -f "$(cat /tmp/cakewallet_docker)" >/dev/null 2>&1 || true
    fi
    docker image prune -af >/dev/null 2>&1 || true
    docker builder prune -af >/dev/null 2>&1 || true
    df -h /
  fi
else
  echo "ERROR: scripts/linux/docker/build.sh not found in upstream tag ${TAG}." >&2
  exit 1
fi

log "3/6 Applying minimal Linux desktop & Flatpak packaging fixes"
# 1) Add StartupWMClass=cake_wallet so KDE Plasma / GNOME docks match the running window to its icon
DESKTOP_FILE="$WORK_DIR/linux/com.cakewallet.CakeWallet.desktop"
if [[ -f "$DESKTOP_FILE" ]]; then
  if ! grep -q '^StartupWMClass=' "$DESKTOP_FILE"; then
    echo "StartupWMClass=cake_wallet" >> "$DESKTOP_FILE"
    echo "Patched ${DESKTOP_FILE}: added StartupWMClass=cake_wallet"
  fi
fi

# 2) Fix libwarp_api_ffi.so (Zcash) runtime linkage on org.freedesktop.Platform (libbz2.so.1.0 -> libbz2.so.1)
FLATPAK_MANIFEST="$WORK_DIR/com.cakewallet.CakeWallet.yml"
if [[ -f "$FLATPAK_MANIFEST" ]]; then
  python3 - "$FLATPAK_MANIFEST" << 'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
marker = "libbz2.so.1.0"
if marker not in text:
    needle = '      - "ln -s /app/cake_wallet/cake_wallet /app/bin/cake_wallet"'
    addition = (
        needle
        + '\n      - "mkdir -p /app/lib"'
        + '\n      - "if [ ! -e /usr/lib/x86_64-linux-gnu/libbz2.so.1.0 ] && [ -e /usr/lib/x86_64-linux-gnu/libbz2.so.1 ]; then ln -sf /usr/lib/x86_64-linux-gnu/libbz2.so.1 /app/lib/libbz2.so.1.0; fi"'
    )
    if needle in text:
        text = text.replace(needle, addition, 1)
    else:
        text = text.replace(
            "    build-commands:\n",
            "    build-commands:\n"
            '      - "mkdir -p /app/lib"\n'
            '      - "if [ ! -e /usr/lib/x86_64-linux-gnu/libbz2.so.1.0 ] && [ -e /usr/lib/x86_64-linux-gnu/libbz2.so.1 ]; then ln -sf /usr/lib/x86_64-linux-gnu/libbz2.so.1 /app/lib/libbz2.so.1.0; fi"\n',
            1,
        )
    p.write_text(text, encoding="utf-8")
    print(f"Patched {p}: added libbz2.so.1.0 compatibility symlink for Zcash")
else:
    print(f"{p} already handles libbz2.so.1.0")
PYEOF
fi

log "4/6 Pulling official Cake Wallet builder image (${BUILDER_IMAGE})"
docker pull "$BUILDER_IMAGE"
df -h / || true

log "5/6 Building Flutter release, Flatpak bundle, tar.xz archive, and verifying sandbox linkage"
# Pass persistent build salts via temp file mounted read-only (never echoed to stdout/logs)
SECRETS_TMP="$(mktemp)"
chmod 600 "$SECRETS_TMP"
trap 'rm -f "$SECRETS_TMP"' EXIT
if [[ -n "${CAKE_BUILD_SECRETS_JSON:-}" ]]; then
  printf '%s' "$CAKE_BUILD_SECRETS_JSON" > "$SECRETS_TMP"
else
  printf '{}' > "$SECRETS_TMP"
fi

docker run --rm --privileged \
  -e "TAG=${TAG}" \
  -e "OUT_DIR=${OUT_DIR}" \
  -e "HOST_UID=${HOST_UID}" \
  -e "HOST_GID=${HOST_GID}" \
  -v "$WORK_DIR:$WORK_DIR" \
  -v "$OUT_DIR:$OUT_DIR" \
  -v "$SECRETS_TMP:/run/cake-build-secrets.json:ro" \
  -w "$WORK_DIR" \
  "$BUILDER_IMAGE" bash -e << 'CONTAINER_EOF'
set -euo pipefail
git config --global --add safe.directory '*'

echo "=== Configuring Cake Wallet for Linux ==="
pushd scripts/linux
  set +u
  source ./app_env.sh cakewallet
  set -u
  ./app_config.sh
popd

echo "=== Installing Flutter dependencies ==="
flutter pub get

echo "=== Generating secrets config ==="
set +x
SECRET_ARGS=(--force)
if [[ -s /run/cake-build-secrets.json ]]; then
  mapfile -t EXTRA_ARGS < <(python3 - << 'PYSECRETS'
import json, sys

with open("/run/cake-build-secrets.json", "r", encoding="utf-8") as f:
    data = json.load(f)

if not data:
    sys.exit(0)

expected = {
    "salt": 32,
    "keychain_salt": 24,
    "key": 32,
    "wallet_salt": 8,
    "short_key": 24,
    "backup_salt": 16,
    "backup_keychain_salt": 24,
    "wallet_group_salt": 32,
}

for k, length in expected.items():
    v = data.get(k, "")
    if not isinstance(v, str) or len(v) != length:
        raise SystemExit(f"ERROR: Secret '{k}' must be a {length}-character string (got length {len(str(v))})")
    print(f"{k}={v}")
PYSECRETS
  )
  if (( ${#EXTRA_ARGS[@]} > 0 )); then
    echo "Using persistent build keyset from repository secrets (${#EXTRA_ARGS[@]} keys validated)."
    SECRET_ARGS+=("${EXTRA_ARGS[@]}")
  else
    echo "No persistent build keyset provided; generating fresh local build salts."
  fi
fi
dart run tool/generate_new_secrets.dart "${SECRET_ARGS[@]}"
unset EXTRA_ARGS SECRET_ARGS

# Validate generated lib/.secrets.g.dart lengths without ever printing values
python3 - << 'PYCHECK'
import re
from pathlib import Path

content = Path("lib/.secrets.g.dart").read_text(encoding="utf-8")
required = {
    "salt": 32,
    "keychainSalt": 24,
    "key": 32,
    "walletSalt": 8,
    "shortKey": 24,
    "backupSalt": 16,
    "backupKeychainSalt": 24,
    "walletGroupSalt": 32,
}
for name, length in required.items():
    m = re.search(rf"const\s+{name}\s*=\s*'([^']*)'", content)
    if not m or len(m.group(1)) != length:
        raise SystemExit(f"ERROR: Generated secret '{name}' missing or invalid length")
print("Validated all 8 required internal crypto salts/keys in lib/.secrets.g.dart.")
PYCHECK

echo "=== Generating Dart models ==="
./model_generator.sh

echo "=== Generating localization ==="
dart run tool/generate_localization.dart

if [[ -x ./compile_graphics.sh ]]; then
  echo "=== Compiling SVG vector graphics ==="
  ./compile_graphics.sh
fi

echo "=== Building Flutter Linux release ==="
flutter build linux --release

BUNDLE_DIR="$PWD/build/linux/x64/release/bundle"
for req in cake_wallet lib/libmonero_wallet2_api_c.so lib/libwownero_wallet2_api_c.so lib/libwarp_api_ffi.so; do
  if [[ ! -e "$BUNDLE_DIR/$req" ]]; then
    echo "ERROR: Expected build artifact missing: $BUNDLE_DIR/$req" >&2
    exit 1
  fi
done
echo "Verified bundle binary and native libraries in $BUNDLE_DIR"

echo "=== Packaging portable tar.xz archive ==="
ARCHIVE_ROOT="Cake_Wallet_${TAG}_Linux"
STAGE_DIR="/tmp/${ARCHIVE_ROOT}"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "$BUNDLE_DIR/." "$STAGE_DIR/"
cp -a linux/com.cakewallet.CakeWallet.desktop "$STAGE_DIR/"
cp -a assets/images/cakewallet_icon_180.png "$STAGE_DIR/com.cakewallet.CakeWallet.png"
tar -C /tmp -cJf "${OUT_DIR}/Cake_Wallet_${TAG}_Linux.tar.xz" "${ARCHIVE_ROOT}"
rm -rf "$STAGE_DIR"

echo "=== Ensuring matching Flatpak runtime is available ==="
RT_VER="$(grep -E "^runtime-version:" com.cakewallet.CakeWallet.yml | head -n1 | sed -E "s/.*['\"]?([0-9]+\.[0-9]+)['\"]?.*/\1/")"
echo "Flatpak runtime-version: ${RT_VER}"
if ! flatpak info "org.freedesktop.Platform//${RT_VER}" >/dev/null 2>&1; then
  flatpak install -y --noninteractive flathub "org.freedesktop.Platform//${RT_VER}" "org.freedesktop.Sdk//${RT_VER}"
fi

echo "=== Building Flatpak bundle ==="
rm -rf build/linux/current .flatpak-builder flatpak-build export
cp -r build/linux/x64 build/linux/current
flatpak-builder --force-clean flatpak-build com.cakewallet.CakeWallet.yml
flatpak build-export export flatpak-build
flatpak build-bundle export "${OUT_DIR}/Cake_Wallet_${TAG}_Linux.flatpak" com.cakewallet.CakeWallet

echo "=== Verifying Flatpak bundle inside sandbox ==="
flatpak install -y --noninteractive "${OUT_DIR}/Cake_Wallet_${TAG}_Linux.flatpak"
echo "--- version.json ---"
flatpak run --command=cat com.cakewallet.CakeWallet /app/cake_wallet/data/flutter_assets/version.json
echo ""
echo "--- desktop entry ---"
flatpak run --command=cat com.cakewallet.CakeWallet /app/share/applications/com.cakewallet.CakeWallet.desktop
echo "--- shared library linkage check ---"
flatpak run --command=sh com.cakewallet.CakeWallet -c '
  set -euo pipefail
  export LD_LIBRARY_PATH="/app/cake_wallet/lib:/app/lib"
  for f in \
    /app/cake_wallet/cake_wallet \
    /app/cake_wallet/lib/libmonero_wallet2_api_c.so \
    /app/cake_wallet/lib/libwownero_wallet2_api_c.so \
    /app/cake_wallet/lib/libwarp_api_ffi.so; do
    echo "Checking $f"
    if ldd "$f" | grep -i "not found"; then
      echo "ERROR: Missing shared library for $f" >&2
      exit 1
    fi
  done
  ls -lh /app/cake_wallet/lib/
  echo "ALL_FLATPAK_LINKAGE_CHECKS_PASSED"
'
flatpak uninstall -y --noninteractive com.cakewallet.CakeWallet || true

chown -R "${HOST_UID}:${HOST_GID}" "${OUT_DIR}"
CONTAINER_EOF

log "6/6 Generating SHA256SUMS and build metadata"
(
  cd "$OUT_DIR"
  sha256sum "Cake_Wallet_${TAG}_Linux.flatpak" "Cake_Wallet_${TAG}_Linux.tar.xz" > SHA256SUMS
  cat SHA256SUMS
)

python3 - "$OUT_DIR/build-metadata.json" "$TAG" "$UPSTREAM_COMMIT" "$BUILDER_IMAGE" "$DEPS_IMAGE_USED" << 'PYMETA'
import json, sys, datetime
out, tag, commit, builder, deps = sys.argv[1:]
meta = {
    "tag": tag,
    "upstream_commit": commit,
    "builder_image": builder,
    "deps_image": deps,
    "built_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
print(json.dumps(meta, indent=2))
PYMETA

ls -lh "$OUT_DIR"
log "Build completed successfully for Cake Wallet ${TAG}!"
