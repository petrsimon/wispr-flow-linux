# Wispr Flow for Linux (unofficial)

[![CI](https://github.com/wispr-flow-linux/wispr-flow-linux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wispr-flow-linux/wispr-flow-linux/actions/workflows/ci.yml?query=branch%3Amain)
[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](UNLICENSE)

This project provides build scripts to run the proprietary **Wispr Flow**
voice-dictation app natively on Linux. It repackages the Windows installer and
pairs it with a **clean-room Rust helper**, producing `.deb` packages
(Debian/Ubuntu), `.rpm` packages (Fedora/RHEL), and distribution-agnostic
AppImages for amd64 and arm64, plus an
[AUR package](https://aur.archlinux.org/packages/wispr-flow-appimage) for Arch
Linux and a Nix flake. The helper reimplements the one native capability Wispr
Flow ships only for macOS and Windows: injecting transcribed text into your
focused application.

**This is a fork.** It tracks
[wispr-flow-linux/wispr-flow-linux](https://github.com/wispr-flow-linux/wispr-flow-linux)
and adds two Linux deep-link patches plus an [Omarchy](https://omarchy.org/) bar
integration on top of it — see [Omarchy](#omarchy) below. Everything else here
is upstream's work.

**This is an unofficial port.** I'm not affiliated with Wispr. For the official
app and support, see [wisprflow.ai](https://wisprflow.ai). If you hit a
build-script or Linux issue,
[open an issue](https://github.com/wispr-flow-linux/wispr-flow-linux/issues) here.

**Documentation:** full docs at [`docs/index.md`](docs/index.md). Build details
in [`docs/building.md`](docs/building.md). Release history in
[`CHANGELOG.md`](CHANGELOG.md). Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md).
Security: [`SECURITY.md`](SECURITY.md).

## Installation

Prebuilt packages ship for **amd64 and arm64** with every release. Pick the
channel for your distro; the repo channels update with your normal system
upgrades. Full details — signature verification, uninstall, per-format notes —
are in [`docs/installation.md`](docs/installation.md).

### APT (Debian/Ubuntu)

```bash
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" | sudo tee /etc/apt/sources.list.d/wispr-flow.list
sudo apt update && sudo apt install wispr-flow
```

### DNF (Fedora/RHEL)

```bash
sudo curl -fsSL https://pkg.wispr-flow-linux.dev/rpm/wispr-flow.repo -o /etc/yum.repos.d/wispr-flow.repo
sudo dnf install wispr-flow
```

### AUR (Arch Linux)

```bash
yay -S wispr-flow-appimage   # or: paru -S wispr-flow-appimage
```

### Manual download

Grab a `.deb`, `.rpm`, or `.AppImage` from the
[Releases page](https://github.com/wispr-flow-linux/wispr-flow-linux/releases).

> [!NOTE]
> These published packages bundle the proprietary Wispr Flow app, downloaded from
> Wispr's official endpoint at build time. Wispr Flow is a trademark of its
> owners; this is an unofficial community port. Prefer to supply the installer
> yourself? [Build from source](#building) instead.

## Omarchy

This fork drives Wispr Flow from the [Omarchy](https://omarchy.org/) bar:
dictation state, start/stop, the dictation language, and a live microphone level
meter while recording — with Wispr's own status bubble parked out of the way.
The integration lives in [`omarchy/`](omarchy/README.md).

Two patches make it possible, and both are in this fork only:

- **Deep links reach a running app**
  (`scripts/patches/linux-deeplink-second-instance.sh`). Wispr already answers
  `wispr-flow://start-hands-free`, `stop-hands-free`, `switch-mic` and `open`,
  but the `second-instance` handler's argv scan that delivers them was gated to
  win32, so every link aimed at an already-running app was dropped and the
  window was merely focused.
- **A `set-language` route**
  (`scripts/patches/linux-deeplink-set-language.sh`). Upstream offers no way to
  change the dictation language from outside the app; the patch adds
  `wispr-flow://set-language?lang=cs`, and a comma-separated list restores
  automatic detection.

The bar plugin drives the app entirely through those URLs — no ydotool, no
synthesized global shortcuts, no privileged access.

### Installing on Omarchy

Neither the published packages nor the AUR build carry the patches, so the
AppImage has to come from this fork:

```bash
git clone https://github.com/petrsimon/wispr-flow-linux.git
cd wispr-flow-linux
./build.sh --build appimage
omarchy/install.sh --appimage build-linux/appimage/wispr-flow-*-x86_64.AppImage
```

`install.sh` needs `jq`, touches nothing outside `$HOME`, and is safe to re-run.
It installs the AppImage to `~/.local/opt/wispr-flow/`, a
`~/.local/bin/wispr-flow` wrapper and a desktop entry claiming the
`wispr-flow:` URL scheme; drops the bar plugin into
`~/.config/omarchy/plugins/wispr.flow/`; registers it in `shell.json` (backed up
first); and restarts the shell, which a never-seen widget needs —
`rescanPlugins` will not pick it up. Flags: `--section left|center|right`,
`--languages en,cs`, `--no-icon`, `--no-restart`.

It stops there deliberately. The Hyprland rule for the status bubble, the
autostart line, and the `SUPER+CTRL+X` / `SUPER+CTRL+M` bindings are printed at
the end rather than written into your config.
[`omarchy/README.md`](omarchy/README.md) carries each of them verbatim, plus the
reasoning behind the panel's shape — why it closes before starting dictation,
and why choosing a microphone stays with `omarchy.audio`.

> [!IMPORTANT]
> This widget **replaces** Omarchy's default dictation
> ([voxtype](https://github.com/voxtype/voxtype)) rather than sitting beside it:
> two dictation front ends compete for the same microphone and the same paste
> target. Stop `voxtype.service` and take over its bindings first — the
> [switch-over](omarchy/README.md#relationship-to-voxtype) is three steps.

> [!NOTE]
> `build.sh` fetches the installer from Wispr's own endpoint, which currently
> redirects to a versionless web-installer stub rather than the Squirrel
> package. If the staging step fails there, point the build at a real installer
> with `--exe <path>`.

## Building

By default `build.sh` downloads the Wispr Flow installer from Wispr's official
endpoint at build time (the same source our [published releases](#installation)
use); the repo never bundles or commits it. Build a package with:

```bash
# Build an .rpm (downloads the installer automatically)
./build.sh --build rpm

# ...or point it at an installer you already have
./build.sh --build rpm --exe ~/Downloads/"Wispr Flow Setup-v1.5.695.exe"
```

`--exe` is optional: without it, `build.sh` fetches the latest installer and
verifies it matches the pinned version; with it, the build uses your local `.exe`
and never fetches the proprietary app.

Here are the common options (`./build.sh --help` lists all):

- `-b, --build <deb|rpm|appimage|nix>` — package format (default: auto-detected)
- `--arch <amd64|arm64>` — target architecture (default: host)
- `-e, --exe <path>` — installer .exe to use (optional; default: fetch latest)
- `-c, --clean <yes|no>` — remove intermediate build files when done

I cover prerequisites, the Linux Electron download, the native sqlite rebuild, and
the mandatory launcher rename in [`docs/building.md`](docs/building.md).

## Configuration

I documented the environment variables, state locations, the uinput udev rule,
clipboard dependencies, the GNOME extension, and AT-SPI in
[`docs/configuration.md`](docs/configuration.md).

## Troubleshooting

Run `wispr-flow --doctor` first. It's the built-in diagnostic, and it checks the
display server / session, `/dev/uinput` access, clipboard tooling, the GNOME
extension, AT-SPI, push-to-talk input access, and the launcher rename. When
something breaks, I keep symptom-keyed fixes in
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## License

Build scripts and the Rust helper in this repository are released into the public
domain under the [Unlicense](UNLICENSE). The Wispr Flow application itself is
proprietary and subject to its own terms.
