#!/usr/bin/env python3
"""Prepare a private signing identity, then explicitly trust/sign Jingdu.

No trust change happens in prepare or sign. See LOCAL-SIGNING.md before using
trust-and-sign: it deliberately changes a narrowly scoped USER trust entry.
Only public Security.framework APIs and Apple's codesign tool perform keychain
and signing operations. No password is placed in argv or printed.
"""

import argparse
import contextlib
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile
import uuid


BUNDLE_ID = "local.jingdu.studio"
DEFAULT_DIRECTORY = Path.home() / "Library/Application Support/Jingdu/BuildSigning"
SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
OPENSSL = "/usr/bin/openssl"
STATE_NAME = "identity.json"
CERT_NAME = "certificate.der"
KEYCHAIN_NAME = "signing.keychain-db"


class SigningError(Exception):
    pass


def run(command, label, *, timeout=60, public_errors=False):
    """Arguments never contain secrets; private tool output is not surfaced."""
    try:
        result = subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SigningError(f"{label}超时；已停止，没有更改访问范围。") from None
    if result.returncode:
        detail = ""
        if public_errors:
            detail = ": " + result.stderr.decode("utf-8", errors="replace").strip()[:2000]
        raise SigningError(f"{label}失败（退出码 {result.returncode}）{detail}")
    return result.stdout


def check_private(path, *, directory=False):
    info = path.lstat()
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(info.st_mode) or info.st_uid != os.getuid():
        raise SigningError(f"签名路径不是当前用户拥有的普通{'目录' if directory else '文件'}：{path}")
    if stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise SigningError(f"签名路径权限应为 {'700' if directory else '600'}：{path}")
    if not directory and info.st_nlink != 1:
        raise SigningError(f"签名文件不允许硬链接：{path}")


def prepare_directory(path):
    # Do not follow symlinks into a different signing store. Existing parents
    # are left unchanged; only newly created directories receive mode 700.
    pending = []
    current = path
    while not current.exists():
        if current.is_symlink():
            raise SigningError("签名目录不能是符号链接。")
        pending.append(current)
        current = current.parent
    for parent in [current, *current.parents]:
        system_alias = str(parent) in ("/tmp", "/var") and parent.resolve() == Path("/private") / parent.name
        if parent.is_symlink() and not system_alias:
            raise SigningError("签名目录的父路径不能是符号链接。")
    for directory in reversed(pending):
        directory.mkdir(mode=0o700)
    check_private(path, directory=True)


@contextlib.contextmanager
def store_lock(directory):
    lock_path = directory / "build.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        check_private(lock_path)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SigningError("另一个镜读签名操作正在进行。") from None
        yield
    finally:
        os.close(descriptor)


