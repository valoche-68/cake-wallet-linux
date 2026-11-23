# Cake Wallet — Automated Linux Builds (Flatpak & tar.xz)

[![Build Linux Release](https://github.com/valoche-68/cake-wallet-linux/actions/workflows/linux-release.yml/badge.svg)](https://github.com/valoche-68/cake-wallet-linux/actions/workflows/linux-release.yml)
[![Latest Release](https://img.shields.io/github/v/release/valoche-68/cake-wallet-linux?label=Latest%20Linux%20Release)](https://github.com/valoche-68/cake-wallet-linux/releases/latest)

**Pre-built, ready-to-install Linux x86_64 binaries (`Flatpak` & `tar.xz`) for [Cake Wallet](https://github.com/cake-tech/cake_wallet)**, automatically synced and compiled via public GitHub Actions whenever a new official release is published upstream.

> **Why this fork exists:** Official releases of `cake-tech/cake_wallet` frequently lag behind on Linux desktop builds. This fork tracks official releases automatically every 6 hours and publishes up-to-date Linux builds with full public CI logs and SHA-256 checksums.

---

## Download & Install

Grab the latest release from the [**Releases page**](https://github.com/valoche-68/cake-wallet-linux/releases/latest).

### Option 1: Flatpak (Recommended)

```bash
# Verify checksum
sha256sum -c SHA256SUMS --ignore-missing

# Install or update (user-level, no root required)
flatpak install --user -y Cake_Wallet_v*_Linux.flatpak

# Launch
flatpak run com.cakewallet.CakeWallet
```

### Option 2: Portable Archive (`.tar.xz`)

```bash
tar -xf Cake_Wallet_v*_Linux.tar.xz
cd Cake_Wallet_v*_Linux
./cake_wallet
```

---

## Transparency, Security & Verification

Because Cake Wallet is a non-custodial cryptocurrency wallet, build transparency is paramount:

1. **Zero wallet source code changes**: Every release is compiled directly from the exact, unaltered official tag of [`cake-tech/cake_wallet`](https://github.com/cake-tech/cake_wallet/releases). Each tag on this fork points to the exact upstream commit SHA.
2. **Official build toolchain**: Builds use Cake Tech's own official Docker builder image and prebuilt native dependencies (`monero`, `wownero`, `zcash`, `mwebd`, `reown`, `torch`) from `ghcr.io/cake-tech/cake_wallet`.
3. **Public CI & Checksums**: Every release links to its public GitHub Actions build log and ships a `SHA256SUMS` file.
4. **Minimal Linux packaging fixes only** (visible in [`scripts/build-linux.sh`](scripts/build-linux.sh)):
   - Adds a compatibility symlink `/app/lib/libbz2.so.1.0 -> /usr/lib/x86_64-linux-gnu/libbz2.so.1` inside the Flatpak so Zcash (`libwarp_api_ffi.so`) loads properly on `org.freedesktop.Platform//24.08`.
   - Adds `StartupWMClass=cake_wallet` to `com.cakewallet.CakeWallet.desktop` for proper KDE Plasma / GNOME taskbar icon matching.
   - Runs an automated post-build Flatpak sandbox verification (`version.json` + `ldd` linkage check on all native crypto libraries) before publishing.
5. **Upgrade compatibility**: Releases built by this repository use a persistent set of internal build salts stored in GitHub Actions Secrets so upgrading from one release of `valoche-68/cake-wallet-linux` to the next seamlessly keeps your PIN, local wallets, and backups working.
   > **Note:** When migrating *from* official Cake Tech builds (or another custom build) *to* this fork for the first time, restore your wallet using your seed phrase (standard non-custodial wallet precaution).

---

## How Automatic Updates Work

- **Default branch (`linux-releases`)**: Holds only the CI workflow (`.github/workflows/linux-release.yml`), build script (`scripts/build-linux.sh`), and this documentation — guaranteeing zero merge conflicts with upstream.
- **Mirrored upstream branches (`dev`, `main`)**: Automatically synced with `cake-tech/cake_wallet`.
- **Schedule**: GitHub Actions checks `cake-tech/cake_wallet/releases/latest` every 6 hours (and can also be triggered manually via **Actions -> Sync & Build Cake Wallet Linux Release -> Run workflow**).

---

## Credits & License

All Cake Wallet source code belongs to [Cake Technologies LLC (`cake-tech/cake_wallet`)](https://github.com/cake-tech/cake_wallet) under its original MIT license. This repository is an independent, unofficial community Linux build automation fork.
