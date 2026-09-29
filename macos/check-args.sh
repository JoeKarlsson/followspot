#!/usr/bin/env bash
# Check that the app starts whisper-server with the same flags as the
# launcher. The app re-implements the launcher's arguments in Swift
# (Server.swift), so a change to ./followspot could otherwise leave it behind.
#
#   macos/check-args.sh <app server.args> [launcher args, e.g. -m model.bin -- -ac 512]
#
# Runs ./followspot with a stand-in whisper-server that prints its arguments,
# then compares both lists. Port, web root, and model/VAD directories are
# expected to differ; file names, thread count, and every flag must match.
set -euo pipefail

APP_ARGS="${1:?usage: macos/check-args.sh <app server.args> [launcher args]}"
shift
cd "$(dirname "$0")/.."

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$FAKE/whisper-server"
chmod +x "$FAKE/whisper-server"
# The launcher links public/current.md only when given a script; it isn't.
PATH="$FAKE:$PATH" ./followspot --no-open "$@" > "$FAKE/launcher.out"
sed -n '/^-m$/,$p' "$FAKE/launcher.out" > "$FAKE/launcher.args"

# Replace the values that legitimately differ with placeholders.
normalize() {
  awk '
    prev == "-m" || prev == "-vm" { n = split($0, parts, "/"); print "<dir>/" parts[n]; prev = ""; next }
    prev == "--port" { print "<port>"; prev = ""; next }
    prev == "--public" { print "<public>"; prev = ""; next }
    { print; prev = $0 }
  ' "$1"
}

if diff <(normalize "$FAKE/launcher.args") <(normalize "$APP_ARGS"); then
  echo "App and launcher pass the same whisper-server flags:"
  normalize "$APP_ARGS" | paste -sd ' ' -
else
  echo "The app's whisper-server flags differ from ./followspot's (< launcher, > app)." >&2
  echo "Update macos/Sources/Followspot/Server.swift to match." >&2
  exit 1
fi