def write_state(directory, state):
    descriptor, temporary = tempfile.mkstemp(prefix=".identity-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(state, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / STATE_NAME)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_state(directory):
    for name in (STATE_NAME, CERT_NAME, KEYCHAIN_NAME):
        if not (directory / name).exists():
            raise SigningError("签名材料不完整；为保留原身份，脚本不会自动重新生成证书。")
        check_private(directory / name)
    try:
        state = json.loads((directory / STATE_NAME).read_text(encoding="utf-8"))
    except (ValueError, UnicodeError):
        raise SigningError("签名状态文件无法读取；未显示文件内容。") from None
    certificate = (directory / CERT_NAME).read_bytes()
    if (not isinstance(state, dict) or state.get("version") != 1 or state.get("bundleIdentifier") != BUNDLE_ID
            or state.get("certificateSHA1") != hashlib.sha1(certificate).hexdigest().upper()
            or state.get("certificateSHA256") != hashlib.sha256(certificate).hexdigest().upper()
            or not isinstance(state.get("keychainPassword"), str)
            or len(state["keychainPassword"]) < 40
            or not isinstance(state.get("trustConfigured"), bool)):
        raise SigningError("签名状态与固定证书不匹配；已停止，不会替换原身份。")
    return state


class ImportParameters(ctypes.Structure):
    # Public SecItemImportExportKeyParameters layout from SecImportExport.h.
    _fields_ = [("version", ctypes.c_uint32), ("flags", ctypes.c_uint32),
                ("passphrase", ctypes.c_void_p), ("alertTitle", ctypes.c_void_p),
                ("alertPrompt", ctypes.c_void_p), ("accessRef", ctypes.c_void_p),
                ("keyUsage", ctypes.c_void_p), ("keyAttributes", ctypes.c_void_p)]


class Keychain:
    """Use an explicitly named private keychain; never change search/defaults."""

    def __init__(self):
        self.security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.owned = []
        p, u32, b = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_ubyte
        out = ctypes.POINTER(p)
        self.bind(self.cf, "CFRelease", [p], None)
        self.bind(self.cf, "CFStringCreateWithCString", [p, ctypes.c_char_p, u32], p)
        self.bind(self.cf, "CFDataCreate", [p, p, ctypes.c_long], p)
        self.bind(self.cf, "CFArrayCreate", [p, out, ctypes.c_long, p], p)
        self.bind(self.security, "SecKeychainSetUserInteractionAllowed", [b])
        self.bind(self.security, "SecKeychainCreate", [ctypes.c_char_p, u32, p, b, p, out])
        self.bind(self.security, "SecKeychainOpen", [ctypes.c_char_p, out])
        self.bind(self.security, "SecKeychainUnlock", [p, u32, p, b])
        self.bind(self.security, "SecKeychainLock", [p])
        self.bind(self.security, "SecTrustedApplicationCreateFromPath", [ctypes.c_char_p, out])
        self.bind(self.security, "SecAccessCreate", [p, p, out])
        self.bind(self.security, "SecItemImport", [p, p, ctypes.POINTER(u32),
                  ctypes.POINTER(u32), u32, ctypes.POINTER(ImportParameters), p, out])
        self.check(self.security.SecKeychainSetUserInteractionAllowed(False), "禁止准备阶段弹出授权框")

    @staticmethod
    def bind(library, name, arguments, result=ctypes.c_int32):
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, result

    @staticmethod
    def check(status, label):
        if status:
            raise SigningError(f"{label}失败（Security 状态码 {status}）；未扩大访问范围。")

    def keep(self, reference):
        value = reference.value if isinstance(reference, ctypes.c_void_p) else reference
        if not value:
            raise SigningError("无法创建签名钥匙串对象。")
        self.owned.append(value)
        return value

    def string(self, value):
        return self.keep(self.cf.CFStringCreateWithCString(None, value.encode("utf-8"), 0x08000100))

    def array(self, values):
        # Every member is either an immortal framework constant or retained in
        # self.owned until after the array is released. No unowned member escapes.
        array = (ctypes.c_void_p * len(values))(*values)
        return self.keep(self.cf.CFArrayCreate(None, array, len(values), None))

    def constant(self, name):
        return ctypes.c_void_p.in_dll(self.security, name).value

    def create(self, path, password):
        reference = ctypes.c_void_p()
        secret = password.encode("utf-8")
        self.check(self.security.SecKeychainCreate(os.fsencode(path), len(secret), secret,
                   False, None, ctypes.byref(reference)), "创建专用签名钥匙串")
        return self.keep(reference)

    def unlock(self, path, password):
        reference = ctypes.c_void_p()
        self.check(self.security.SecKeychainOpen(os.fsencode(path), ctypes.byref(reference)),
                   "打开专用签名钥匙串")
        keychain = self.keep(reference)
        secret = password.encode("utf-8")
        self.check(self.security.SecKeychainUnlock(keychain, len(secret), secret, True),
                   "解锁专用签名钥匙串")
        return keychain

    def import_identity(self, keychain, pkcs12, passphrase):
        trusted = ctypes.c_void_p()
        self.check(self.security.SecTrustedApplicationCreateFromPath(
            os.fsencode(CODESIGN), ctypes.byref(trusted)), "限定签名私钥使用程序")
        trusted_array = self.array([self.keep(trusted)])
        access = ctypes.c_void_p()
        self.check(self.security.SecAccessCreate(self.string("Jingdu local build signing key"),
                   trusted_array, ctypes.byref(access)), "创建签名私钥访问控制")
        access_ref = self.keep(access)
        parameters = ImportParameters(
            version=0, flags=1,  # kSecKeyImportOnlyOne; never kSecKeyNoAccessControl.
            passphrase=self.string(passphrase), accessRef=access_ref,
            keyUsage=self.array([self.constant("kSecAttrCanSign")]),
            keyAttributes=self.array([self.constant("kSecAttrIsPermanent"),
                                      self.constant("kSecAttrIsSensitive")]))
        # Omit kSecAttrIsExtractable: the imported private key cannot be exported.
        data = self.keep(self.cf.CFDataCreate(None, pkcs12, len(pkcs12)))
        data_format, item_type = ctypes.c_uint32(12), ctypes.c_uint32(5)  # PKCS12, aggregate.
        self.check(self.security.SecItemImport(data, None, ctypes.byref(data_format),
                   ctypes.byref(item_type), 0, ctypes.byref(parameters), keychain, None),
                   "导入仅供 codesign 使用且不可导出的签名私钥")

    def lock(self, reference):
        self.check(self.security.SecKeychainLock(reference), "锁定专用签名钥匙串")

    def close(self):
        for reference in reversed(self.owned):
            self.cf.CFRelease(reference)
        self.owned.clear()


def keychain_preferences():
    return tuple(run([SECURITY, command, "-d", "user"], "读取钥匙串偏好")
                 for command in ("default-keychain", "list-keychains"))


def search_keychains():
    output = run([SECURITY, "list-keychains", "-d", "user"], "读取签名钥匙串查找范围")
    try:
        return shlex.split(output.decode("utf-8"))
    except (UnicodeError, ValueError):
        raise SigningError("无法读取钥匙串查找列表；未更改用户偏好。") from None


@contextlib.contextmanager
def signing_keychain_lookup(path):
    """Temporarily make the private identity discoverable to codesign.

    codesign requires search-list membership even with --keychain. This only
    changes identity lookup: private-key ACLs and the default keychain remain
    untouched. On exit, remove only the path this call added; do not overwrite
    unrelated changes the user made while signing was in progress.
    """
    canonical = path.resolve()

    def matches(entry):
        return Path(entry).expanduser().resolve() == canonical

    before = search_keychains()
    if any(matches(entry) for entry in before):
        yield
        return
    try:
        run([SECURITY, "list-keychains", "-d", "user", "-s", *before, str(path)],
            "临时加入专用签名钥匙串")
        yield
    finally:
        # Read again instead of blindly restoring `before`: preserve concurrent
        # additions, removals, and order changes of all unrelated keychains.
        current = search_keychains()
        remaining = [entry for entry in current if not matches(entry)]
        if remaining != current:
            run([SECURITY, "list-keychains", "-d", "user", "-s", *remaining],
                "撤回本次临时加入的签名钥匙串")


def prepare(directory):
    if (directory / STATE_NAME).exists():
        return load_state(directory)
    if set(path.name for path in directory.iterdir()) != {"build.lock"}:
        raise SigningError("目录包含未完成或未知签名材料；不会覆盖或自动更换身份。")
    before = keychain_preferences()
    bridge = Keychain()
    keychain = None
    try:
        password = secrets.token_urlsafe(48)
        with tempfile.TemporaryDirectory(prefix=".prepare-", dir=directory) as temporary:
            work = Path(temporary)
            passphrase = secrets.token_urlsafe(48)
            (work / "package-password").write_text(passphrase, encoding="utf-8")
            name = "Jingdu Local Build " + str(uuid.uuid4())
            run([OPENSSL, "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256",
                 "-days", "3650", "-subj", f"/CN={name}/", "-keyout", str(work / "key.pem"),
                 "-out", str(work / "certificate.pem"), "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                 "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                 "-addext", "extendedKeyUsage=codeSigning"], "生成本机签名证书")
            run([OPENSSL, "x509", "-in", str(work / "certificate.pem"), "-outform", "DER",
                 "-out", str(directory / CERT_NAME)], "保存固定签名证书")
            run([OPENSSL, "pkcs12", "-export", "-inkey", str(work / "key.pem"),
                 "-in", str(work / "certificate.pem"), "-out", str(work / "identity.p12"),
                 "-passout", "file:" + str(work / "package-password"),
                 "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
                "准备加密的临时签名包")
            # The PKCS12 compatibility cipher is only for this short-lived local
            # transfer; the final private key lives in the macOS keychain.
            keychain = bridge.create(directory / KEYCHAIN_NAME, password)
            bridge.import_identity(keychain, (work / "identity.p12").read_bytes(), passphrase)
            certificate = (directory / CERT_NAME).read_bytes()
            state = {"version": 1, "bundleIdentifier": BUNDLE_ID,
                     "certificateSHA1": hashlib.sha1(certificate).hexdigest().upper(),
                     "certificateSHA256": hashlib.sha256(certificate).hexdigest().upper(),
                     "keychainPassword": password, "trustConfigured": False,
                     "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
            for name in (CERT_NAME, KEYCHAIN_NAME):
                os.chmod(directory / name, 0o600)
            write_state(directory, state)
        return state
    finally:
        try:
            if keychain is not None:
                bridge.lock(keychain)
        finally:
            bridge.close()
        if keychain_preferences() != before:
            raise SigningError("钥匙串偏好在准备期间发生变化；未覆盖用户偏好，请先检查。")


def validate_app(app):
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise SigningError("请指定镜读 .app 的实际目录。")
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise SigningError("无法读取待签名应用的信息。") from None
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "Jingdu":
        raise SigningError("此脚本只签名标识为 local.jingdu.studio 的镜读应用。")
    if not (app / "Contents/MacOS/Jingdu").is_file():
        raise SigningError("镜读应用尚未构建完成。")


def requirement(state):
    return f'identifier "{BUNDLE_ID}" and certificate leaf = H"{state["certificateSHA1"]}"'


def trust_command(directory):
    # No -d: user domain only. BOTH constraints apply, so this grants neither
    # SSL trust nor trust to arbitrary applications evaluating the certificate.
    return [SECURITY, "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
            "-a", CODESIGN, "-k", str(directory / KEYCHAIN_NAME), str(directory / CERT_NAME)]


def sign(directory, state, app, *, establish_trust=False):
    validate_app(app)  # Reject another app before any trust mutation.
    if not establish_trust and not state["trustConfigured"]:
        raise SigningError("尚未建立本机签名信任；sign 不会自动修改信任设置。")
    bridge = Keychain()
    keychain = None
    try:
        keychain = bridge.unlock(directory / KEYCHAIN_NAME, state["keychainPassword"])
        if establish_trust:
            print("将仅在当前用户域，为该固定证书建立 codeSign 用途且仅限 /usr/bin/codesign 的信任。", flush=True)
            # Leave time for the user to complete macOS's one-time authorization.
            run(trust_command(directory), "建立限定用途的本机签名信任", timeout=300, public_errors=True)
        with signing_keychain_lookup(directory / KEYCHAIN_NAME):
            engine = app / "Contents/Resources/SubtitleEngine/whisper-cli"
            if engine.exists():
                if not engine.is_file() or engine.is_symlink() or not engine.resolve().is_relative_to(app.resolve()):
                    raise SigningError("字幕引擎必须是应用包内的普通文件。")
                run([CODESIGN, "--force", "--sign", state["certificateSHA1"], "--keychain",
                     str(directory / KEYCHAIN_NAME), "--identifier", BUNDLE_ID + ".subtitle-engine",
                     "--timestamp=none", str(engine)], "签名本地字幕引擎", public_errors=True)
            run([CODESIGN, "--force", "--sign", state["certificateSHA1"], "--keychain",
                 str(directory / KEYCHAIN_NAME), "--identifier", BUNDLE_ID, "--timestamp=none",
                 "--requirements", "=designated => " + requirement(state), str(app)],
                "固定身份签名", public_errors=True)
            run([CODESIGN, "--verify", "--deep", "--strict", "--verbose=2", "--test-requirement",
                 "=" + requirement(state), str(app)], "核验签名与固定身份", public_errors=True)
            # Validate the embedded certificate itself, not just a successful tool exit.
            with tempfile.TemporaryDirectory(prefix=".verify-", dir=directory) as temporary:
                prefix = str(Path(temporary) / "certificate-")
                run([CODESIGN, "--display", "--extract-certificates=" + prefix, str(app)], "核验签名证书")
                if Path(prefix + "0").read_bytes() != (directory / CERT_NAME).read_bytes():
                    raise SigningError("最终签名未使用固定证书；已停止。")
        if establish_trust:
            # A successful trust mutation alone does not prove usable signing.
            write_state(directory, dict(state, trustConfigured=True))
        print("镜读已使用固定的本机身份签名并通过验证。")
    finally:
        try:
            if keychain is not None:
                bridge.lock(keychain)
        finally:
            bridge.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_DIRECTORY,
                        help="私有签名目录；隔离验证可显式指定 /tmp 下的目录")
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("prepare", help="准备固定身份；不建立信任、不签名")
    for name, help_text in (("trust-and-sign", "显式建立限定用户信任，然后签名"),
                            ("sign", "只复用已有身份签名；不修改信任")):
        action = actions.add_parser(name, help=help_text)
        action.add_argument("app", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin" or os.getuid() == 0:
        raise SigningError("请在 macOS 中以当前普通用户运行；不要使用 sudo。")
    os.umask(0o077)
    directory = args.state_dir.expanduser().absolute()
    prepare_directory(directory)
    with store_lock(directory):
        if args.action == "prepare":
            state = prepare(directory)
            print(f"签名材料已准备并复用固定身份：{directory}")
            print("证书 SHA-1：" + state["certificateSHA1"])
            print("未建立任何证书信任；未修改默认钥匙串或搜索列表。")
        else:
            sign(directory, load_state(directory), args.app.expanduser().absolute(),
                 establish_trust=args.action == "trust-and-sign")


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError) as error:
        print(f"签名操作停止：{error}", file=sys.stderr)
        sys.exit(1)
