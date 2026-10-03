#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/GenPlayer.xcodeproj/project.pbxproj"
NOTES_DIR="$ROOT_DIR/docs/releases"
NOTES_FILE="$NOTES_DIR/latest_app_store_release_notes.md"
CHANGELOG_FILE=""
TAG_MESSAGE_FILE=""
RELEASE_MODE="app-store"
RELEASE_SLUG=""
TAG_NAME=""

DO_BUILD=1
DO_COMMIT=0
DO_PUSH=0
ALLOW_DIRTY=0
DRY_RUN=0
BUILD_ONLY=0
SYNC_WEBSITE=1
TARGET_VERSION=""
TARGET_BUILD=""
BASE_REF=""
CUSTOM_NOTES_CN=""
CUSTOM_NOTES_CN_FILE=""
CUSTOM_NOTES_EN=""
CUSTOM_NOTES_EN_FILE=""

usage() {
  cat <<'EOF'
Usage:
  scripts/prepare_appstore_release.sh [options]

Options:
  --version <version>       Target marketing version. Default: patch bump.
  --build <build>           Target build number. Default: current build + 1.
  --base-ref <ref>          Git ref used as the release notes baseline.
  --notes-cn <text>         Custom release notes in Chinese (plain text or markdown list).
  --notes-cn-file <path>    Path to a file containing Chinese release notes.
  --notes-en <text>         Custom release notes in English (plain text or markdown list).
  --notes-en-file <path>    Path to a file containing English release notes.
  --sync-website            Sync release notes to website/changelog.html & site.js (default for app-store mode).
  --no-sync-website         Disable syncing release notes to website files.
  --build-only              Keep the current marketing version and bump build only.
  --skip-build              Skip xcodebuild validation.
  --commit                  Create a git commit after updating files.
  --push                    Push the current branch after committing.
  --allow-dirty             Allow running with a dirty worktree.
  --dry-run                 Print the planned release values without editing files.
  --help                    Show this message.

Examples:
  scripts/prepare_appstore_release.sh --base-ref cd510c9
  scripts/prepare_appstore_release.sh --notes-cn-file /tmp/notes_cn.txt --notes-en-file /tmp/notes_en.txt
  scripts/prepare_appstore_release.sh --build-only --base-ref cd510c9
  scripts/prepare_appstore_release.sh --version 1.0.8 --build 15 --commit
  scripts/prepare_appstore_release.sh --version 1.1.0 --build 1 --commit --push
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      TARGET_VERSION="${2:-}"
      shift 2
      ;;
    --build)
      TARGET_BUILD="${2:-}"
      shift 2
      ;;
    --base-ref)
      BASE_REF="${2:-}"
      shift 2
      ;;
    --notes-cn)
      CUSTOM_NOTES_CN="${2:-}"
      shift 2
      ;;
    --notes-cn-file)
      CUSTOM_NOTES_CN_FILE="${2:-}"
      shift 2
      ;;
    --notes-en)
      CUSTOM_NOTES_EN="${2:-}"
      shift 2
      ;;
    --notes-en-file)
      CUSTOM_NOTES_EN_FILE="${2:-}"
      shift 2
      ;;
    --sync-website)
      SYNC_WEBSITE=1
      shift
      ;;
    --no-sync-website)
      SYNC_WEBSITE=0
      shift
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --skip-build)
      DO_BUILD=0
      shift
      ;;
    --commit)
      DO_COMMIT=1
      shift
      ;;
    --push)
      DO_PUSH=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $DO_PUSH -eq 1 && $DO_COMMIT -ne 1 ]]; then
  echo "--push requires --commit." >&2
  exit 1
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Missing project file: $PROJECT_FILE" >&2
  exit 1
fi

