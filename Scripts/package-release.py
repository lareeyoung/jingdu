#!/usr/bin/env python3
"""Create clean source and macOS arm64 test releases, without local signing keys.

Uses only --prepare plus ad-hoc signing inside a temporary directory. It never
installs the app, calls sign-local-app.py, or changes keychain/Gatekeeper settings.
No models, accounts, media, user library, or AppleDouble metadata are packaged.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT_FILES = ("build.command", ".gitignore", ".gitattributes", "README.md")
ENGINE_FILES = ("README.txt", "LICENSE-whisper.cpp", "LICENSE-whisper-model", "THIRD_PARTY_NOTICES.txt")
SOURCE_GLOBS = ("Sources/*.swift", "Tests/*.swift", "Tests/*.py", "Scripts/*.py", "Scripts/*.md")
TEXT_SUFFIXES = {".swift", ".py", ".md", ".txt", ".command"}


class ReleaseError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def command(arguments, *, cwd=None, env=None):
    try:
        result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as error:
        # Commands never carry credentials. Build diagnostics are useful here.
        raise ReleaseError(f"命令失败：{Path(arguments[0]).name}\n{error.stderr[-6000:]}") from None
    return result.stdout + result.stderr


def checked_file(root, relative):
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ReleaseError(f"打包来源必须是项目内的普通文件：{relative}")
    return path


def source_files(root):
    selected = {Path(name) for name in SOURCE_ROOT_FILES if (root / name).exists()}
    for pattern in SOURCE_GLOBS:
        selected.update(path.relative_to(root) for path in root.glob(pattern) if not path.name.startswith("."))
    selected.update(Path("Resources") / name for name in ("Info.plist", "AppIcon.icns"))
    selected.update(Path("Resources/SubtitleEngine") / name for name in ENGINE_FILES)
    required = {Path("build.command"), Path("Sources/JingduApp.swift"), Path("Sources/ScriptRelay.swift"),
                Path("Scripts/package-release.py"), Path("Scripts/prepare-subtitle-engine.py"), Path("Scripts/DISTRIBUTION.md")}
    if not required.issubset(selected):
        raise ReleaseError("缺少构建/分发必需源码文件。")
    for relative in sorted(selected):
        path = checked_file(root, relative)
        # Hidden sidecars and generated data cannot enter via a new allowlist.
        if any(part.startswith("._") or part in {"__pycache__", ".git", "BuildSigning"} for part in relative.parts):
            raise ReleaseError(f"打包清单包含非源码文件：{relative}")
        if relative.suffix not in TEXT_SUFFIXES and relative.name not in {".gitignore", ".gitattributes"}:
            continue
        content = path.read_text(encoding="utf-8")
        if re.search(r"^-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----", content, re.MULTILINE):
            raise ReleaseError(f"检测到私钥材料，已阻止打包：{relative}")
        if re.search(r"/(?:Users|home)/[^/\s\"'<>]+/|/Vol" r"umes/[^/\n]+/", content):
            raise ReleaseError(f"检测到个人绝对路径，请先清理：{relative}")
        # Tests intentionally contain private-network validation fixtures. Only
        # shipped product source must have no private relay defaults or links.
        if relative.parts[0] == "Sources":
            for match in re.finditer(r'https?://([^/\s\"\')]+)', content):
                host = match.group(1).split(":")[0].lower()
                try:
                    address = ipaddress.ip_address(host)
                    private = address.is_private and not address.is_loopback
                except ValueError:
                    private = host.endswith((".internal", ".corp", ".local", "baidu-int.com"))
                if private:
                    raise ReleaseError(f"检测到产品源码中的内网服务地址，请先改为通用配置：{relative}")
    return sorted(selected)


def copy_plain(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)  # No extended attributes or sidecars.
    destination.chmod(0o755 if source.suffix in {".command", ".py"} else 0o644)


def zip_tree(folder, destination):
    """Stable paths, timestamps and permissions; never copy extended attributes."""
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(folder.rglob("*")):
            if path.is_symlink():
                raise ReleaseError("归档中不能含符号链接。")
            if not path.is_file():
                continue
            relative = path.relative_to(folder.parent)
            if any(part.startswith("._") or part in {".DS_Store", "__MACOSX", "__pycache__", ".git"} for part in relative.parts):
                raise ReleaseError("归档中发现未清理的元数据。")
            item = zipfile.ZipInfo(relative.as_posix(), date_time=(2020, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = (stat.S_IFREG | stat.S_IMODE(path.stat().st_mode)) << 16
            archive.writestr(item, path.read_bytes())


def validate_binary(path, run):
    if run(["/usr/bin/lipo", "-archs", str(path)]).strip() != "arm64":
        raise ReleaseError("发行包只支持 arm64；引擎与主程序必须都为 arm64。")
    dependencies = run(["/usr/bin/otool", "-L", str(path)])
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(" (")[0]
        if dependency and not dependency.startswith(("/System/Library/", "/usr/lib/")):
            raise ReleaseError(f"发行包包含非系统动态库依赖：{dependency}")


def validate_bundle(app):
    expected = {"Contents/Info.plist", "Contents/MacOS/Jingdu", "Contents/Resources/AppIcon.icns",
                "Contents/_CodeSignature/CodeResources", "Contents/Resources/SubtitleEngine/whisper-cli"}
    expected.update("Contents/Resources/SubtitleEngine/" + name for name in ENGINE_FILES)
    for path in app.rglob("*"):
        if path.is_symlink() or (path.is_file() and path.relative_to(app).as_posix() not in expected):
            raise ReleaseError("候选应用出现未列入清单的文件，已停止分发。")


def package(root, output, *, source_only=False, run=command):
    root = root.resolve()
    output = output.expanduser().absolute()
    if output.exists():
        raise ReleaseError("输出目录已存在。请指定新的发行目录，避免覆盖已有文件。")
    resolved_output = output.resolve()
    if any(part.endswith(".app") for part in resolved_output.parts) or resolved_output.is_relative_to(Path.home() / "Applications") or resolved_output.is_relative_to(Path("/Applications")):
        raise ReleaseError("发行目录不能位于已安装的应用或 Applications 中。")
    selected = source_files(root)
    info = plistlib.loads(checked_file(root, Path("Resources/Info.plist")).read_bytes())
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) or info.get("LSMinimumSystemVersion") != "14.0":
        raise ReleaseError("请确认版本号与 macOS 14.0 最低系统要求。")
    if info.get("CFBundleIdentifier") != "local.jingdu.studio":
        raise ReleaseError("应用标识不符合镜读发行配置。")
    engine = None if source_only else checked_file(root, Path("Resources/SubtitleEngine/whisper-cli"))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".jingdu-release-", dir=output.parent) as temporary:
        work = Path(temporary)
        staging = work / "artifacts"; staging.mkdir()
        source = work / f"Jingdu-{version}-source"; source.mkdir()
        for relative in selected:
            copy_plain(root / relative, source / relative)
        # This is the only source tree given to the compiler. User preferences,
        # library data and private signing files are never read or copied.
        source_zip = staging / f"Jingdu-{version}-source.zip"
        zip_tree(source, source_zip)
        artifacts = [source_zip]
        if not source_only:
            if sys.platform != "darwin":
                raise ReleaseError("macOS 应用构建需要在 macOS 上执行；其他系统可用 --source-only。")
            validate_binary(engine, run)
            copy_plain(engine, source / "Resources/SubtitleEngine/whisper-cli")
            (source / "Resources/SubtitleEngine/whisper-cli").chmod(0o755)
            binary = work / f"Jingdu-{version}-macOS-arm64"; binary.mkdir()
            app = binary / "镜读.app"
            environment = os.environ.copy()
            environment.update(JINGDU_APP_OUTPUT=str(app), COPYFILE_DISABLE="1")
            run(["/bin/zsh", "build.command", "--prepare"], cwd=source, env=environment)
            validate_bundle(app)
            built_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if built_info != info:
                raise ReleaseError("候选应用信息与源码版本不一致。")
            main = app / "Contents/MacOS/Jingdu"
            decoder = app / "Contents/Resources/SubtitleEngine/whisper-cli"
            validate_binary(main, run); validate_binary(decoder, run)
            for target in (decoder, app):
                run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(target)])
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
            if "Signature=adhoc" not in run(["/usr/bin/codesign", "--display", "--verbose=2", str(app)]):
                raise ReleaseError("发行候选并非明确的 ad-hoc 测试签名，已停止。")
            validate_bundle(app)
            copy_plain(source / "Scripts/DISTRIBUTION.md", binary / "安装与模型准备.md")
            copy_plain(source / "Scripts/prepare-subtitle-engine.py", binary / "Scripts/prepare-subtitle-engine.py")
            binary_zip = staging / f"Jingdu-{version}-macOS-arm64.zip"
            zip_tree(binary, binary_zip); artifacts.append(binary_zip)
        metadata = {
            "version": version, "build": str(info.get("CFBundleVersion", "")), "architecture": "arm64", "minimumMacOS": "14.0",
            "distribution": "colleague-test", "signature": None if source_only else "ad-hoc", "notarized": False,
            "modelBundled": False, "sourceFiles": {str(path): sha256(source / path) for path in selected},
            "artifacts": {path.name: sha256(path) for path in artifacts},
        }
        (staging / "RELEASE.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        artifacts.append(staging / "RELEASE.json")
        (staging / "SHA256SUMS").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in artifacts), encoding="utf-8")
        # Never publish a package built from a source snapshot that changed
        # while another task was editing or adding files during compilation.
        if source_files(root) != selected or any(sha256(root / path) != metadata["sourceFiles"][str(path)] for path in selected):
            raise ReleaseError("构建期间源码清单或内容发生变化，请在代码冻结后重新打包。")
        # All build and signing work has succeeded. No installed app is touched.
        if output.exists():
            raise ReleaseError("输出目录在构建期间被创建，已停止，未覆盖。")
        staging.rename(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="全新发行目录，不能指向 Applications")
    parser.add_argument("--source-only", action="store_true", help="只生成干净源码归档，不构建或签名")
    parser.add_argument("--check", action="store_true", help="只检查源码分发清单，不产生包或修改设置")
    args = parser.parse_args()
    try:
        if args.check:
            if args.output_dir or args.source_only:
                parser.error("--check 不与输出或构建选项混用")
            print(f"源码分发检查通过：{len(source_files(ROOT))} 个白名单文件。")
        else:
            if not args.output_dir:
                parser.error("请用 --output-dir 指定新的发行目录")
            destination = package(ROOT, args.output_dir, source_only=args.source_only)
            print(f"已生成发行文件：{destination}")
            print("这是未经 Developer ID 公证的同事测试包；安装说明和 SHA256SUMS 已附带。")
    except (ReleaseError, OSError, ValueError) as error:
        print(f"未生成发行包：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
