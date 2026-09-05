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
| — | nothing else; the keybinding and the Hyprland rules are printed, not applied |
| `~/.local/opt/wispr-flow/wispr-flow.AppImage` | the app, with `--appimage` |
| `~/.local/bin/wispr-flow` | wrapper, with `--appimage` |
| `~/.local/share/applications/wispr-flow.desktop` | desktop entry claiming the `wispr-flow:` URL scheme, with `--appimage` |

Pass `--section left\|center\|right` to place the widget, `--languages en,cs`
to override the offered languages, `--no-icon` to leave the bar icon out, and
`--no-restart` to skip the shell restart. Re-running is safe: an existing bar
entry is updated in place.

## Relationship to voxtype

Omarchy's own dictation is [voxtype](https://github.com/voxtype/voxtype): a
binary, a `Dictation` entry in the `omarchy.indicators` widget, and the
`SUPER+CTRL+X` / `F9` bindings in
`$OMARCHY_PATH/default/hypr/bindings/voxtype.lua`. This plugin is an
alternative to that, not a companion — running both means two dictation
front-ends competing for the same microphone and the same paste target.

To use Wispr instead:

```bash
# 1. Stop the daemon and keep it stopped.
systemctl --user disable --now voxtype.service

# 2. Drop voxtype's Dictation entry from the indicators widget, in shell.json,
#    and put this widget in its place:
#      { "id": "omarchy.indicators",
#        "items": ["ScreenRecording", "Reminder", "NightLight", "Dnd", "StayAwake"] },
#      { "id": "wispr.flow", "languages": "en,cs" }

# 3. Take over voxtype's bindings, in ~/.config/hypr/bindings.lua. Omarchy only
#    defines them while the voxtype binary is present, which it still is after
#    the daemon stops, so they have to be unbound first.
#      hl.unbind("SUPER + CTRL + X")
#      hl.unbind("F9")
#      o.bind("SUPER + CTRL + X", "Toggle dictation",
#        "~/.config/omarchy/plugins/wispr.flow/wispr-state --toggle")
#      o.bind("SUPER + CTRL + M", "Wispr Flow", "omarchy-shell wispr.flow toggle")
```

F9 push-to-talk has no replacement here and does not need one: Wispr reads its
own push-to-talk key at the evdev level, whatever the compositor is doing.

Sitting where the Dictation indicator was, this widget is the richer form of
the same thing: the mic still goes active while recording, but it is clickable
and carries the language and the Hub behind it.

`showIcon: false` is for the other arrangement — keeping voxtype's indicator,
or wanting no permanent icon at all. With it off the widget keeps a zero-width
slot and only the `SUPER+CTRL+M` binding opens the panel.

## The widget

Left click opens the panel; right click toggles dictation without opening it;
middle click raises the Hub. `j`/`k` walk the rows, Enter activates, Escape
closes.

The panel leads with the language list, because that is the one setting that
exists nowhere else on the desktop. Start/stop sits below it as a convenience —
right-clicking the icon is quicker and does not have to open anything. State
lives in the bar icon and its tooltip (`Wispr Flow · Idle · Czech`) rather than
in a banner repeating it.

**Choosing a microphone is not this panel's job.** Wispr's device setting is an
override; while it sits on the app's `Auto-detect (Default)` entry Wispr simply
records from whatever PipeWire is capturing, which `omarchy.audio` already
controls alongside input volume and mute. Offering a second picker here would
duplicate a working control and invite the two to disagree. The panel shows a
`Release <device>` row only when the override is actually in force, so the way
back to the system default is one click and the section is invisible the rest
of the time.

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
- **The device names come from the log, not from `config.json`.** The ranked
  list in the config remembers microphones that are unplugged, and the app
  refuses to switch to those; the `audioDevices` array it logs on every
  settings sync holds only what is actually connected.
- **A new bar widget needs a full shell restart.** `omarchy-shell shell
  rescanPlugins` reloads code for plugins already in the registry; a widget the
  shell has never seen leaves its slot empty until `omarchy restart shell`.
- **A language switch lives in the app's memory, not in `config.json`.** The
  route sets the pref the transcription request builders read; Wispr flushes
  that file on its own schedule and often serializes a snapshot taken before
  the change, so reading the language back from disk gives a stale answer —
  sometimes for minutes. `wispr-state --set-language` therefore records the
  choice in `$XDG_RUNTIME_DIR` and prefers its own record over the config file
  for as long as the app has been running since it was written. A restart makes
  the config authoritative again, and the switch is lost with it.
- **The Hub's own language picker will not reflect a switch made here**, since
  the renderer's store is not notified.

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