extract_app_setting() {
  local key="$1"
  local config_id="${MAIN_TARGET_CONFIG_IDS[0]}"

  awk -v key="$key" -v config_id="$config_id" '
    $0 ~ "^[[:space:]]*" config_id " /\\* (Debug|Release) \\*/ = \\{" {
      in_target_config = 1
    }

    in_target_config && index($0, key " = ") {
      value = $0
      sub("^.*" key " = ", "", value)
      sub(";.*$", "", value)
      print value
      exit
    }

    in_target_config && /^[[:space:]]*};$/ {
      in_target_config = 0
    }
  ' "$PROJECT_FILE"
}

extract_main_target_config_ids() {
  awk '
    /Build configuration list for PBXNativeTarget "GenPlayer"/ || /Build configuration list for PBXNativeTarget "GenPlayer_tvOS"/ || /Build configuration list for PBXNativeTarget "GenPlayer_macOS"/ {
      in_target_list = 1
      next
    }

    in_target_list && /\);/ {
      in_target_list = 0
    }

    in_target_list && /\/\* (Debug|Release) \*\// {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, /[[:space:]]+/)
      print parts[1]
    }
  ' "$PROJECT_FILE"
}

increment_patch_version() {
  local version="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$version"

  if [[ -z "${major:-}" || -z "${minor:-}" ]]; then
    echo "Unsupported version format: $version" >&2
    exit 1
  fi

  if [[ -z "${patch:-}" ]]; then
    echo "${major}.${minor}.1"
  else
    echo "${major}.${minor}.$((patch + 1))"
  fi
}

MAIN_TARGET_CONFIG_IDS=()
while IFS= read -r config_id; do
  if [[ -n "$config_id" ]]; then
    MAIN_TARGET_CONFIG_IDS+=("$config_id")
  fi
done < <(extract_main_target_config_ids)

