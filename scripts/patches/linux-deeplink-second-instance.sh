#!/usr/bin/env bash
#===============================================================================
# linux-deeplink-second-instance.sh -- fix warm-start `wispr-flow:` deep-link
# handling on Linux in the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# linux-deeplink.sh fixes the COLD-START path (app not running: the OS appends
# the URL to process.argv). This patch fixes the other half, the WARM-START
# path: when the app is ALREADY running, the OS launches a second instance and
# Electron hands its argv to the first instance via the `second-instance`
# event. The bundle's handler scans that argv for the URL -- but the scan is
# gated to win32:
#
#   app.on("second-instance",(t,r)=>{
#     if(r.includes("--quit-app")){...}
#     const i=r.find(e=>e.startsWith("--squirrel-"));
#     if(i){...}
#     else{
#       if(<winflag>){                                     // <-- win32 ONLY
#         const e=<P>(r.find(e=>e.startsWith("wispr-flow:")
#                            ||e.startsWith("wispr-flow/")));
#         if(e)return void <dispatch>(e)
#       }
#       ...  "User tried to open the app a second time ..."
#     }
#   })
#
# macOS does not need the scan (it gets `open-url`), but Linux does: it
# delivers protocol URLs through argv exactly like Windows. So on Linux a deep
# link aimed at a RUNNING app silently loses its payload and falls through to
# the "focus the window" branch.
#
# Confirmed on Wispr Flow 1.6.7 (packaged AppImage, bundle byte-level):
#   ...`Ignoring second-instance from Squirrel event: ${i}`);else{if(b.H8){
#      const e=P(r.find(e=>e.startsWith("wispr-flow:")
#      ||e.startsWith("wispr-flow/")));if(e)return void U(e)}
#      n().info("User tried to open the app a second time while it was
#      already running")...
# and reproduced at runtime: `wispr-flow wispr-flow://open` against a running
# app logs only "User tried to open the app a second time while it was already
# running" -- the dispatcher is never reached.
#
# WHAT THIS UNLOCKS
# -----------------
# The dispatcher already routes several URLs that are useful to a desktop
# shell -- `wispr-flow://start-hands-free`, `wispr-flow://stop-hands-free`,
# `wispr-flow://switch-mic`, `wispr-flow://open`. Since the app is essentially
# always running, they are unreachable on Linux without this patch. With it, a
# panel button or keybinding can drive dictation by firing a URL instead of
# synthesizing a global shortcut through uinput.
#
# THE PATCH (surgical, one site)
# ------------------------------
# Widen the win32 guard at THAT site only, so Linux is included:
#
#   else{if(b.H8){const e=P(r.find(...
#     becomes
#   else{if(b.H8||"linux"===process.platform){/*MARKER*/const e=P(r.find(...
#
# The anchor is the developer literal `"second-instance"` followed, within a
# bounded window, by the guard and the argv-scan shape. The win32 accessor is
# read back out of the match rather than hardcoded, because the minified
# `obj.prop` churns every release. This cannot regress Windows (the flag still
# wins) or macOS (neither branch is true; open-url is untouched), and it cannot
# collide with the cold-start site patched by linux-deeplink.sh: that one scans
# `process.argv.find` (a dotted collection, excluded here) and sits BEFORE the
# `"second-instance"` literal the anchor keys on.
#
# Usage: linux-deeplink-second-instance.sh [path-to-.webpack/main/index.js]
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	# default to the in-repo extracted bundle
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$BUNDLE/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

# --- Idempotency guard --------------------------------------------------------
# Deliberately not WISPR_LINUX_DEEPLINK_WARM: verify-patches.sh greps for
# fixed strings, so a marker that has another marker as a prefix would keep
# reporting that other one present after it had been lost.
LINUX_MARKER="WISPR_LINUX_WARM_DEEPLINK"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (win32 flag accessor DERIVED, not hardcoded) -----------------------
# The minified win32 accessor (`b.H8` today) churns between releases, so we read
# it back out of the match. The STABLE anchors are the `"second-instance"` event
# name and the `wispr-flow:` scheme literal -- both survive minification.
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: the second-instance handler, then its win32-gated argv scan for the
# wispr-flow: URL. Capture the win32 flag accessor (obj.prop) so we widen THIS
# guard only, never another site that shares the flag.
#
#   "second-instance" ... if(<winflag>){const <v>=<P>(<r>.find(<a>=>
#       <a>.startsWith("wispr-flow:")
#
# The bounded [\s\S]{0,400}? gap keeps the match inside the handler: the
# --quit-app and --squirrel- branches sit between the event name and the guard.
# The (?<![\w$.]) before the collection excludes a dotted receiver, so the
# cold-start `process.argv.find` site can never be matched here.
anchor = re.compile(
    r'"second-instance"[\s\S]{0,400}?'                 # the handler
    r'if\((?P<flag>[\w$]+(?:\.[\w$]+)?)\)\{'           # if(<winflag>){
    r'const\s+[\w$]+='                                 #   const <v>=
    r'[\w$]+\('                                        #   <P>(
    r'(?<![\w$.])(?P<coll>[\w$]+)\.find\('             #   <r>.find(
    r'(?P<a>[\w$]+)=>'                                 #     <a>=>
    r'(?P=a)\.startsWith\("wispr-flow:"\)'             #     ...("wispr-flow:")
)
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 second-instance deep-link guard, "
        f"found {len(matches)}. The bundle layout may have changed; "
        f"inspect manually around `second-instance`."
    )

flag = matches[0].group('flag')

# Widen the guard: insert the linux clause and the marker right after the `{`
# that opens the win32-gated block. Build with concatenation so no `$N`/`$&`
# sequence can be eaten by a replacement DSL (we use a lambda anyway).
def widen(m):
    head = m.group(0)
    guard = 'if(' + flag + '){'
    at = head.index(guard)
    return (
        head[:at]
        + 'if(' + flag + '||"linux"===process.platform)'
        + '{/*' + marker + '*/'
        + head[at + len(guard):]
    )

data, n = anchor.subn(widen, data, count=1)
if n != 1:
    sys.exit(f"ERROR: substitution applied {n} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: derived win32 flag={flag!r}; second-instance argv guard "
      f"widened to include linux (1 site).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# The widened guard must sit immediately before the argv scan (proves we hit the
# second-instance site, not some unrelated marker placement).
if ! grep -q '"linux"===process.platform){/\*'"$LINUX_MARKER"'\*/const' "$BUNDLE"; then
	echo "ERROR: marker not adjacent to the argv guard. Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Syntax-check: catch a replacement that serializes but doesn't parse before it
# ever reaches asar.
if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi

echo "OK: Linux warm-start deep-link guard widened in $BUNDLE"
echo
echo "Patched second-instance handler now does (conceptually):"
echo "  app.on('second-instance', (event, argv) => {"
echo "    if (isWin32 || process.platform === 'linux') {"
echo "      const url = argv.find(a => a.startsWith('wispr-flow:'));"
echo "      if (url) return dispatchDeepLink(url);"
echo "    }"
echo "    focusHubWindow();"
echo "  });"
echo
echo "So a 'wispr-flow:' link aimed at an ALREADY RUNNING app now delivers the"
echo "URL on Linux (cold start is handled by linux-deeplink.sh; macOS still"
echo "uses open-url)."
