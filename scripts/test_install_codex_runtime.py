"""Synthetic installer checks; never download or discover a real Codex login."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("install_codex_runtime", Path(__file__).with_name("install-codex-runtime.py"))
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


def archive_bytes(name="codex-synthetic-target", *, kind=tarfile.REGTYPE, extra=None):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        member = tarfile.TarInfo(name)
        member.type = kind
        contents = b"synthetic executable; never run\n"
        if kind == tarfile.REGTYPE:
            member.size = len(contents)
        else:
            member.linkname = "/a-path-that-must-not-be-touched"
        archive.addfile(member, io.BytesIO(contents) if kind == tarfile.REGTYPE else None)
        if extra:
            second = tarfile.TarInfo(extra)
            second.size = 1
            archive.addfile(second, io.BytesIO(b"x"))
    return buffer.getvalue()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="reset-rune-installer-test-")
        self.root = Path(self.temporary.name)
        self.data = self.root / "isolated-data"
        self.archive = self.root / "runtime.tar.gz"
        self.contents = archive_bytes()
        self.archive.write_bytes(self.contents)
        self.hash = hashlib.sha256(self.contents).hexdigest()
        self.assets = mock.patch.object(installer, "ASSETS", {"arm64": ("synthetic-target", self.hash)})
        self.probe = mock.patch.object(installer, "check_executable_version")
        self.assets.start()
        self.mock_probe = self.probe.start()
        self.addCleanup(self.assets.stop)
        self.addCleanup(self.probe.stop)
        self.addCleanup(self.temporary.cleanup)

    def install(self):
        return installer.install_runtime(self.data, "arm64", archive_path=self.archive,
                                         downloader=mock.Mock(side_effect=AssertionError("Network access is forbidden in tests")))

    def test_install_and_reuse_with_integrity_receipt(self):
        executable = self.install()
        self.assertEqual(executable.read_bytes(), b"synthetic executable; never run\n")
        receipt = json.loads(executable.with_name("receipt.json").read_text())
        self.assertEqual(receipt["archiveSha256"], self.hash)
        self.assertEqual(receipt["binarySha256"], installer.sha256(executable))
        before = executable.stat().st_ino
        self.archive.unlink()
        self.assertEqual(self.install(), executable)
        self.assertEqual(executable.stat().st_ino, before)
        self.assertEqual(self.mock_probe.call_count, 2)

    def test_mismatched_archive_installs_nothing(self):
        self.archive.write_bytes(b"unexpected download")
        with self.assertRaisesRegex(installer.InstallError, "SHA-256 mismatch"):
            self.install()
        self.assertFalse((self.data / "codex-runtime" / installer.VERSION / "synthetic-target").exists())
        self.assertEqual(list((self.data / "codex-runtime" / installer.VERSION).iterdir()), [])
        self.mock_probe.assert_not_called()

    def test_existing_tampered_binary_is_not_overwritten(self):
        executable = self.install()
        executable.write_bytes(b"unrelated executable")
        with self.assertRaisesRegex(installer.InstallError, "integrity receipt"):
            self.install()
        self.assertEqual(executable.read_bytes(), b"unrelated executable")

    def test_existing_incomplete_directory_is_not_overwritten(self):
        destination = self.data / "codex-runtime" / installer.VERSION / "synthetic-target"
        for directory in (self.data, self.data / "codex-runtime", destination.parent, destination):
            installer.private_directory(directory)
        marker = destination / "unrelated.txt"
        marker.write_text("retain me")
        with self.assertRaisesRegex(installer.InstallError, "receipt"):
            self.install()
        self.assertEqual(marker.read_text(), "retain me")

    def test_insecure_root_and_intermediate_directories_are_rejected_without_changes(self):
        for directory in (self.data, self.data / "codex-runtime", self.data / "codex-runtime" / installer.VERSION):
            installer.private_directory(directory)
        for insecure in (self.data, self.data / "codex-runtime"):
            with self.subTest(path=insecure):
                insecure.chmod(0o777)
                try:
                    with self.assertRaisesRegex(installer.InstallError, "unexpected directory"):
                        self.install()
                    self.assertEqual(insecure.stat().st_mode & 0o777, 0o777)
                    self.assertFalse((self.data / "codex-runtime" / installer.VERSION / "synthetic-target").exists())
                finally:
                    insecure.chmod(0o700)

    def test_insecure_installed_runtime_paths_are_rejected_without_changes(self):
        executable = self.install()
        for insecure, unsafe_mode, original_mode in (
            (executable.parent, 0o755, 0o700),
            (executable, 0o722, 0o700),
            (executable.with_name("receipt.json"), 0o622, 0o600),
        ):
            with self.subTest(path=insecure):
                before = executable.read_bytes()
                insecure.chmod(unsafe_mode)
                try:
                    with self.assertRaisesRegex(installer.InstallError, "insecure existing runtime"):
                        self.install()
                    self.assertEqual(insecure.stat().st_mode & 0o777, unsafe_mode)
                    self.assertEqual(executable.read_bytes(), before)
                finally:
                    insecure.chmod(original_mode)

    def test_source_version_drift_rejects_before_writing(self):
        source = self.root / "CodexSource.swift"
        source.write_text('public let baselineCodexVersion = "99.0.0"\n')
        with self.assertRaisesRegex(installer.InstallError, "differs"):
            installer.check_supported_version(source)
        with mock.patch.object(installer, "check_supported_version", side_effect=installer.InstallError("version drift")):
            with self.assertRaisesRegex(installer.InstallError, "version drift"):
                self.install()
        self.assertFalse(self.data.exists())

    def test_archive_links_paths_duplicates_and_extra_files_are_rejected(self):
        for index, contents in enumerate([
            archive_bytes("../codex-synthetic-target"),
            archive_bytes("/codex-synthetic-target"),
            archive_bytes(kind=tarfile.SYMTYPE),
            archive_bytes(kind=tarfile.LNKTYPE),
            archive_bytes(extra="codex-synthetic-target"),
            archive_bytes(extra="unrelated"),
        ]):
            with self.subTest(index=index):
                self.archive.write_bytes(contents)
                output = self.root / f"must-not-exist-{index}"
                with self.assertRaises(installer.InstallError):
                    installer.extract_binary(self.archive, output, "codex-synthetic-target")
                self.assertFalse(output.exists())

    def test_version_probe_receives_only_isolated_directories(self):
        self.probe.stop()
        executable = self.root / "synthetic-codex"
        with mock.patch.object(installer.subprocess, "run") as process:
            process.return_value = mock.Mock(returncode=0, stdout=f"codex-cli {installer.VERSION}\n".encode())
            installer.check_executable_version(executable)
        arguments, keywords = process.call_args
        self.assertEqual(arguments[0], [str(executable), "--version"])
        environment = keywords["env"]
        self.assertEqual(set(environment), {"HOME", "CODEX_HOME", "PATH", "TMPDIR"})
        self.assertNotEqual(environment["HOME"], str(Path.home()))
        self.assertTrue(environment["CODEX_HOME"].startswith(keywords["cwd"].as_posix()))
        self.assertFalse(Path(environment["HOME"]).exists(), "Probe sandbox should be removed")


if __name__ == "__main__":
    unittest.main()
