#!/usr/bin/env python3
"""Build the pinned offline engine and explicitly install its verified local model.
Build-time dependencies: Python 3, CMake, Apple's Command Line Tools. Runtime has
no Python, Homebrew or network dependency. Use --model-only to install the model.
The optional mirror is opt-in; the upstream model SHA-1 is always mandatory.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

VERSION = "1.8.3"
SOURCE_URL = f"https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v{VERSION}"
SOURCE_SHA256 = "870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a"
MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=true"
MIRROR_URL = "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=true"
MODEL_SHA1 = "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
MODEL_SIZE = 487601967
ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources/SubtitleEngine"
MODEL = Path.home() / "Library/Application Support/Jingdu/SubtitleModels/ggml-small.bin"


def digest(path, algorithm):
    h = hashlib.new(algorithm)
    with path.open("rb") as file:
        while chunk := file.read(4 * 1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def download(url, destination):
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "20",
                    "--max-time", "1800", url, "--output", str(destination)], check=True)


def install_model(allow_mirror):
    MODEL.parent.mkdir(parents=True, exist_ok=True)
    if MODEL.exists() and MODEL.stat().st_size == MODEL_SIZE and digest(MODEL, "sha1") == MODEL_SHA1:
        print("已验证现有多语言字幕模型：", MODEL)
        return
    fd, temporary = tempfile.mkstemp(prefix=".ggml-small-", suffix=".download", dir=MODEL.parent)
    os.close(fd)
    temporary = Path(temporary)
    try:
        try:
            download(MODEL_URL, temporary)
        except subprocess.CalledProcessError:
            if not allow_mirror:
                raise
            print("官方入口不可达，使用已明确允许的镜像；仍严格核对官方哈希。")
            download(MIRROR_URL, temporary)
        if temporary.stat().st_size != MODEL_SIZE or digest(temporary, "sha1") != MODEL_SHA1:
            raise RuntimeError("模型校验失败；未启用文件。")
        os.replace(temporary, MODEL)
        print("已安装并校验多语言模型：", MODEL)
    finally:
        temporary.unlink(missing_ok=True)


def build(cmake):
    cmake = shutil.which(cmake) or (cmake if Path(cmake).is_file() else None)
    if not cmake:
        raise RuntimeError("需要 CMake 构建工具；请安装 CMake，或用 --cmake 指定其可执行文件。")
    with tempfile.TemporaryDirectory(prefix="jingdu-whisper-build-") as work:
        work = Path(work)
        archive = work / "source.tar.gz"
        download(SOURCE_URL, archive)
        if digest(archive, "sha256") != SOURCE_SHA256:
            raise RuntimeError("源码归档校验失败；已停止构建。")
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                candidate = (work / member.name).resolve()
                if not candidate.is_relative_to(work.resolve()) or member.issym() or member.islnk():
                    raise RuntimeError("源码归档包含不安全的路径。")
            tar.extractall(work, filter="data")
        source = work / f"whisper.cpp-{VERSION}"
        destination = work / "build"
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
        flags = ["-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DGGML_METAL=ON",
                 "-DGGML_METAL_EMBED_LIBRARY=ON", "-DGGML_ACCELERATE=ON", "-DGGML_NATIVE=OFF",
                 "-DGGML_OPENMP=OFF", "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_SERVER=OFF",
                 "-DWHISPER_CURL=OFF", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                 f"-DCMAKE_CXX_FLAGS=-isystem {sdk}/usr/include/c++/v1"]
        subprocess.run([cmake, "-S", str(source), "-B", str(destination), *flags], check=True)
        subprocess.run([cmake, "--build", str(destination), "--target", "whisper-cli", "--parallel", "6"], check=True)
        binary = destination / "bin/whisper-cli"
        dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
        for line in dependencies.splitlines()[1:]:
            path = line.strip().split(" (")[0]
            if not path.startswith(("/System/Library/", "/usr/lib/")):
                raise RuntimeError(f"引擎包含非系统动态依赖：{path}")
        RESOURCES.mkdir(parents=True, exist_ok=True)
        staged = RESOURCES / ".whisper-cli.new"
        shutil.copy2(binary, staged)
        staged.chmod(0o755)
        os.replace(staged, RESOURCES / "whisper-cli")
        shutil.copy2(source / "LICENSE", RESOURCES / "LICENSE-whisper.cpp")
        print("已构建无 Homebrew 运行时依赖的本地字幕引擎。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-only", action="store_true")
    parser.add_argument("--engine-only", action="store_true")
    parser.add_argument("--allow-mirror", action="store_true")
    parser.add_argument("--cmake", default="cmake")
    args = parser.parse_args()
    if args.model_only and args.engine_only:
        parser.error("不能同时指定 --model-only 与 --engine-only")
    if not args.model_only:
        build(args.cmake)
    if not args.engine_only:
        install_model(args.allow_mirror)


if __name__ == "__main__":
    main()
