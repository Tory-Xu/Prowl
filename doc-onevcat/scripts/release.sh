#!/usr/bin/env bash
# Prowl public release script.
# Usage: ./doc-onevcat/scripts/release.sh [VERSION]
#
# Environment variables:
#   APPLE_SIGNING_IDENTITY          Developer ID identity (auto-detected if unset)
#   APPLE_TEAM_ID                   Apple Team ID (inferred from identity if unset)
#   APPLE_NOTARY_KEYCHAIN_PROFILE   Keychain profile for notarytool (default: supacode-notary)
#   SPARKLE_PRIVATE_KEY_FILE        Path to EdDSA private key file (default: ~/.prowl-sparkle-private-key)
#   PROWL_SITE_DIR                  Path to Prowl-Site repo (default: ../Prowl-Site)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────

origin_repo_from_remote() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -z "$remote_url" ]] && return 1
  local repo
  repo="$(echo "$remote_url" | sed -E 's#^(git@github.com:|ssh://git@github.com/|https://github.com/)##; s#\.git$##')"
  [[ "$repo" == */* ]] && echo "$repo" && return 0
  return 1
}

default_signing_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}'
}

team_id_from_identity() {
  local identity="$1"
  if [[ "$identity" =~ \(([A-Z0-9]{10})\)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

signing_identity_sha() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "$1" | head -1 | awk '{print $2}'
}

log() { echo "[release] $*"; }
die() { echo "error: $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────

log "preflight checks..."

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
for cmd in gh jq codesign xcrun create-dmg; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not found"
done
[[ -x "$PROJECT_DIR/bins/generate_appcast" ]] || die "bins/generate_appcast not found"

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is not clean — commit or stash changes first"
fi

REPO="${GH_REPO:-$(origin_repo_from_remote || true)}"
[[ -z "$REPO" ]] && REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ -z "$REPO" ]] && die "cannot determine GitHub repository"

KEYCHAIN_PROFILE="${APPLE_NOTARY_KEYCHAIN_PROFILE:-supacode-notary}"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-$(default_signing_identity || true)}"
[[ -z "$SIGNING_IDENTITY" ]] && die "no Developer ID Application identity found — set APPLE_SIGNING_IDENTITY"

TEAM_ID="${APPLE_TEAM_ID:-$(team_id_from_identity "$SIGNING_IDENTITY" || true)}"
[[ -z "$TEAM_ID" ]] && die "cannot determine Apple Team ID — set APPLE_TEAM_ID"

IDENTITY_SHA="$(signing_identity_sha "$SIGNING_IDENTITY")"
[[ -z "$IDENTITY_SHA" ]] && die "cannot find signing identity SHA for: $SIGNING_IDENTITY"

SPARKLE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/.prowl-sparkle-private-key}"
[[ -f "$SPARKLE_KEY_FILE" ]] || die "Sparkle private key not found: $SPARKLE_KEY_FILE"

PROWL_SITE="${PROWL_SITE_DIR:-$PROJECT_DIR/../Prowl-Site}"

log "repository: $REPO"
log "signing identity: $SIGNING_IDENTITY"
log "team ID: $TEAM_ID"

# ── Version ──────────────────────────────────────────────────────────────────

if [[ -n "${1:-}" ]]; then
  VERSION="$1"
  if ! echo "$VERSION" | grep -qE '^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?$'; then
    die "VERSION must be in YYYY.M.DD or YYYY.M.DD.N format"
  fi
else
  VERSION="$(date +%Y.%-m.%-d)"
  suffix=1
  while git rev-parse "v$VERSION" >/dev/null 2>&1; do
    suffix=$((suffix + 1))
    VERSION="$(date +%Y.%-m.%-d).$suffix"
  done
fi

TAG="v$VERSION"
git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists"

BUILD="$(date +%Y%m%d)"
CURRENT_BUILD="$(/usr/bin/awk -F' = ' '/CURRENT_PROJECT_VERSION = [0-9]+;/{gsub(/;/,""); print $2; exit}' "$PROJECT_DIR/supacode.xcodeproj/project.pbxproj")"
if [[ "$CURRENT_BUILD" -ge "$BUILD" ]] 2>/dev/null; then
  BUILD="$((CURRENT_BUILD + 1))"
fi

log "version: $VERSION (build $BUILD), tag: $TAG"

# ── Bump version ─────────────────────────────────────────────────────────────

log "bumping version in project..."
make bump-version VERSION="$VERSION" BUILD="$BUILD"

# ── Changelog ────────────────────────────────────────────────────────────────

log "generating release notes..."
NOTES_FILE="build/release-notes.md"
mkdir -p build
PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"

generate_llm_notes() {
  local range="$1"
  local raw_context
  raw_context="$(mktemp)"

  # Gather commit messages
  {
    echo "=== Commits ($range) ==="
    git log --pretty=format:'%s' "$range"
    echo ""
  } > "$raw_context"

  # Gather merged PR details (title + body)
  {
    echo ""
    echo "=== Merged Pull Requests ==="
    local pr_numbers
    pr_numbers="$(git log --pretty=format:'%s' "$range" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)"
    for pr in $pr_numbers; do
      local pr_json
      pr_json="$(gh pr view "$pr" --repo "$REPO" --json title,body 2>/dev/null || true)"
      if [[ -n "$pr_json" ]]; then
        echo "--- PR #$pr ---"
        echo "$pr_json" | jq -r '"Title: \(.title)\nBody:\n\(.body)"'
        echo ""
      fi
    done
  } >> "$raw_context"

  # Gather diff stats
  {
    echo ""
    echo "=== Diff Stats ==="
    git diff --stat "$range"
  } >> "$raw_context"

  local prompt
  prompt="$(cat <<'PROMPT'
You are writing release notes for **Prowl**, a macOS app that runs multiple
coding agents in parallel, each in its own terminal tab.

Given the raw context below (commits, PR descriptions, diff stats), produce a
concise, user-facing changelog in Markdown.

## Rules

1. **Audience**: Prowl end-users (developers). They care about what changed in
   their day-to-day experience, not internal code structure.
2. **Include only user-visible changes**: new features, behavior changes, UX
   improvements, notable bug fixes. Skip pure refactors, test-only changes,
   CI tweaks, dependency bumps, and code-style changes unless they affect
   the user.
3. **Teach naturally**: when a change introduces a new shortcut, workflow, or
   setting, briefly explain how to use it (e.g. "Press ⌥⌘↩ to toggle
   Canvas view").
4. **Tone**: clear, professional, friendly. No marketing fluff, no emoji, no
   exclamation marks, no "we're excited".
5. **Format**:
   - Start with a one-line summary sentence of the release theme if there is a
     clear one; otherwise jump straight to the list.
   - Use a flat bullet list (`-`). Group related items under a single bullet.
   - Each bullet should be one or two sentences maximum.
   - If a change is a bug fix, start the bullet with "Fixed: …".
   - End with nothing — no sign-off, no footer.
6. **Length**: aim for 3-8 bullets. Merge trivial items. Omit if truly nothing
   is user-facing (output a single bullet: "- Internal improvements and
   stability fixes.").
7. **Language**: English only.
8. Output **only** the Markdown content. No preamble, no code fences.
PROMPT
)"

  local notes
  notes="$(claude -p \
    --model sonnet \
    --allowedTools "" \
    --output-format text \
    "$prompt

--- RAW CONTEXT ---
$(cat "$raw_context")
--- END ---" 2>/dev/null || true)"
  rm -f "$raw_context"

  if [[ -n "$notes" ]] && [[ "$(echo "$notes" | wc -l)" -ge 2 ]]; then
    echo "$notes"
    return 0
  fi
  return 1
}

generate_fallback_notes() {
  local range="$1"
  if [[ -n "$range" ]]; then
    gh api "repos/$REPO/releases/generate-notes" \
      -f tag_name="$TAG" -f previous_tag_name="$PREV_TAG" \
      --jq '.body' 2>/dev/null || \
    git log --pretty=format:'- %s' "$range"
  else
    git log --pretty=format:'- %s' -20
  fi
}

if [[ -s "$NOTES_FILE" ]]; then
  log "using existing release notes from $NOTES_FILE"
elif [[ -n "$PREV_TAG" ]]; then
  RANGE="$PREV_TAG..$TAG"
  if command -v claude >/dev/null 2>&1; then
    log "generating release notes with LLM..."
    if generate_llm_notes "$RANGE" > "$NOTES_FILE"; then
      log "release notes generated by LLM"
    else
      log "LLM generation failed, falling back to GitHub auto-notes..."
      generate_fallback_notes "$RANGE" > "$NOTES_FILE"
    fi
  else
    generate_fallback_notes "$RANGE" > "$NOTES_FILE"
  fi
else
  generate_fallback_notes "" > "$NOTES_FILE"
fi
log "release notes written to $NOTES_FILE"

# ── Archive ──────────────────────────────────────────────────────────────────

log "archiving Release build..."
make archive APPLE_TEAM_ID="$TEAM_ID" DEVELOPER_ID_IDENTITY_SHA="$IDENTITY_SHA"

# ── Export ───────────────────────────────────────────────────────────────────

log "generating ExportOptions.plist..."
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$SIGNING_IDENTITY</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

log "exporting archive..."
make export-archive

# ── Locate exported app ─────────────────────────────────────────────────────

APP_PATH="$(find build/export -name "*.app" -maxdepth 3 -print -quit)"
[[ -d "$APP_PATH" ]] || die "exported app not found in build/export"
APP_NAME="$(basename "$APP_PATH")"
log "exported app: $APP_PATH"

# ── Re-sign Sparkle & Sentry frameworks ─────────────────────────────────────

log "re-signing embedded frameworks..."
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"

if [[ -d "$SPARKLE" ]]; then
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/XPCServices/Installer.xpc"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements -v "$SPARKLE/XPCServices/Downloader.xpc"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/Updater.app"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/Autoupdate"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/Sparkle"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$APP_PATH/Contents/Frameworks/Sparkle.framework"
fi

SENTRY_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sentry.framework"
if [[ -d "$SENTRY_FRAMEWORK" ]]; then
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SENTRY_FRAMEWORK/Versions/A/Sentry"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SENTRY_FRAMEWORK"
fi

# ── Re-sign app ─────────────────────────────────────────────────────────────

log "re-signing app..."
codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements,requirements,flags -v "$APP_PATH"
codesign -vvv --deep --strict "$APP_PATH"
log "signature verified"

# ── DMG ──────────────────────────────────────────────────────────────────────

log "building DMG..."
DMG_PATH="build/Prowl.dmg"
mise exec -- create-dmg "$APP_PATH" build/ \
  --overwrite \
  --dmg-title="Prowl" \
  --identity="$IDENTITY_SHA"

DMG_OUTPUT="$(find build -name "*.dmg" -maxdepth 1 -newer build/ExportOptions.plist | head -1)"
if [[ "$DMG_OUTPUT" != "$DMG_PATH" ]] && [[ -n "$DMG_OUTPUT" ]]; then
  mv "$DMG_OUTPUT" "$DMG_PATH"
fi
[[ -f "$DMG_PATH" ]] || die "DMG not found at $DMG_PATH"

# ── Notarize ─────────────────────────────────────────────────────────────────

log "notarizing DMG..."
for attempt in 1 2 3; do
  if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
    break
  fi
  if [[ $attempt -lt 3 ]]; then
    log "notarization attempt $attempt failed, retrying in 30s..."
    sleep 30
  else
    die "notarization failed after 3 attempts"
  fi
done

log "stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler staple "$APP_PATH"

# ── Package zip for Sparkle ──────────────────────────────────────────────────

ZIP_PATH="build/Prowl.app.zip"
log "packaging $ZIP_PATH for Sparkle..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# ── Appcast ──────────────────────────────────────────────────────────────────

log "generating appcast..."
STAGING="$(mktemp -d)"
ARCHIVE_BASE="$(basename "$ZIP_PATH" .zip)"
cp "$ZIP_PATH" "$STAGING/"
cp "$NOTES_FILE" "$STAGING/$ARCHIVE_BASE.md"

# Fetch existing appcast for history
curl -fsSL "https://prowl.onev.cat/appcast.xml" -o "$STAGING/appcast.xml" 2>/dev/null || true

"$PROJECT_DIR/bins/generate_appcast" \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --maximum-versions 10 \
  "$STAGING"

cp "$STAGING/appcast.xml" build/appcast.xml
find "$STAGING" -name "*.delta" -exec cp {} build/ \; 2>/dev/null || true
rm -rf "$STAGING"
log "appcast generated at build/appcast.xml"

# ── Tag + push ───────────────────────────────────────────────────────────────

log "pushing tags..."
git push --follow-tags

# ── GitHub Release ───────────────────────────────────────────────────────────

log "creating GitHub Release..."
UPLOAD_FILES=("$DMG_PATH" "$ZIP_PATH" "build/appcast.xml")
DELTA_FILES=( $(find build -name "*.delta" -type f 2>/dev/null || true) )
UPLOAD_FILES+=("${DELTA_FILES[@]}")

gh release create "$TAG" "${UPLOAD_FILES[@]}" \
  --repo "$REPO" \
  --title "Prowl $VERSION" \
  --notes-file "$NOTES_FILE"

RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"
log "release created: $RELEASE_URL"

# ── Update Prowl-Site ────────────────────────────────────────────────────────

if [[ -d "$PROWL_SITE" ]]; then
  log "updating Prowl-Site appcast..."
  mkdir -p "$PROWL_SITE/public"
  cp build/appcast.xml "$PROWL_SITE/public/appcast.xml"
  pushd "$PROWL_SITE" >/dev/null
  if [[ -n "$(git status --porcelain)" ]]; then
    git add public/appcast.xml
    git commit -m "Update appcast for Prowl $VERSION"
    git push
    log "Prowl-Site pushed (Netlify deploy will follow)"
  else
    log "Prowl-Site appcast unchanged"
  fi
  popd >/dev/null
else
  log "Prowl-Site not found at $PROWL_SITE — skipping appcast deploy"
  log "copy build/appcast.xml manually or set PROWL_SITE_DIR"
fi

echo
log "done! Release: $RELEASE_URL"
