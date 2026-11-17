#!/usr/bin/env python3
"""Install reset-rune's verified Codex runtime without changing global Codex.

INPUT: The repository's supported version and a pinned official release archive.
OUTPUT: A private, versioned executable and an integrity receipt; no service changes.
POS: Opt-in maintenance utility; see native/README.md for service configuration.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.153.0"
ASSETS = {
    "arm64": ("aarch64-apple-darwin", "8cdecd0b8ebe23f20eb373010fd91e9517977e840b68941ef6a646b409cb32e1"),
    "x64": ("x86_64-apple-darwin", "668309c7d7cc1ebee5f9b4485739f92fd5556b0805bd9f49a3479302b5f68adc"),
}
MAX_ARCHIVE_BYTES = 250 * 1024 * 1024
MAX_BINARY_BYTES = 400 * 1024 * 1024


class InstallError(Exception):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_supported_version(source: Path = ROOT / "native/Sources/CodexTransport/CodexSource.swift") -> None:
    match = re.search(r'^public let baselineCodexVersion = "([^"]+)"$', source.read_text(), re.MULTILINE)
    if match is None or match.group(1) != VERSION:
        raise InstallError("The transport version differs from the verified installer manifest; update and verify both first.")


def private_directory(path: Path) -> None:
    if os.path.lexists(path):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise InstallError(f"Refusing an unexpected directory: {path}")
    else:
        path.mkdir(parents=True, mode=0o700)


def download_archive(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "reset-rune-runtime-installer"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("xb") as output:
        received = 0
        while chunk := response.read(1024 * 1024):
            received += len(chunk)
            if received > MAX_ARCHIVE_BYTES:
                raise InstallError("Official archive exceeded the download limit.")
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())


def extract_binary(archive: Path, destination: Path, member_name: str) -> None:
    # Never extract arbitrary paths, links, directories, or additional archive entries.
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if len(members) != 1 or members[0].name != member_name:
            raise InstallError("Unexpected contents in the official runtime archive.")
        member = members[0]
        if not member.isfile() or not 0 < member.size <= MAX_BINARY_BYTES:
            raise InstallError("The runtime archive member is not a bounded regular file.")
        source = bundle.extractfile(member)
        if source is None:
            raise InstallError("The runtime archive has no executable contents.")
        with source, destination.open("xb") as output:
            remaining = member.size
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise InstallError("The runtime archive is truncated.")
                output.write(chunk)
                remaining -= len(chunk)
            output.flush()
            os.fsync(output.fileno())
    destination.chmod(0o700)


def check_executable_version(executable: Path) -> None:
    # Version probing cannot discover the user's login, config, or home directory.
    with tempfile.TemporaryDirectory(prefix="reset-rune-codex-version-") as directory:
        isolated = Path(directory)
        home, codex_home = isolated / "home", isolated / "codex"
        home.mkdir(mode=0o700)
        codex_home.mkdir(mode=0o700)
        result = subprocess.run(
            [str(executable), "--version"], cwd=isolated,
            env={"HOME": str(home), "CODEX_HOME": str(codex_home), "PATH": "/usr/bin:/bin",
                 "TMPDIR": str(isolated)},
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False,
        )
        if result.returncode != 0 or result.stdout.strip() != f"codex-cli {VERSION}".encode():
            raise InstallError("The installed executable did not report the pinned compatible version.")


def existing_runtime(directory: Path, target: str, archive_hash: str, url: str) -> Path:
    executable, receipt_path = directory / "codex", directory / "receipt.json"
    try:
        for path in (directory, executable, receipt_path):
            info = path.lstat()
            is_directory = path == directory
            correct_type = stat.S_ISDIR(info.st_mode) if is_directory else stat.S_ISREG(info.st_mode)
            forbidden_permissions = 0o077 if is_directory else 0o022
            if not correct_type or info.st_uid != os.getuid() or info.st_mode & forbidden_permissions:
                raise InstallError(f"Refusing an insecure existing runtime path: {path}")
        receipt = json.loads(receipt_path.read_text())
        expected = {"version": VERSION, "target": target, "archiveSha256": archive_hash, "source": url}
        if not directory.is_dir() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise InstallError("Existing runtime is incomplete; it has been left untouched.")
        if any(receipt.get(key) != value for key, value in expected.items()) or receipt.get("binarySha256") != sha256(executable):
            raise InstallError("Existing runtime failed its integrity receipt; it has been left untouched.")
    except (OSError, ValueError, AttributeError) as error:
        raise InstallError("Existing runtime has no valid integrity receipt; it has been left untouched.") from error
    check_executable_version(executable)
    return executable


def install_runtime(data_dir: Path, arch: str, *, archive_path: Path | None = None, downloader=download_archive) -> Path:
    check_supported_version()
    target, archive_hash = ASSETS[arch]
    url = f"https://github.com/openai/codex/releases/download/rust-v{VERSION}/codex-{target}.tar.gz"
    private_directory(data_dir)
    root = data_dir / "codex-runtime"
    version_directory = root / VERSION
    private_directory(root)
    private_directory(version_directory)
    destination = version_directory / target
    if os.path.lexists(destination):
        return existing_runtime(destination, target, archive_hash, url)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=version_directory) as temporary:
        staging = Path(temporary)
        archive = staging / "codex.tar.gz"
        if archive_path is None:
            downloader(url, archive)
        else:
            if not archive_path.is_file() or archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
                raise InstallError("The supplied archive is not a bounded regular file.")
            shutil.copyfile(archive_path, archive)
        if archive.stat().st_size > MAX_ARCHIVE_BYTES or sha256(archive) != archive_hash:
            raise InstallError("Official runtime archive SHA-256 mismatch; nothing was installed.")
        candidate = staging / "runtime"
        candidate.mkdir(mode=0o700)
        executable = candidate / "codex"
        extract_binary(archive, executable, f"codex-{target}")
        check_executable_version(executable)
        receipt = {"version": VERSION, "target": target, "archiveSha256": archive_hash,
                   "source": url, "binarySha256": sha256(executable)}
        receipt_file = candidate / "receipt.json"
        with receipt_file.open("x") as output:
            json.dump(receipt, output, sort_keys=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        receipt_file.chmod(0o600)
        # rename publishes the complete directory together. An existing nonempty
        # installation is never replaced, including a concurrent successful install.
        try:
            candidate.rename(destination)
        except OSError:
            if os.path.lexists(destination):
                return existing_runtime(destination, target, archive_hash, url)
            raise
    return destination / "codex"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path.home() / "Library/Application Support/Bottled Reset Rune")
    parser.add_argument("--arch", choices=ASSETS, help="Defaults to the architecture of this Mac.")
    parser.add_argument("--archive", type=Path, help="Use a previously downloaded official archive; the same pinned SHA-256 check applies.")
    args = parser.parse_args()
    arch = args.arch or {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64"}.get(platform.machine())
    if platform.system() != "Darwin" or arch is None:
        parser.error("This installer supports macOS arm64 and x64 only.")
    try:
        executable = install_runtime(args.data_dir.expanduser().absolute(), arch, archive_path=args.archive)
    except (InstallError, OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        print(f"Codex runtime installation failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified Codex CLI {VERSION}: {executable}")
    print("Configure only reset-rune's service environment with RESET_RUNE_CODEX_PATH set to this path.")
    print("No service, global Codex, login, or automatic-use setting was changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
