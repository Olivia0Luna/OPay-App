#!/usr/bin/env bash
# Installs the Flutter SDK (not included in Netlify's build image) from the
# official release archive and builds the web target.
set -euo pipefail

FLUTTER_DIR="$HOME/flutter"
RELEASES_BASE="https://storage.googleapis.com/flutter_infra_release/releases"

if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  archive=$(curl -fsSL "$RELEASES_BASE/releases_linux.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
h = d["current_release"]["stable"]
print(next(r["archive"] for r in d["releases"] if r["hash"] == h))
')
  echo "Downloading Flutter: $archive"
  curl -fsSL "$RELEASES_BASE/$archive" | tar -xJ -C "$HOME"
fi

# Flutter reads its version with `git -c <key>=<value> ...` and
# `git tag --points-at <rev>`. Some build environments only allow a small set of
# read-only git commands, so this shim drops the `-c` options, answers
# `tag --points-at` via `show-ref`, and forwards the rest to the git on PATH.
SHIM_DIR="$HOME/.flutter-git-shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH="${PATH#"$(dirname "$0")":}"
if [ "${args[0]:-}" = "tag" ] && [ "${args[1]:-}" = "--points-at" ]; then
  sha=$(git rev-parse "${args[2]:-HEAD}^{commit}") || exit 1
  git show-ref --tags -d | awk -v sha="$sha" '$1 == sha {
    sub("^refs/tags/", "", $2); sub("\\^\\{\\}$", "", $2); print $2 }' | sort -u
  exit 0
fi
exec git "${args[@]}"
SHIM
chmod +x "$SHIM_DIR/git"

export PATH="$SHIM_DIR:$FLUTTER_DIR/bin:$PATH"

# Drop any version cached from a run where git lookups failed.
rm -f "$FLUTTER_DIR/bin/cache/flutter.version.json"

# `.env` is gitignored, so on Netlify it is generated from the project's
# environment variables (Project configuration > Environment variables).
# A local `.env` is left untouched.
if [ ! -f .env ]; then
  : > .env
  for key in AUTH_BASE_URL API_BASE_URL RECHARGE_ENDPOINT USER_ID API_TIMEOUT; do
    if [ -n "${!key:-}" ]; then
      printf '%s=%s\n' "$key" "${!key}" >> .env
    fi
  done
  if [ -z "${AUTH_BASE_URL:-}" ]; then
    echo "WARNING: AUTH_BASE_URL is not set; the app will show 'Missing environment values: AUTH_BASE_URL'." >&2
  fi
fi

flutter config --no-analytics
flutter --version
flutter pub get
flutter build web --release
