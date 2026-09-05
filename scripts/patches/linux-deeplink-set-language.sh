#!/usr/bin/env bash
#===============================================================================
# linux-deeplink-set-language.sh -- add a `wispr-flow://set-language` deep-link
# route to the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Wispr ships deep links for dictation (start/stop-hands-free), the microphone
# (switch-mic) and the Hub (open), but none for the dictation language -- that
# lives only in the Hub UI. A desktop shell that drives Wispr from a bar widget
# needs it, so this adds the missing route rather than asking the user to open
# a window for it.
#
# Unlike the other Linux patches this ADDS BEHAVIOUR instead of widening a
# platform gate. It is deliberately the smallest addition that works, and it
# introduces no new webpack imports: every symbol it uses is already bound in
# the dispatcher's own module and is read back out of the match.
#
# HOW THE LANGUAGE IS ACTUALLY USED
# ---------------------------------
# The transcription request builders read the pref directly at request time:
#
#   language: <state>.RA.prefs.user.selectedLanguages ?? []
#   1 === <state>.RA.prefs?.user.selectedLanguages?.length &&
#       (lang = <state>.RA.prefs?.user.selectedLanguages?.[0])
#
# So setting `selectedLanguages` to a single-entry array pins the next
# dictation to that language. That is exactly what the Hub's picker ends up
# doing; we just reach the same pref from a URL.
#
# THE PATCH
# ---------
# One extra branch in the deep-link dispatcher's if/else chain, inserted
# immediately before the switch-mic branch it is modelled on:
#
#   else if(e.startsWith("wispr-flow://set-language")){ ...set the pref... }
#
# `lang` takes one code to pin a language, or a comma-separated list to hand
# the choice back to Wispr's own detection across those languages -- which is
# what a multi-entry selectedLanguages means to the request builders.
#   else if(e.startsWith("wispr-flow://switch-mic"))$(e);
#
# ANCHORING
# ---------
# The anchor is the developer string literal "wispr-flow://switch-mic" and the
# `startsWith` call shape around it, which occur once. Three minified names are
# needed and all three are captured from the surrounding module rather than
# hardcoded, because they churn every release:
#   * the URL parameter name (`e` today) -- from the branch itself
#   * the shared-state accessor (`I` today) -- from `<X>.RA.sharedSettings
#     .audioDevices` in the switch-mic handler
#   * the logger factory (`n` today) -- from `<Y>().warn(` in the same handler
# If any of them cannot be found the patch bails rather than emitting a branch
# that would throw at runtime.
#
# Usage: linux-deeplink-set-language.sh [path-to-.webpack/main/index.js]
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$BUNDLE/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

# --- Idempotency guard --------------------------------------------------------
LINUX_MARKER="WISPR_LINUX_SET_LANGUAGE"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (every minified name DERIVED, not hardcoded) -----------------------
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# The switch-mic branch of the dispatcher chain. `url` is the dispatcher's
# parameter, which the new branch reuses.
branch = re.compile(
    r'else if\((?P<url>[\w$]+)\.startsWith\("wispr-flow://switch-mic"\)\)'
)
matches = list(branch.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 switch-mic dispatcher branch, "
        f"found {len(matches)}. The bundle layout may have changed; "
        f"inspect manually around `wispr-flow://switch-mic`."
    )
url = matches[0].group('url')

# The shared-state accessor, from the switch-mic handler's device lookup. The
# search is confined to that handler: `.RA` is imported under a different local
# name in every module, and the first match in the whole bundle belongs to some
# other one, which would not be in scope where we splice the new branch in.
handler_at = data.find('Switch mic deeplink received with mic_name')
if handler_at < 0:
    sys.exit("ERROR: could not locate the switch-mic handler.")
handler = data[handler_at:handler_at + 2000]
state_m = re.search(r'(?P<state>[\w$]+)\.RA\.sharedSettings\.audioDevices', handler)
if not state_m:
    sys.exit("ERROR: could not derive the shared-state accessor "
             "(`<X>.RA.sharedSettings.audioDevices` not found in the handler).")
state = state_m.group('state')

# The logger factory, from the switch-mic handler's own warning.
log_m = re.search(
    r'(?P<log>[\w$]+)\(\)\.warn\("Switch mic deeplink received without', data)
if not log_m:
    sys.exit("ERROR: could not derive the logger factory "
             "(the switch-mic warning was not found).")
log = log_m.group('log')

# The new branch. Written defensively: a missing pref tree or a malformed URL
# logs and returns instead of throwing out of the dispatcher, which would take
# every later route down with it.
new_branch = (
    'else if(' + url + '.startsWith("wispr-flow://set-language")){'
    '/*' + marker + '*/'
    'try{'
    'const l=(new URL(' + url + ').searchParams.get("lang")||"")'
    '.split(",").map(s=>s.trim()).filter(s=>s.length>0);'
    'if(!l.length)' + log + '().warn("Set language deeplink received without lang parameter");'
    'else if(!' + state + '.RA.prefs?.user)'
    + log + '().warn("Set language deeplink received before prefs were loaded");'
    'else{' + state + '.RA.prefs.user.selectedLanguages=l;'
    + log + '().info(`Set language deeplink received: ${l.join(",")}`)}'
    '}catch(err){'
    + log + '().error("Error handling set language deeplink:",'
    '{customAttributes:{error:err}})}}'
)

data, n = branch.subn(lambda m: new_branch + m.group(0), data, count=1)
if n != 1:
    sys.exit(f"ERROR: substitution applied {n} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: added set-language route (url={url!r}, state={state!r}, "
      f"logger={log!r}).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if ! grep -q 'wispr-flow://set-language' "$BUNDLE"; then
	echo "ERROR: route literal missing after patch. Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi

echo "OK: set-language deep-link route added in $BUNDLE"
echo
echo "  wispr-flow://set-language?lang=cs      pins the next dictation to Czech"
echo "  wispr-flow://set-language?lang=en,cs   restores detection across both"
