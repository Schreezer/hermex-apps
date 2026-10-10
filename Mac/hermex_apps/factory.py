"""The app factory: scaffold an app from the template, then build it into an
IPA the phone installs. Hermes writes the code in between (see the
hermex-app-factory skill).

Each build step is recorded as a "build" event so the phone can show progress
(BUILD_SPEC §3.5); the build card itself is build step 7.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Any, Callable

from . import appapi, store
from .store import AppsError

MAC_DIR = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = MAC_DIR / "template"
TEXT_SUFFIXES = {".swift", ".yml", ".py", ".json", ".md", ".plist"}
HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


def appkit_path() -> Path:
    raw = os.environ.get("HERMEX_APPKIT_PATH", "").strip()
    return Path(raw).expanduser() if raw else MAC_DIR.parent / "Packages" / "HermexAppKit"


def platform() -> str:
    value = os.environ.get("HERMEX_APPS_PLATFORM", "device").strip() or "device"
    if value not in ("device", "simulator"):
        raise AppsError("HERMEX_APPS_PLATFORM must be device or simulator.")
    return value


def derived_data(app_id: str) -> Path:
    raw = os.environ.get("HERMEX_APPS_DERIVED_DATA", "").strip()
    root = Path(raw).expanduser() if raw else store.home() / "DerivedData"
    return root / app_id


# ── Scaffold ─────────────────────────────────────────────────────────────────

def create(app_id: str, name: str, tagline: str, summary: str, symbol: str,
           color: str, ink: str, routes: list[str], origin: str | None = None) -> dict[str, Any]:
    store.check_id(app_id)
    folder = store.app_dir(app_id)
    if (folder / "app.json").exists():
        raise AppsError(f"{app_id} already exists. Change it with apps_build, or pick another id.", status=409)
    _check_look(color, ink)
    name = name.strip()
    if not name:
        raise AppsError("The app needs a name.")

    target = store.target_name(name, app_id)
    values = {
        "__APP_ID__": app_id,
        "__APP_NAME__": name,
        "__TARGET__": target,
        "__BUNDLE_ID__": store.bundle_id(app_id),
        "__TOOL_PREFIX__": store.tool_prefix(app_id),
        "__HERMEXAPPKIT__": str(appkit_path()),
    }
    folder.mkdir(parents=True, exist_ok=True)
    for source in sorted(TEMPLATE_DIR.rglob("*")):
        if source.is_dir() or source.name.startswith(".") or "__pycache__" in source.parts:
            continue
        dest = folder / source.relative_to(TEMPLATE_DIR)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix in TEXT_SUFFIXES:
            text = source.read_text()
            for key, value in values.items():
                text = text.replace(key, value)
            dest.write_text(text)
        else:
            shutil.copy2(source, dest)

    stamp = store.now_iso()
    store.write_record({
        "id": app_id,
        "name": name,
        "tagline": tagline.strip(),
        "summary": summary.strip(),
        "bundle_id": store.bundle_id(app_id),
        "target": target,
        "symbol": symbol.strip() or "app.fill",
        "color": color.upper(),
        "ink": ink.upper(),
        "routes": routes,
        "origin": origin,
        "version": 0,
        "created_at": stamp,
        "built_at": None,
        "updated_at": stamp,
        "versions": [],
    })
    return {
        "app_id": app_id,
        "folder": str(folder),
        "swift_sources": str(folder / "project" / "App"),
        "server": str(folder / "server.py"),
        "tool_prefix": store.tool_prefix(app_id),
        "files": sorted(str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file()),
    }


def set_info(app_id: str, **fields: Any) -> dict[str, Any]:
    record = store.read_record(app_id)
    allowed = {"name", "tagline", "summary", "symbol", "color", "ink", "routes", "origin"}
    changes = {k: v for k, v in fields.items() if k in allowed and v is not None}
    _check_look(changes.get("color", record["color"]), changes.get("ink", record["ink"]))
    for key in ("color", "ink"):
        if key in changes:
            changes[key] = changes[key].upper()
    record.update(changes)
    record["updated_at"] = store.now_iso()
    store.write_record(record)
    return store.public_record(app_id)


def _check_look(color: str, ink: str) -> None:
    for label, value in (("color", color), ("ink", ink)):
        if not isinstance(value, str) or not HEX_RE.match(value):
            raise AppsError(f"{label} must be a hex color like #FF7A45.")


# ── Build ────────────────────────────────────────────────────────────────────

Progress = Callable[[str, str, str], None]


def build(app_id: str, change: str, reason: str | None = None, progress: Progress | None = None) -> dict[str, Any]:
    """Checks the API, builds, packages and publishes the next version."""
    record = store.read_record(app_id)
    folder = store.app_dir(app_id)
    version = int(record.get("version", 0)) + 1
    is_new = version == 1

    def step(name: str, state: str, detail: str = "") -> None:
        store.emit("build", app_id, step=name, state=state, detail=detail, version=version, is_new=is_new)
        if progress:
            progress(name, state, detail)

    with open(folder / ".build.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise AppsError(f"{app_id} is already building.", status=409)

        cancel_flag = folder / ".cancel"
        cancel_flag.unlink(missing_ok=True)

        step("check", "running", "Checking the app's API")
        try:
            tools = appapi.load(app_id).tools
        except AppsError as error:
            step("check", "failed", str(error))
            raise
        step("check", "done", f"{len(tools)} tools")

        step("build", "running", "Compiling with Xcode")
        try:
            app_bundle = _xcodebuild(app_id, record["target"], version, cancel_flag)
        except AppsError as error:
            step("build", "cancelled" if error.status == 499 else "failed", str(error).splitlines()[0])
            raise
        finally:
            cancel_flag.unlink(missing_ok=True)
        step("build", "done", "")

        step("package", "running", "Packaging the IPA")
        info = _package(app_id, app_bundle, version)
        step("package", "done", f"{info['size'] // 1024} KB")

        stamp = store.now_iso()
        record = store.read_record(app_id)
        record["version"] = version
        record["built_at"] = record.get("built_at") or stamp
        record["updated_at"] = stamp
        record.setdefault("versions", []).append(
            {"number": version, "change": change.strip() or "Update", "reason": reason, "at": stamp}
        )
        store.write_record(record)
        store.emit("ready", app_id, version=version, is_new=is_new, name=record["name"])
        if progress:
            progress("ready", "done", f"v{version}")
    return store.public_record(app_id)


def request_cancel(app_id: str) -> None:
    """Stops the app's running build (the user tapped Cancel build)."""
    folder = store.app_dir(app_id)
    store.read_record(app_id)
    (folder / ".cancel").touch()