if [[ ${#MAIN_TARGET_CONFIG_IDS[@]} -eq 0 ]]; then
  echo "Failed to locate GenPlayer target build configurations in project file." >&2
  exit 1
fi

current_version="$(extract_app_setting "MARKETING_VERSION")"
current_build="$(extract_app_setting "CURRENT_PROJECT_VERSION")"

if [[ -z "$current_version" || -z "$current_build" ]]; then
  echo "Failed to read current app version/build from project." >&2
  exit 1
fi

if [[ -z "$TARGET_VERSION" ]]; then
  if [[ $BUILD_ONLY -eq 1 ]]; then
    TARGET_VERSION="$current_version"
  else
    TARGET_VERSION="$(increment_patch_version "$current_version")"
  fi
fi

if [[ -z "$TARGET_BUILD" ]]; then
  TARGET_BUILD="$((current_build + 1))"
fi

if [[ -z "$BASE_REF" ]]; then
  if git -C "$ROOT_DIR" describe --tags --abbrev=0 >/dev/null 2>&1; then
    BASE_REF="$(git -C "$ROOT_DIR" describe --tags --abbrev=0)"
  fi
fi

if [[ -z "$BASE_REF" ]]; then
  BASE_REF="$(git -C "$ROOT_DIR" log -G 'CURRENT_PROJECT_VERSION = |MARKETING_VERSION = ' --format='%H' -- GenPlayer.xcodeproj/project.pbxproj | sed -n '1p')"
fi

if [[ -z "$BASE_REF" ]]; then
  BASE_REF="$(git -C "$ROOT_DIR" rev-list --max-parents=0 HEAD | tail -n 1)"
fi

if ! git -C "$ROOT_DIR" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  echo "Invalid --base-ref: $BASE_REF" >&2
  exit 1
fi

if [[ $BUILD_ONLY -eq 1 ]]; then
  RELEASE_MODE="build-only"
  RELEASE_SLUG="build-v${TARGET_VERSION}-b${TARGET_BUILD}"
  TAG_NAME="build/v${TARGET_VERSION}-b${TARGET_BUILD}"
else
  RELEASE_MODE="app-store"
  RELEASE_SLUG="v${TARGET_VERSION}"
  TAG_NAME="v${TARGET_VERSION}"
fi

CHANGELOG_FILE="$NOTES_DIR/${RELEASE_SLUG}.md"
TAG_MESSAGE_FILE="$NOTES_DIR/${RELEASE_SLUG}.tag.md"

if [[ $ALLOW_DIRTY -ne 1 ]]; then
  if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
    echo "Worktree is dirty. Commit or stash changes first, or rerun with --allow-dirty." >&2
    exit 1
  fi
fi

subjects="$(git -C "$ROOT_DIR" log --no-merges --format='%s' "${BASE_REF}..HEAD")"
commit_count="$(git -C "$ROOT_DIR" rev-list --count --no-merges "${BASE_REF}..HEAD")"
diff_summary="$(git -C "$ROOT_DIR" diff --shortstat "${BASE_REF}..HEAD" | sed 's/^[[:space:]]*//')"
commit_log="$(git -C "$ROOT_DIR" log --no-merges --reverse --date=short --format='- %ad %h %s' "${BASE_REF}..HEAD")"

if [[ -z "$diff_summary" ]]; then
  diff_summary="No code diff detected."
fi

if [[ -z "$commit_log" ]]; then
  commit_log="- No non-merge commits found between ${BASE_REF} and HEAD."
fi

parse_notes_into_cn() {
  local input="$1"
  cn_notes=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      cn_notes+=("$line")
    fi
  done < <(python3 -c "
import sys, os
sys.path.insert(0, '$ROOT_DIR/scripts')
from sync_website_changelog import parse_raw_notes_text
notes = parse_raw_notes_text(sys.stdin.read())
for n in notes:
    print(n)
" <<< "$input")
}

parse_notes_into_en() {
  local input="$1"
  en_notes=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      en_notes+=("$line")
    fi
  done < <(python3 -c "
import sys, os
sys.path.insert(0, '$ROOT_DIR/scripts')
from sync_website_changelog import parse_raw_notes_text
notes = parse_raw_notes_text(sys.stdin.read())
for n in notes:
    print(n)
" <<< "$input")
}

if [[ -n "$CUSTOM_NOTES_CN_FILE" && -f "$CUSTOM_NOTES_CN_FILE" ]]; then
  CUSTOM_NOTES_CN="$(cat "$CUSTOM_NOTES_CN_FILE")"
fi

if [[ -n "$CUSTOM_NOTES_EN_FILE" && -f "$CUSTOM_NOTES_EN_FILE" ]]; then
  CUSTOM_NOTES_EN="$(cat "$CUSTOM_NOTES_EN_FILE")"
fi

cn_notes=()
en_notes=()

if [[ -n "$CUSTOM_NOTES_CN" ]]; then
  parse_notes_into_cn "$CUSTOM_NOTES_CN"
fi

if [[ -n "$CUSTOM_NOTES_EN" ]]; then
  parse_notes_into_en "$CUSTOM_NOTES_EN"
fi

if [[ ${#cn_notes[@]} -eq 0 ]]; then
  has_iptv=0
  has_thumbnails=0
  has_macos=0
  has_tvos=0
  has_download=0
  has_subtitles=0
  has_privacy=0
  has_playback=0
  has_browsing=0
  has_localization=0

  if printf '%s\n' "$subjects" | grep -Eqi 'iptv|epg|m3u|xmltv'; then
    has_iptv=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'thumb|thumbnail|16:9|aspect'; then
    has_thumbnails=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'mac|macos|pip|multi-window|window|pin'; then
    has_macos=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'tvos|focus|shelf'; then
    has_tvos=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'download|offline'; then
    has_download=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'subtitle|audio track'; then
    has_subtitles=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'privacy|pin|lock'; then
    has_privacy=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'playback|player|audio|vlc|background|lock screen|resume|seeking|seek'; then
    has_playback=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'search|webdav|remote|favorite|folder|navigation|detail|playlist|image|smb|jellyfin|emby|plex|server'; then
    has_browsing=1
  fi

  if printf '%s\n' "$subjects" | grep -Eqi 'language|localization|chinese|traditional chinese|i18n'; then
    has_localization=1
  fi

  if [[ $has_iptv -eq 1 ]]; then
    cn_notes+=("新增支持导入 IPTV (M3U) 播放列表与 XMLTV 电子节目指南 (EPG)，支持播放器内查看节目单与频道收藏。")
    en_notes+=("Added IPTV (M3U) playlist and XMLTV EPG program guide support, with in-player guide browsing and channel favorites.")
  fi

  if [[ $has_thumbnails -eq 1 ]]; then
    cn_notes+=("新增 Jellyfin、Emby、Plex 媒体库 16:9 横版缩略图展示模式，海报与剧照自由切换。")
    en_notes+=("Added 16:9 landscape thumbnail display mode for Jellyfin, Emby, and Plex media libraries.")
  fi

  if [[ $has_macos -eq 1 ]]; then
    cn_notes+=("优化 macOS 播放器体验，支持按视频画幅自适应无黑边播放、原生画中画 (PiP)、窗口置顶与服务器配置导入导出备份。")
    en_notes+=("Enhanced macOS player with aspect-ratio adaptive resizing (no black bars), native Picture-in-Picture (PiP), window pinning, and server backup import/export.")
  fi

  if [[ $has_tvos -eq 1 ]]; then
    cn_notes+=("优化 Apple TV 大屏导航、遥控器焦点与分类浏览体验。")
    en_notes+=("Optimized Apple TV navigation, remote focus handling, and shelf layouts.")
  fi

  if [[ $has_download -eq 1 ]]; then
    cn_notes+=("优化离线下载中心并发管理与文件存储稳定性。")
    en_notes+=("Improved download concurrency and offline storage stability.")
  fi

  if [[ $has_subtitles -eq 1 ]]; then
    cn_notes+=("优化外挂字幕与多音轨选择体验。")
    en_notes+=("Enhanced external subtitle and audio track switching.")
  fi

  if [[ $has_privacy -eq 1 ]]; then
    cn_notes+=("完善隐私空间安全保护与解锁体验。")
    en_notes+=("Refined Privacy Space locking and security workflows.")
  fi

  if [[ $has_playback -eq 1 ]]; then
    cn_notes+=("优化播放稳定性、断点续播与后台恢复体验。")
    en_notes+=("Improved playback stability, resume behavior, and background recovery.")
  fi

  if [[ $has_browsing -eq 1 ]]; then
    cn_notes+=("提升远程媒体浏览、搜索与导航稳定性。")
    en_notes+=("Enhances remote media browsing, search, and navigation stability.")
  fi

  if [[ $has_localization -eq 1 ]]; then
    cn_notes+=("改进多语言显示与本地化体验。")
    en_notes+=("Refines multilingual display and localization behavior.")
  fi

  if [[ ${#cn_notes[@]} -eq 0 ]]; then
    cn_notes+=("修复若干问题并提升整体稳定性。")
    en_notes+=("Fixes issues and improves overall stability.")
  fi
fi

if [[ ${#en_notes[@]} -eq 0 ]]; then
  en_notes=("${cn_notes[@]}")
fi

render_notes_file() {
  local output_file="$1"
  {
    echo "# App Store Release Notes Draft"
    echo
    echo "- Current project version: ${current_version} (${current_build})"
    echo "- Next candidate version: ${TARGET_VERSION} (${TARGET_BUILD})"
    echo "- Git baseline: ${BASE_REF}"
    echo "- Release mode: ${RELEASE_MODE}"
    echo "- Suggested tag: ${TAG_NAME}"
    echo "- Detailed changelog: docs/releases/${RELEASE_SLUG}.md"
    echo
    echo "## 中文"
    echo
    for note in "${cn_notes[@]}"; do
      echo "- ${note}"
    done
    echo
    echo "## English"
    echo
    for note in "${en_notes[@]}"; do
      echo "- ${note}"
    done
  } > "$output_file"
}

render_changelog_file() {
  local output_file="$1"
  {
    echo "# Release ${RELEASE_SLUG}"
    echo
    echo "- Current project version: ${current_version} (${current_build})"
    echo "- Prepared version: ${TARGET_VERSION} (${TARGET_BUILD})"
    echo "- Release mode: ${RELEASE_MODE}"
    echo "- Suggested tag: ${TAG_NAME}"
    echo "- Git baseline: ${BASE_REF}"
    echo "- Non-merge commits: ${commit_count}"
    echo "- Diff summary: ${diff_summary}"
    echo
    echo "## App Store Copy"
    echo
    echo "### 中文"
    echo
    for note in "${cn_notes[@]}"; do
      echo "- ${note}"
    done
    echo
    echo "### English"
    echo
    for note in "${en_notes[@]}"; do
      echo "- ${note}"
    done
    echo
    echo "## Detailed Changelog"
    echo
    printf '%s\n' "$commit_log"
  } > "$output_file"
}

render_tag_message_file() {
  local output_file="$1"
  {
    echo "Prepare ${TARGET_VERSION} (${TARGET_BUILD})"
    echo
    echo "Mode: ${RELEASE_MODE}"
    echo "Baseline: ${BASE_REF}"
    echo "Commits: ${commit_count}"
    echo "Diff: ${diff_summary}"
    echo
    echo "App Store Notes (CN):"
    for note in "${cn_notes[@]}"; do
      echo "- ${note}"
    done
    echo
    echo "App Store Notes (EN):"
    for note in "${en_notes[@]}"; do
      echo "- ${note}"
    done
    echo
    echo "Detailed changelog:"
    echo "- docs/releases/${RELEASE_SLUG}.md"
  } > "$output_file"
}

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Current project version: ${current_version} (${current_build})"
  echo "Next candidate version: ${TARGET_VERSION} (${TARGET_BUILD})"
  echo "Release mode: ${RELEASE_MODE}"
  echo "Git baseline: ${BASE_REF}"
  echo "Suggested tag: ${TAG_NAME}"
  echo "Detailed changelog: docs/releases/${RELEASE_SLUG}.md"
  echo "Commit count: ${commit_count}"
  echo "Diff summary: ${diff_summary}"
  echo
  echo "Chinese release notes:"
  for note in "${cn_notes[@]}"; do
    echo "- ${note}"
  done
  echo
  echo "English release notes:"
  for note in "${en_notes[@]}"; do
    echo "- ${note}"
  done
  exit 0
fi

tmp_project="$(mktemp)"
config_id_pattern="$(printf '%s|' "${MAIN_TARGET_CONFIG_IDS[@]}")"
config_id_pattern="${config_id_pattern%|}"

awk -v version="$TARGET_VERSION" -v build="$TARGET_BUILD" -v config_ids="$config_id_pattern" '
  $0 ~ "^[[:space:]]*(" config_ids ") /\\* (Debug|Release) \\*/ = \\{" {
    in_target_config = 1
  }

  in_target_config && /CURRENT_PROJECT_VERSION = / {
    sub(/= [^;]+;/, "= " build ";")
  }

  in_target_config && /MARKETING_VERSION = / {
    sub(/= [^;]+;/, "= " version ";")
  }

  {
    print
  }

  in_target_config && /^[[:space:]]*};$/ {
    in_target_config = 0
  }
' "$PROJECT_FILE" > "$tmp_project"
mv "$tmp_project" "$PROJECT_FILE"

mkdir -p "$NOTES_DIR"
render_notes_file "$NOTES_FILE"
render_changelog_file "$CHANGELOG_FILE"
render_tag_message_file "$TAG_MESSAGE_FILE"

sync_website_changelog() {
  local target_ver="$1"
  local today_date
  today_date="$(date +'%Y-%m-%d')"
  local html_file="$ROOT_DIR/website/changelog.html"
  local js_file="$ROOT_DIR/website/assets/site.js"

  if [[ ! -f "$html_file" || ! -f "$js_file" ]]; then
    echo "Website files not found, skipping website changelog sync."
    return 0
  fi

  echo "Syncing release notes to website/changelog.html and website/assets/site.js..."
  local cn_tmp
  cn_tmp="$(mktemp)"
  local en_tmp
  en_tmp="$(mktemp)"

  printf '%s\n' "${cn_notes[@]}" > "$cn_tmp"
  printf '%s\n' "${en_notes[@]}" > "$en_tmp"

  python3 "$ROOT_DIR/scripts/sync_website_changelog.py" \
    --version "$target_ver" \
    --date "$today_date" \
    --notes-cn-file "$cn_tmp" \
    --notes-en-file "$en_tmp"

  rm -f "$cn_tmp" "$en_tmp"
  echo "Website changelog synced."
}

if [[ $SYNC_WEBSITE -eq 1 && $BUILD_ONLY -ne 1 ]]; then
  sync_website_changelog "$TARGET_VERSION"
fi

if [[ $DO_BUILD -eq 1 ]]; then
  (
    cd "$ROOT_DIR"
    python3 "$ROOT_DIR/scripts/build_vlckit_rate_fix.py" --ensure
    DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
    echo "Validating iOS build using ${DEVELOPER_PATH}..."
    env DEVELOPER_DIR="${DEVELOPER_PATH}" \
      xcodebuild \
      -project GenPlayer.xcodeproj \
      -scheme GenPlayer \
      -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' \
      build \
      CODE_SIGNING_ALLOWED=NO

    echo "Validating tvOS build using ${DEVELOPER_PATH}..."
    env DEVELOPER_DIR="${DEVELOPER_PATH}" \
      xcodebuild \
      -project GenPlayer.xcodeproj \
      -scheme GenPlayer_tvOS \
      -sdk appletvsimulator \
      -destination 'generic/platform=tvOS Simulator' \
      build \
      CODE_SIGNING_ALLOWED=NO

    echo "Validating macOS build using ${DEVELOPER_PATH}..."
    env DEVELOPER_DIR="${DEVELOPER_PATH}" \
      xcodebuild \
      -project GenPlayer.xcodeproj \
      -scheme GenPlayer_macOS \
      -destination 'generic/platform=macOS' \
      build \
      CODE_SIGNING_ALLOWED=NO
  )
fi

if [[ $DO_COMMIT -eq 1 ]]; then
  git -C "$ROOT_DIR" add "$PROJECT_FILE" "$NOTES_FILE" "$CHANGELOG_FILE" "$TAG_MESSAGE_FILE"
  if [[ $SYNC_WEBSITE -eq 1 && $BUILD_ONLY -ne 1 ]]; then
    git -C "$ROOT_DIR" add "$ROOT_DIR/website/changelog.html" "$ROOT_DIR/website/assets/site.js"
  fi

  if [[ $BUILD_ONLY -eq 1 ]]; then
    git -C "$ROOT_DIR" commit -m "chore: prepare build ${TARGET_VERSION} (${TARGET_BUILD})"
  else
    git -C "$ROOT_DIR" commit -m "chore: prepare App Store release ${TARGET_VERSION} (${TARGET_BUILD})"
  fi
fi

if [[ $DO_PUSH -eq 1 ]]; then
  git -C "$ROOT_DIR" push
fi

echo "Prepared App Store release ${TARGET_VERSION} (${TARGET_BUILD})."
echo "Release notes draft: $NOTES_FILE"
echo "Versioned changelog: $CHANGELOG_FILE"
echo "Tag annotation draft: $TAG_MESSAGE_FILE"
