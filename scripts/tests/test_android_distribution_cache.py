"""公开小文件 fixture；不会调用 Gradle、网络或凭据工具。"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "android_distribution_cache.py"
SPEC = importlib.util.spec_from_file_location("android_distribution_cache", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
cache = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cache
SPEC.loader.exec_module(cache)


class DistributionCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # macOS /var 是平台链接；fixture 使用真实 canonical 根。
        self.root = Path(self.temp.name).resolve()
        self.build = self.root / ".test/android-build"
        self.build.mkdir(parents=True)
        self.home = self.build / "gradle-home-current"
        self.home.mkdir(mode=0o700)
        self.data = b"public-distribution-fixture" * 40
        self.sha = hashlib.sha256(self.data).hexdigest()
        for attribute, value in (("DISTRIBUTION_BYTES", len(self.data)),
                                 ("DISTRIBUTION_SHA256", self.sha), ("CHUNK_BYTES", 31)):
            patcher = mock.patch.object(cache, attribute, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.properties = self.root / "android/gradle/wrapper/gradle-wrapper.properties"
        self.properties.parent.mkdir(parents=True)
        self.properties.write_text("distributionBase=GRADLE_USER_HOME\n"
                                   "distributionPath=wrapper/dists\n"
                                   "zipStoreBase=GRADLE_USER_HOME\n"
                                   "zipStorePath=wrapper/dists\n"
                                   "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-all.zip\n"
                                   f"distributionSha256Sum={self.sha}\n")

    def source(self, name: str = "gradle-home-source", data: bytes | None = None) -> Path:
        home = self.build / name
        home.mkdir(mode=0o700)
        parent = home.joinpath(*cache.RELATIVE_DIRECTORY)
        parent.mkdir(parents=True)
        file = parent / cache.ZIP_NAME
        file.write_bytes(self.data if data is None else data)
        return file

    def target(self) -> Path:
        return self.home.joinpath(*cache.RELATIVE_DIRECTORY, cache.ZIP_NAME)

    def seed(self) -> dict:
        return cache.seed_distribution_zip(self.root, self.home, time.monotonic() + 20)

    def rejected(self) -> None:
        with self.assertRaises(cache.DistributionCacheError) as error:
            self.seed()
        self.assertEqual(str(error.exception), cache.ERROR)
        self.assertNotIn(str(self.root), str(error.exception))

    def test_official_url_hash(self) -> None:
        self.assertEqual(cache._url_hash(cache.DISTRIBUTION_URL), "c2qonpi39x1mddn7hk5gh9iqj")

    def test_no_source_keeps_normal_download(self) -> None:
        self.assertEqual(self.seed(), {"reused": False})
        self.assertFalse(self.target().exists())

    def test_current_home_is_not_a_source(self) -> None:
        self.target().parent.mkdir(parents=True)
        self.target().write_bytes(self.data)
        self.assertEqual(self.seed(), {"reused": False})

    def test_only_zip_is_copied_and_source_is_preserved(self) -> None:
        source = self.source()
        (source.parent / "gradle-8.14").mkdir()
        (source.parent / (cache.ZIP_NAME + ".ok")).write_text("fixture")
        (source.parents[4] / "caches").mkdir()
        result = self.seed()
        self.assertEqual(result, {"reused": True, "source": "project-task-gradle-home",
                                  "bytes": len(self.data), "sha256": self.sha})
        self.assertEqual(source.read_bytes(), self.data)
        self.assertEqual(self.target().read_bytes(), self.data)
        self.assertNotEqual(source.stat().st_ino, self.target().stat().st_ino)
        self.assertEqual(self.target().stat().st_mode & 0o777, 0o600)
        self.assertEqual([p.name for p in self.target().parent.iterdir()], [cache.ZIP_NAME])
        self.assertFalse((self.home / "caches").exists())

    def test_bad_size(self) -> None:
        self.source(data=b"truncated")
        self.rejected()
        self.assertFalse(self.target().exists())

    def test_bad_sha(self) -> None:
        self.source(data=b"x" * len(self.data))
        self.rejected()
        self.assertFalse(self.target().exists())

    def test_properties_sha_must_match(self) -> None:
        self.source()
        self.properties.write_text(self.properties.read_text().replace(self.sha, "0" * 64))
        self.rejected()

    def test_properties_url_or_directory_drift(self) -> None:
        self.source()
        original = self.properties.read_text()
        for old, new in (("services.gradle.org", "example.invalid"),
                         ("wrapper/dists", "caches"), ("gradle-8.14-all.zip", "gradle-8.14-bin.zip")):
            self.properties.write_text(original.replace(old, new))
            self.rejected()

    def test_duplicate_property(self) -> None:
        self.source()
        with self.properties.open("a") as output:
            output.write(f"distributionSha256Sum={self.sha}\n")
        self.rejected()

    def test_source_file_link_rejected(self) -> None:
        source = self.source()
        replacement = source.with_name("public-original")
        source.rename(replacement)
        source.symlink_to(replacement.name)
        self.rejected()

    def test_source_hardlink_rejected(self) -> None:
        source = self.source()
        os.link(source, source.with_name("public-link"))
        self.rejected()

    def test_source_home_link_rejected(self) -> None:
        source = self.source()
        old = source.parents[4]
        renamed = self.build / "public-original-home"
        old.rename(renamed)
        old.symlink_to(renamed.name)
        self.rejected()

    def test_target_home_link_rejected(self) -> None:
        self.source()
        renamed = self.build / "public-target"
        self.home.rename(renamed)
        self.home.symlink_to(renamed.name)
        self.rejected()

    def test_target_home_permissions(self) -> None:
        self.source()
        self.home.chmod(0o755)
        self.rejected()

    def test_source_permissions(self) -> None:
        source = self.source()
        source.chmod(0o666)
        self.rejected()

    def test_wrong_uid(self) -> None:
        self.source()
        with mock.patch.object(cache.os, "getuid", return_value=os.getuid() + 1):
            self.rejected()

    def test_target_outside_owned_scope(self) -> None:
        with self.assertRaises(cache.DistributionCacheError):
            cache.seed_distribution_zip(self.root, self.root / "other", time.monotonic() + 20)

    def test_existing_target_is_never_overwritten(self) -> None:
        self.source()
        self.target().parent.mkdir(parents=True)
        self.target().write_bytes(b"keep-existing")
        self.rejected()
        self.assertEqual(self.target().read_bytes(), b"keep-existing")

    def test_multiple_sources_select_lexical_first_deterministically(self) -> None:
        self.source("gradle-home-z")
        first = self.source("gradle-home-a")
        original = cache._copy
        seen = []
        def record(source, target, end):
            seen.append(os.fstat(source).st_ino)
            return original(source, target, end)
        with mock.patch.object(cache, "_copy", side_effect=record):
            self.assertTrue(self.seed()["reused"])
        self.assertEqual(seen, [first.stat().st_ino])

    def test_invalid_selected_source_does_not_fallback(self) -> None:
        self.source("gradle-home-a", data=b"x" * len(self.data))
        self.source("gradle-home-z")
        original = cache._copy
        with mock.patch.object(cache, "_copy", wraps=original) as copy:
            self.rejected()
        self.assertEqual(copy.call_count, 1)
        self.assertFalse(self.target().exists())

    def test_discovery_count_bounded(self) -> None:
        self.source()
        with mock.patch.object(cache, "MAX_ENTRIES", 1):
            self.rejected()

    def test_source_changed_after_copy(self) -> None:
        source = self.source()
        original = cache._copy
        def changed(*args):
            result = original(*args)
            source.write_bytes(b"x" * len(self.data))
            return result
        with mock.patch.object(cache, "_copy", side_effect=changed):
            self.rejected()
        self.assertFalse(self.target().exists())

    def test_source_parent_replaced_after_copy(self) -> None:
        source = self.source()
        original = cache._copy
        def replaced(*args):
            result = original(*args)
            parent = source.parent
            parent.rename(parent.with_name("old-directory"))
            parent.mkdir()
            (parent / cache.ZIP_NAME).write_bytes(self.data)
            return result
        with mock.patch.object(cache, "_copy", side_effect=replaced):
            self.rejected()
        self.assertFalse(self.target().exists())

    def test_target_bytes_changed_after_copy_are_rejected(self) -> None:
        self.source()
        original = cache._copy
        def changed(source, target, end):
            result = original(source, target, end)
            os.lseek(target, 0, os.SEEK_SET)
            os.write(target, b"x" * len(self.data))
            return result
        with mock.patch.object(cache, "_copy", side_effect=changed):
            self.rejected()
        self.assertFalse(self.target().exists())

    def test_target_parent_replaced_during_copy_is_rejected(self) -> None:
        self.source()
        original = cache._copy
        def replaced(source, target, end):
            result = original(source, target, end)
            parent = self.target().parent
            parent.rename(parent.with_name("old-target-directory"))
            parent.mkdir()
            return result
        with mock.patch.object(cache, "_copy", side_effect=replaced):
            self.rejected()
        self.assertFalse(self.target().exists())

    def test_properties_symlink_rejected(self) -> None:
        self.source()
        original = self.properties.with_name("public-properties")
        self.properties.rename(original)
        self.properties.symlink_to(original.name)
        self.rejected()

    def test_short_write_never_publishes(self) -> None:
        self.source()
        original = cache.os.write
        def short(fd, data):
            return original(fd, data[:-1])
        with mock.patch.object(cache.os, "write", side_effect=short):
            self.rejected()
        self.assertFalse(self.target().exists())
        self.assertFalse(list(self.target().parent.glob(".bettbox-distribution-*")))

    def test_written_bytes_are_independently_checked(self) -> None:
        self.source()
        original = cache.os.write
        def corrupt(fd, data):
            return original(fd, b"x" * len(data))
        with mock.patch.object(cache.os, "write", side_effect=corrupt):
            self.rejected()
        self.assertFalse(self.target().exists())

    def test_post_publish_fsync_failure_rolls_back_owned_zip(self) -> None:
        self.source()
        original = cache.os.fsync
        calls = 0
        def failing(fd):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("fixture secret URL must not escape")
            return original(fd)
        with mock.patch.object(cache.os, "fsync", side_effect=failing):
            self.rejected()
        self.assertFalse(self.target().exists())

    def test_atomic_publish_conflict_preserves_external_file(self) -> None:
        self.source()
        def conflict(*args, **kwargs):
            self.target().write_bytes(b"external-owner")
            raise FileExistsError("fixture secret")
        with mock.patch.object(cache.os, "link", side_effect=conflict):
            self.rejected()
        self.assertEqual(self.target().read_bytes(), b"external-owner")

    def test_expired_parent_deadline(self) -> None:
        with self.assertRaises(cache.DistributionCacheError):
            cache.seed_distribution_zip(self.root, self.home, time.monotonic() - 1)

    def test_nonfinite_deadline(self) -> None:
        for deadline in (float("nan"), float("inf")):
            with self.assertRaises(cache.DistributionCacheError):
                cache.seed_distribution_zip(self.root, self.home, deadline)

    def test_copy_phase_cannot_extend_120_second_cap(self) -> None:
        self.source()
        original = cache._copy
        def expired(source, target, end):
            self.assertLessEqual(end, 1120)
            with mock.patch.object(cache.time, "monotonic", return_value=1121):
                original(source, target, end)
        with mock.patch.object(cache.time, "monotonic", return_value=1000), \
                mock.patch.object(cache, "_copy", side_effect=expired):
            with self.assertRaises(cache.DistributionCacheError):
                cache.seed_distribution_zip(self.root, self.home, 99999)
        self.assertFalse(self.target().exists())


if __name__ == "__main__":
    unittest.main()