def _xcodebuild(app_id: str, target: str, version: int, cancel_flag: Path) -> Path:
    project_dir = store.app_dir(app_id) / "project"
    log_path = store.app_dir(app_id) / "build.log"
    derived = derived_data(app_id)
    sim = platform() == "simulator"
    sdk = "iphonesimulator" if sim else "iphoneos"
    destination = "generic/platform=iOS Simulator" if sim else "generic/platform=iOS"

    commands = [
        ["xcodegen", "generate", "--quiet", "--spec", str(project_dir / "project.yml"), "--project", str(project_dir)],
        [
            "xcodebuild", "-quiet",
            "-project", str(project_dir / f"{target}.xcodeproj"),
            "-scheme", target,
            "-configuration", "Release",
            "-sdk", sdk,
            "-destination", destination,
            "-derivedDataPath", str(derived),
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO",
            f"CURRENT_PROJECT_VERSION={version}",
            f"MARKETING_VERSION={version}",
            "build",
        ],
    ]
    with open(log_path, "w") as log:
        for command in commands:
            log.write("$ " + " ".join(command) + "\n")
            log.flush()
            output = _run(command, cancel_flag)
            log.write(output.text)
            if output.returncode != 0:
                raise AppsError(_build_errors(output.text, project_dir) + f"\nFull log: {log_path}", status=422)

    products = derived / "Build" / "Products" / f"Release-{sdk}"
    bundles = sorted(products.glob("*.app"))
    if not bundles:
        raise AppsError(f"The build finished without an app. Full log: {log_path}", status=500)
    return bundles[0]


class _Output:
    def __init__(self, returncode: int, text: str):
        self.returncode = returncode
        self.text = text


def _run(command: list[str], cancel_flag: Path, timeout: float = 900) -> _Output:
    """Runs a build command, stopping it if the user cancels or it runs too long."""
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except FileNotFoundError:
        raise AppsError(f"{command[0]} is not installed on this Mac.", status=500)
    deadline = time.monotonic() + timeout
    while True:
        try:
            text, _ = process.communicate(timeout=0.5)
            return _Output(process.returncode, text)
        except subprocess.TimeoutExpired:
            if cancel_flag.exists() or time.monotonic() > deadline:
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                if cancel_flag.exists():
                    raise AppsError("The user cancelled this build. Don't build again unless they ask.", status=499)
                raise AppsError("The build took longer than 15 minutes and was stopped.", status=500)


def _build_errors(output: str, project_dir: Path) -> str:
    lines = []
    for line in output.splitlines():
        if re.search(r"\berror:", line) and line not in lines:
            lines.append(line.replace(str(project_dir) + "/", ""))
    if not lines:
        lines = output.strip().splitlines()[-15:]
    return "The build failed:\n" + "\n".join(lines[:30])


def _package(app_id: str, app_bundle: Path, version: int) -> dict[str, Any]:
    dist = store.app_dir(app_id) / "dist"
    dist.mkdir(exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(suffix=".ipa", dir=dist)
    os.close(fd)
    tmp = Path(tmp_name)
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app_bundle.rglob("*")):
            arcname = Path("Payload") / app_bundle.name / path.relative_to(app_bundle)
            if path.is_symlink():
                info = zipfile.ZipInfo(str(arcname))
                info.create_system = 3
                info.external_attr = 0o120777 << 16
                archive.writestr(info, os.readlink(path))
            elif path.is_file():
                archive.write(path, arcname)
    digest = hashlib.sha256(tmp.read_bytes()).hexdigest()
    info = {
        "version": version,
        "size": tmp.stat().st_size,
        "sha256": digest,
        "platform": platform(),
        "built_at": store.now_iso(),
    }
    tmp.replace(dist / "app.ipa")
    (dist / "ipa.json").write_text(json.dumps(info, indent=2) + "\n")
    return info
