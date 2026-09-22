#!/usr/bin/env python3
"""Run the offline model/subtitle release regressions on macOS.

Requires Python 3, Apple's Swift Command Line Tools, and ffmpeg for a disposable
synthetic MP4. No application launch, real model request, system keychain access,
user-library read, download, signing, or installation is performed. The optional
full Whisper integration and real keychain probes are deliberately not run.

Usage: python3 Tests/run-release-regressions.py
       python3 Tests/run-release-regressions.py --suite ScriptRelayTests
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
CORE = [
    "Models", "SubtitleModels", "ScriptModels", "ScriptReading", "ScriptPrompt",
    "ScriptRelay", "ScriptKeychain", "ScriptCredentials", "ScriptResponseArchive",
    "MediaAnalyzer", "CompositionBuilder", "ScriptCompression", "ScriptMediaPreparer",
    "AppModel", "ScriptWorkspaceModel", "SubtitleWorkspace", "SubtitleTranslation",
    "SubtitleTranscriber", "TimelineFollow",
]
SUITES = [
    "ScriptRelayTests", "ScriptModelsTests", "ScriptReadingTests",
    "ScriptSubtitleSharingTests", "SubtitleModelsTests", "SubtitleTranslationTests",
    "SubtitleTranscriberTests", "ScriptWorkflowTests", "ScriptAutoGenerationTests",
    "SharedSubtitlePipelineTests", "SubtitleWorkflowTests", "ScriptAuthorizationWorkflowTests",
]
MEDIA_SUITES = {
    "ScriptWorkflowTests", "ScriptAutoGenerationTests", "SharedSubtitlePipelineTests",
    "ScriptAuthorizationWorkflowTests",
}
FRAMEWORKS = ["SwiftUI", "AVKit", "AVFoundation", "AppKit", "Security", "LocalAuthentication"]


def run(command, *, env=None, timeout=300):
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        if result.stdout:
            print(result.stdout, flush=True)
        if result.stderr:
            print(result.stderr, flush=True)
        raise RuntimeError(f"{Path(command[0]).name} exited with code {result.returncode}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="append", choices=SUITES, help="Run only the named suite; repeat to select several.")
    args = parser.parse_args()
    suites = args.suite or SUITES
    ffmpeg = shutil.which("ffmpeg")
    needs_media = bool(MEDIA_SUITES.intersection(suites))
    if needs_media and ffmpeg is None:
        parser.error("ffmpeg is needed to generate the synthetic fixture; install it separately or select a suite without media.")
    framework_flags = [flag for name in FRAMEWORKS for flag in ("-framework", name)]
    swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos14.0", "-O", "-parse-as-library"]
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="jingdu-release-regressions-") as temporary:
        work = Path(temporary)
        module = "JingduRegressionCore"
        print("Building the shared test module…", flush=True)
        run(swift + ["-enable-testing", "-emit-library", "-emit-module", "-module-name", module,
                     "-emit-module-path", str(work / (module + ".swiftmodule")),
                     *[str(ROOT / "Sources" / (name + ".swift")) for name in CORE], *framework_flags,
                     "-o", str(work / ("lib" + module + ".dylib"))])
        fixture = work / "synthetic.mp4"
        if needs_media:
            print("Creating a six-second synthetic media fixture…", flush=True)
            run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i",
                 "color=c=0x28404f:s=640x360:r=30:d=6", "-f", "lavfi", "-i",
                 "anullsrc=r=48000:cl=mono", "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-movflags", "+faststart", str(fixture)], timeout=60)
        for suite in suites:
            print(f"Building and running {suite}…", flush=True)
            # Tests retain their direct-compilation entry points. A temporary
            # @testable import permits sharing one compiled core for this runner.
            test_source = work / (suite + ".swift")
            test_source.write_text("@testable import " + module + "\n" + (ROOT / "Tests" / (suite + ".swift")).read_text())
            binary = work / suite
            run(swift + [str(test_source), "-I", str(work), "-L", str(work), "-l" + module,
                         "-Xlinker", "-rpath", "-Xlinker", "@executable_path", *framework_flags,
                         "-o", str(binary)])
            env = os.environ.copy()
            env["JINGDU_LIBRARY_DIRECTORY"] = str(work / ("library-" + suite))
            command = [str(binary)] + ([str(fixture)] if suite in MEDIA_SUITES else [])
            output = run(command, env=env, timeout=120)
            if output.strip():
                print(output.strip(), flush=True)
        print(f"PASS: {len(suites)} offline suites in {time.monotonic() - started:.1f}s; temporary outputs removed.", flush=True)


if __name__ == "__main__":
    main()
