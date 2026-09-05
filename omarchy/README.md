[< Back to docs index](../docs/index.md)

# Omarchy integration

Drives Wispr Flow from the [Omarchy](https://omarchy.org/) bar: dictation
state, start/stop, microphone and dictation language, with Wispr's own status
bubble out of the way.

```bash
omarchy/install.sh --appimage build-linux/appimage/wispr-flow-1.6.7-x86_64.AppImage
```

Everything it installs lives under `$HOME`; nothing needs root.

## What it installs

| Path | What |
|---|---|
| `~/.config/omarchy/plugins/wispr.flow/` | the bar plugin (`Panel.qml`, `wispr-state`, `manifest.json`) |
| `~/.config/omarchy/shell.json` | a `wispr.flow` entry in the bar layout (backed up first) |
| `~/.local/opt/wispr-flow/wispr-flow.AppImage` | the app, with `--appimage` |
| `~/.local/bin/wispr-flow` | wrapper, with `--appimage` |
| `~/.local/share/applications/wispr-flow.desktop` | desktop entry claiming the `wispr-flow:` URL scheme, with `--appimage` |

Pass `--section left\|center\|right` to place the widget, `--languages en,cs`
to override the offered languages, and `--no-restart` to skip the shell
restart. Re-running is safe: an existing bar entry is updated in place.

## The widget

Left click opens the panel; right click toggles dictation without opening it;
middle click raises the Hub. Inside the panel: dictation state, a start/stop
button, the microphone list and the language list, each with the current
choice checked. `j`/`k` walk the rows, Enter activates, Escape closes.

Dictation is always driven with the panel shut: an open panel holds keyboard
focus, and Wispr records the focused window at start and synthesizes the paste
keystroke into it at stop, so a dictation started from an open panel would end
with the transcript on the clipboard and nowhere else. Starting or stopping
from inside the panel therefore closes it first and gives the compositor a
moment to hand focus back. Right click is the shortest path: it toggles
dictation without opening the panel at all.

The panel drives the app entirely through its `wispr-flow:` deep links, so it
needs no privileged access and no window of Wispr's own. Three of the patches
in `scripts/patches/` have to be in the build for it to work:

- `linux-deeplink.sh` — cold-start URL delivery
- `linux-deeplink-second-instance.sh` — delivery to a **running** app, which is
  what every click depends on
- `linux-deeplink-set-language.sh` — the `set-language` route, which upstream
  does not ship at all

`wispr-state` gathers what the panel draws — it is a plain script, so the log
and config parsing can be checked from a shell:

```bash
~/.config/omarchy/plugins/wispr.flow/wispr-state en,cs | jq .
```

## Notes

- **Languages are captured at install time** from the app's own
  `selectedLanguages`. Pinning one language rewrites that list, so the original
  set has to be recorded first or it is lost. Change it later with
  `--languages`, or by editing the widget's entry in `shell.json`.
- **The device list comes from the log, not from `config.json`.** The ranked
  list in the config remembers microphones that are unplugged, and the app
  refuses to switch to those; the `audioDevices` array it logs on every
  settings sync holds only what is actually connected.
- **A new bar widget needs a full shell restart.** `omarchy-shell shell
  rescanPlugins` reloads code for plugins already in the registry; a widget the
  shell has never seen leaves its slot empty until `omarchy restart shell`.
- **A language switch is not persisted** and the Hub's own picker will not
  reflect it: the route sets the in-memory pref that the transcription request
  builders read, and the renderer's store is not notified. It survives until
  the app restarts.

## Hyprland

Neither is installed for you — the installer prints both at the end, because
editing someone's Hyprland config is not its business.

Wispr's status bubble is a mostly-transparent Electron surface that Hyprland
places badly, and it cannot be clicked on Wayland at all: the app decides
whether a click counts by polling the global cursor position, which Wayland
does not provide, so it stays click-through. The bar widget replaces it.

```lua
o.window({ class = "^wispr-flow$", initial_title = "^Flow Status Indicator$" }, {
  workspace = "special:wispr silent",
  float = true,
  no_focus = true,
  no_initial_focus = true,
  no_anim = true,
})
```

The window's title only becomes `Status` after mapping, which is why the rule
matches on the initial title. Parking it on a special workspace rather than
suppressing it keeps the app's own `show()`/`focus()` calls harmless.

To start Wispr with the session, in `~/.config/hypr/autostart.lua`:

```lua
o.launch_on_start("wispr-flow")
```
