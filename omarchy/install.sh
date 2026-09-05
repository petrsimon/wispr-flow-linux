#!/usr/bin/env bash
#===============================================================================
# install.sh -- install the Omarchy integration for Wispr Flow.
#
# Installs the bar plugin, registers it in the bar layout, and optionally
# installs an AppImage built by ../build.sh. Everything it touches is under
# $HOME; nothing here needs root.
#
# Usage:
#   omarchy/install.sh [--appimage <path>] [--section left|center|right]
#                      [--languages en,cs] [--no-restart]
#===============================================================================
set -euo pipefail

PLUGIN_ID='wispr.flow'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$SCRIPT_DIR/plugins/$PLUGIN_ID"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
APP_CONFIG="$HOME/.config/Wispr Flow/config.json"
APP_DEST="$HOME/.local/opt/wispr-flow/wispr-flow.AppImage"

appimage=''
section='right'
languages=''
restart='yes'

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--appimage)  [[ -n ${2:-} ]] || die '--appimage needs a path'; appimage="$2"; shift 2 ;;
		--section)   [[ -n ${2:-} ]] || die '--section needs a value'; section="$2"; shift 2 ;;
		--languages) [[ -n ${2:-} ]] || die '--languages needs a value'; languages="$2"; shift 2 ;;
		--no-restart) restart='no'; shift ;;
		-h|--help)   grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)           die "unknown argument: $1" ;;
	esac
done

command -v jq >/dev/null || die 'jq is required'
command -v omarchy >/dev/null || die 'this does not look like an Omarchy system (no omarchy command)'
[[ -d $PLUGIN_SRC ]] || die "plugin sources not found: $PLUGIN_SRC"
case "$section" in left|center|right) ;; *) die "invalid --section: $section" ;; esac

# ---------------------------------------------------------------- application
if [[ -n $appimage ]]; then
	say 'Install the application'
	[[ -f $appimage ]] || die "AppImage not found: $appimage"
	mkdir -p "$(dirname "$APP_DEST")" "$HOME/.local/bin" \
		"$HOME/.local/share/applications"
	install -m 755 "$appimage" "$APP_DEST"
	info "AppImage -> $APP_DEST"

	cat > "$HOME/.local/bin/wispr-flow" <<-WRAPPER
		#!/bin/sh
		exec "\$HOME/.local/opt/wispr-flow/wispr-flow.AppImage" "\$@"
	WRAPPER
	chmod 755 "$HOME/.local/bin/wispr-flow"
	info "wrapper -> ~/.local/bin/wispr-flow"

	# The desktop entry claims the URL scheme, so xdg-open routes deep links
	# too -- not only our own direct invocations.
	cat > "$HOME/.local/share/applications/wispr-flow.desktop" <<-DESKTOP
		[Desktop Entry]
		Type=Application
		Name=Wispr Flow
		Comment=Voice dictation
		Exec=wispr-flow %U
		Icon=ai.wisprflow.WisprFlow
		Terminal=false
		Categories=Utility;AudioVideo;
		StartupWMClass=wispr-flow
		MimeType=x-scheme-handler/wispr-flow;
	DESKTOP
	update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
	info 'desktop entry installed'

	case ":$PATH:" in
		*":$HOME/.local/bin:"*) ;;
		*) info 'WARNING: ~/.local/bin is not on PATH' ;;
	esac
	if command -v wispr-flow >/dev/null && \
		[[ "$(command -v wispr-flow)" != "$HOME/.local/bin/wispr-flow" ]]; then
		info "WARNING: $(command -v wispr-flow) shadows the wrapper;"
		info '         remove the packaged build first (e.g. pacman -Rns wispr-flow-appimage)'
	fi
fi

# --------------------------------------------------------------------- plugin
say 'Install the bar plugin'
mkdir -p "$PLUGIN_DEST"
cp -a "$PLUGIN_SRC/." "$PLUGIN_DEST/"
chmod 755 "$PLUGIN_DEST/wispr-state"
info "$PLUGIN_ID -> $PLUGIN_DEST"

# Seed the offered languages from the app's own selection. Pinning a language
# rewrites that list, so the original set has to be captured now or it is lost.
if [[ -z $languages && -r $APP_CONFIG ]]; then
	languages=$(jq -r '(.prefs.user.selectedLanguages // []) | join(",")' \
		"$APP_CONFIG" 2>/dev/null || true)
fi
[[ -n $languages ]] || languages='en'
info "languages offered: $languages"

# ----------------------------------------------------------------- bar layout
say 'Register the widget in the bar'
if [[ ! -f $SHELL_JSON ]]; then
	mkdir -p "$(dirname "$SHELL_JSON")"
	cp /usr/share/omarchy/config/omarchy/shell.json "$SHELL_JSON"
	info 'started from the shipped shell.json'
fi

backup="$SHELL_JSON.bak.$(date +%s)"
cp "$SHELL_JSON" "$backup"

# Idempotent: update the entry in place if it is already there, otherwise
# append it to the chosen section. Any other section keeps whatever it has.
updated=$(jq \
	--arg id "$PLUGIN_ID" \
	--arg section "$section" \
	--arg languages "$languages" \
	'
	def entry: {id: $id, languages: $languages};
	.bar.layout[$section] = (
		(.bar.layout[$section] // []) as $list
		| if ($list | map(.id == $id) | any)
			then ($list | map(if .id == $id then . + {languages: $languages} else . end))
			else ($list + [entry])
		  end
	)
	' "$SHELL_JSON")

printf '%s\n' "$updated" > "$SHELL_JSON"
info "bar.layout.$section carries $PLUGIN_ID (backup: $(basename "$backup"))"

# ---------------------------------------------------------------------- reload
# shell.json and plugin code hot-reload, but a bar widget the shell has never
# seen is only picked up on a full restart -- rescanPlugins reloads code for
# plugins already in the registry and leaves the new slot empty.
if [[ $restart == 'yes' ]]; then
	say 'Restart the shell'
	omarchy restart shell
	info 'done'
else
	say 'Skipped the shell restart'
	info 'run `omarchy restart shell` before the widget appears'
fi

cat <<'NEXT'

Optional: hide Wispr's own status bubble, which Hyprland places badly and
which cannot be clicked on Wayland anyway. Add to ~/.config/hypr/hyprland.lua:

  o.window({ class = "^wispr-flow$", initial_title = "^Flow Status Indicator$" }, {
    workspace = "special:wispr silent",
    float = true,
    no_focus = true,
    no_initial_focus = true,
    no_anim = true,
  })

Optional: start Wispr with the session, in ~/.config/hypr/autostart.lua:

  o.launch_on_start("wispr-flow")
NEXT
