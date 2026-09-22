#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

# Normal builds reuse the fixed identity prepared by Scripts/sign-local-app.py.
# They never establish certificate trust or fall back to an ad-hoc signature.
# To prepare a reviewable, unsigned candidate before the one-time setup:
#   JINGDU_APP_OUTPUT='/tmp/Jingdu-candidate/镜读.app' ./build.command --prepare
# See Scripts/LOCAL-SIGNING.md for the separate trust-and-sign operation.
MODE=sign
case "$#:${1:-}" in
  0:) ;;
  1:--prepare) MODE=prepare ;;
  *) print -u2 '用法：./build.command [--prepare]'; exit 2 ;;
esac

APP=$(python3 - "$MODE" "${JINGDU_APP_OUTPUT:-}" <<'PY'
from pathlib import Path
import sys

mode, requested = sys.argv[1:]
installed = (Path.home() / "Applications/镜读.app").resolve()
if mode == "prepare" and not requested:
    sys.exit("--prepare 必须通过 JINGDU_APP_OUTPUT 指定独立的候选应用路径。")
app = Path(requested).expanduser().resolve() if requested else installed
if app.suffix != ".app":
    sys.exit("输出路径必须以 .app 结尾。")
if mode == "prepare" and (app == installed or installed in app.parents):
    sys.exit("--prepare 不能写入已安装的镜读应用；请指定独立的候选路径。")
if app.exists() and not app.is_dir():
    sys.exit("输出路径已被非目录文件占用。")
print(app)
PY
)

mkdir -p "${APP:h}"
STAGING_ROOT=$(mktemp -d "${APP:h}/.jingdu-build.XXXXXX")
STAGED_APP="$STAGING_ROOT/镜读.app"
cleanup() {
  if [[ -d "$STAGING_ROOT/previous.app" ]]; then
    # If publication or rollback failed, retain the old bundle for recovery.
    print -u2 "已保留上一版本：$STAGING_ROOT/previous.app"
  else
    rm -rf -- "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library Sources/*.swift -framework SwiftUI -framework AVKit -framework AVFoundation -framework AppKit -o "$STAGED_APP/Contents/MacOS/Jingdu"
cp -X Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp -X Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/"; fi
if [[ -d Resources/SubtitleEngine ]]; then
  mkdir -p "$STAGED_APP/Contents/Resources/SubtitleEngine"
  # The repository can live on exFAT. Do not seal AppleDouble sidecars as
  # resources: ditto unfolds those metadata files during installation.
  cp -X Resources/SubtitleEngine/* "$STAGED_APP/Contents/Resources/SubtitleEngine/"
fi

if [[ "$MODE" == sign ]]; then
  python3 Scripts/sign-local-app.py sign "$STAGED_APP"
fi

# Stage on the destination volume. Only publish after successful compilation
# and (for normal builds) signature verification. Restore the old bundle if
# the final rename fails, and never delete a backup that could not be restored.
python3 - "$STAGED_APP" "$APP" "$STAGING_ROOT/previous.app" <<'PY'
from pathlib import Path
import os
import shutil
import sys

candidate, destination, backup = map(Path, sys.argv[1:])
had_previous = destination.exists()
if had_previous:
    os.rename(destination, backup)
try:
    os.rename(candidate, destination)
except BaseException:
    if had_previous:
        os.rename(backup, destination)
    raise
if had_previous:
    shutil.rmtree(backup)
PY

if [[ "$MODE" == prepare ]]; then
  print "已生成待签名候选包：$APP（未签名，未写入安装目录）"
else
  print "已使用固定身份构建并验证：$APP"
fi
