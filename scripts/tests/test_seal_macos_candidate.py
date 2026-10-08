"""候选签名前检查真实文件结构及固定签名身份，错误不进入签名发布。"""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import plistlib
import contextlib
import io
import runpy
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import seal_macos_candidate as seal


class AdmissionTests(unittest.TestCase):
    def fixture(self, root):
        app = root / "Bettbox.app"
        binary = app / "Contents/MacOS/BettboxCoreSupervisor"
        manifest = app / "Contents/Resources/BettboxCoreSupervisorIdentity.json"
        binary.parent.mkdir(parents=True); manifest.parent.mkdir(parents=True)
        binary.write_bytes(b"public-helper")
        fields = {"schema": 1, "identifier": "com.appshub.bettbox.core.supervisor",
                  "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                  "cdhash": "a" * 40, "signingmode": "adhoc"}
        manifest.write_text(json.dumps(fields, sort_keys=True) + "\n")
        return app, binary, manifest, fields

    def signature(self, identifier):
        return SimpleNamespace(stderr=("Identifier=" + identifier + "\nCDHash=" + "a" * 40 +
                                       "\nSignature=adhoc\nTeamIdentifier=not set\n").encode())

    def test_expected_helper_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            app, _, _, fields = self.fixture(Path(directory))
            with patch.object(seal, "tool", return_value=self.signature(fields["identifier"])):
                self.assertEqual(seal.artifact(app, "BettboxCoreSupervisor", fields["identifier"]), fields)

    def test_core_signature_cannot_impersonate_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            app, _, _, fields = self.fixture(Path(directory))
            with patch.object(seal, "tool", return_value=self.signature("com.appshub.bettbox.core")):
                with self.assertRaisesRegex(RuntimeError, "签名ID"):
                    seal.artifact(app, "BettboxCoreSupervisor", fields["identifier"])

    def test_replaced_bytes_rejected_before_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            app, binary, _, fields = self.fixture(Path(directory))
            binary.write_bytes(b"replacement")
            with patch.object(seal, "tool") as tool:
                with self.assertRaises(RuntimeError): seal.artifact(app, "BettboxCoreSupervisor", fields["identifier"])
                tool.assert_not_called()

    def test_manifest_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, _, manifest, fields = self.fixture(Path(directory))
            saved = manifest.with_suffix(".saved"); manifest.rename(saved); manifest.symlink_to(saved)
            with patch.object(seal, "tool") as tool:
                with self.assertRaises(RuntimeError): seal.artifact(app, "BettboxCoreSupervisor", fields["identifier"])
                tool.assert_not_called()

    def test_bundle_link_must_stay_inside(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app, _, _, _ = self.fixture(root)
            outside = root / "outside"; outside.write_bytes(b"public")
            (app / "external").symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "越界"): seal.checked_tree(app)

    def source_bundle(self, root):
        source = root / seal.SOURCE
        parent = source.parent; parent.mkdir(parents=True)
        app, helper, manifest, fields = self.fixture(parent)
        self.assertEqual(app, source)
        core = helper.with_name("BettboxCore"); core.write_bytes(helper.read_bytes())
        core_fields = dict(fields, identifier="com.appshub.bettbox.core")
        manifest.with_name("BettboxCoreIdentity.json").write_text(json.dumps(core_fields, sort_keys=True) + "\n")
        helper.with_name("Bettbox").write_bytes(b"public-host")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.appshub.bettbox", "CFBundleExecutable": "Bettbox"}))
        return source

    def fake_signer(self, argv):
        path = argv[-1]
        identifier = "com.appshub.bettbox"
        if path.endswith("BettboxCoreSupervisor"): identifier += ".core.supervisor"
        elif path.endswith("BettboxCore"): identifier += ".core"
        return self.signature(identifier)

    def test_full_seal_never_follows_existing_marker_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_bundle(root)
            parent = (root / seal.DESTINATION).parent; parent.mkdir()
            outside = root / "public-outside"; outside.write_bytes(b"keep")
            (parent / "seal.json").symlink_to(outside)
            with patch.object(seal, "tool", side_effect=self.fake_signer):
                with self.assertRaises(RuntimeError): seal.seal(root)
            self.assertEqual(outside.read_bytes(), b"keep")

    def test_existing_marker_rejected_before_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_bundle(root)
            parent = (root / seal.DESTINATION).parent; parent.mkdir()
            marker = parent / "seal.json"; marker.write_text('{"passed":true}')
            with patch.object(seal, "tool") as tool:
                with self.assertRaises(RuntimeError): seal.seal(root)
                tool.assert_not_called()
            self.assertEqual(marker.read_text(), '{"passed":true}')

    def test_sign_failure_never_publishes_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_bundle(root)
            def fail(argv):
                if "--force" in argv: raise RuntimeError("公开签名失败")
                return self.fake_signer(argv)
            with patch.object(seal, "tool", side_effect=fail):
                with self.assertRaises(RuntimeError): seal.seal(root)
            self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_success_marker_matches_verified_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = self.source_bundle(root)
            original = (source / "Contents/MacOS/Bettbox").read_bytes()
            with patch.object(seal, "tool", side_effect=self.fake_signer): report = seal.seal(root)
            marker = json.loads(((root / seal.DESTINATION).parent / "seal.json").read_text())
            self.assertEqual(marker, report)
            self.assertTrue(marker["passed"])
            self.assertEqual(marker["signingmode"], "adhoc")
            self.assertEqual((source / "Contents/MacOS/Bettbox").read_bytes(), original)

    def test_probe_only_omits_restricted_entitlement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_bundle(root)
            with patch.object(seal, "tool", side_effect=self.fake_signer) as tool:
                report = seal.seal(root, seal.PROBE_DESTINATION)
            host_calls = [call.args[0] for call in tool.call_args_list
                          if "--identifier" in call.args[0]]
            self.assertEqual(len(host_calls), 1)
            self.assertNotIn("--entitlements", host_calls[0])
            self.assertEqual(report["entitlement_profile"], "probe-none")

    def test_arbitrary_candidate_destination_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_bundle(root)
            with patch.object(seal, "tool") as tool:
                with self.assertRaises(RuntimeError): seal.seal(root, Path("build/arbitrary.app"))
                tool.assert_not_called()

    def development_signer(self, identities=1, host_mode="apple-development",
                           team="PUBLIC1234", host_id="com.appshub.bettbox",
                           certificate_subject="CN=Apple Development: Public Fixture (PUBLICCN01),OU=PUBLIC1234",
                           certificate_hash="1" * 40, duplicate_cdhash=False,
                           authority="Apple Development: Public Fixture 0 (PUBLICCN01)"):
        # 仅公开虚拟证书与摘要；替身输出只供生产入口解析，不代表系统身份。
        calls = []
        def run(argv, input_data=None):
            calls.append(argv)
            if argv[0] == "/usr/bin/security" and "find-identity" in argv:
                lines = [f'  {index + 1}) {str(index + 1) * 40} "Apple Development: Public Fixture {index} (PUBLICCN01)"'
                         for index in range(identities)]
                output = "\n".join(lines + [f"     {identities} valid identities found\n"])
                return SimpleNamespace(stdout=output.encode(), stderr=b"", returncode=0)
            if argv[0] == "/usr/bin/security" and "find-certificate" in argv:
                return SimpleNamespace(stdout=b"-----BEGIN CERTIFICATE-----\nUFVCTElD\n-----END CERTIFICATE-----\n",
                                       stderr=b"", returncode=0)
            if argv[0] == "/usr/bin/openssl":
                self.assertIsInstance(input_data, bytes)
                digest = ":".join(certificate_hash[index:index + 2] for index in range(0, 40, 2))
                output = f"SHA1 Fingerprint={digest}\nsubject={certificate_subject}\n"
                return SimpleNamespace(stdout=output.encode(), stderr=b"", returncode=0)
            if "-d" in argv and argv[-1].endswith("Bettbox.app"):
                mode = ("Signature=adhoc\n" if host_mode == "adhoc" else
                        f"Authority={authority}\n"
                        "Authority=Apple Worldwide Developer Relations Certification Authority\n"
                        "Authority=Apple Root CA\n")
                output = f"Identifier={host_id}\nCDHash={'b' * 40}\n{mode}TeamIdentifier={team}\n"
                if duplicate_cdhash:
                    output += f"CDHash={'b' * 40}\n"
                return SimpleNamespace(stdout=b"", stderr=output.encode(), returncode=0)
            return self.fake_signer(argv)
        return run, calls

    def development_bundle(self, root):
        source = self.source_bundle(root)
        framework = source / "Contents/Frameworks/Public.framework"
        framework.mkdir(parents=True)
        (framework / "Public").write_bytes(b"\xcf\xfa\xed\xfe-public-framework")
        return source

    def test_development_missing_or_multiple_identity_rejected_before_copy_and_sign(self):
        for count in (0, 2):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.development_bundle(root)
                signer, calls = self.development_signer(identities=count)
                with patch.object(seal, "tool", side_effect=signer), patch.object(seal.shutil, "copytree") as copy:
                    with self.assertRaisesRegex(RuntimeError, "开发签名身份数量不符"):
                        seal.seal(root, signing_mode="apple-development")
                    copy.assert_not_called()
                self.assertTrue(any(call[0] == "/usr/bin/security" for call in calls))
                self.assertFalse(any("--force" in call for call in calls))
                self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_development_malformed_identity_output_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.development_bundle(root)
            result = SimpleNamespace(stdout=b'  1) BAD "Apple Development: Public Fixture (PUBLIC1234)"\n'
                                            b'     1 valid identities found\n', stderr=b"", returncode=0)
            with patch.object(seal, "tool", return_value=result), patch.object(seal.shutil, "copytree") as copy:
                with self.assertRaisesRegex(RuntimeError, "开发签名身份格式不符"):
                    seal.seal(root, signing_mode="apple-development")
                copy.assert_not_called()
            self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_development_host_mode_team_and_identifier_are_independently_verified(self):
        for fields in ({"host_mode": "adhoc"}, {"team": "not set"},
                       {"team": "OTHER12345"}, {"team": "PUBLICCN01"},
                       {"host_id": "com.public.wrong"}, {"duplicate_cdhash": True},
                       {"authority": "Developer ID Application: Public Fixture (PUBLIC1234)"}):
            with self.subTest(fields=fields), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.development_bundle(root)
                signer, calls = self.development_signer(**fields)
                with patch.object(seal, "tool", side_effect=signer):
                    with self.assertRaisesRegex(RuntimeError, "宿主开发签名身份不符"):
                        seal.seal(root, signing_mode="apple-development")
                self.assertTrue(any("--force" in call for call in calls))
                self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_development_certificate_sha1_and_unique_ou_required_before_copy(self):
        cases = ({"certificate_hash": "2" * 40},
                 {"certificate_subject": "CN=Public Fixture"},
                 {"certificate_subject": "OU=PUBLIC1234,OU=PUBLIC1234,CN=Public Fixture"},
                 {"certificate_subject": "OU=bad,CN=Public Fixture"})
        for fields in cases:
            with self.subTest(fields=fields), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.development_bundle(root)
                signer, calls = self.development_signer(**fields)
                with patch.object(seal, "tool", side_effect=signer), patch.object(seal.shutil, "copytree") as copy:
                    with self.assertRaisesRegex(RuntimeError, "开发签名证书Team不符"):
                        seal.seal(root, signing_mode="apple-development")
                    copy.assert_not_called()
                self.assertFalse(any("--force" in call for call in calls))
                self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_development_selects_unique_identity_for_framework_and_host_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = self.development_bundle(root)
            before = {name: (source / "Contents/MacOS" / name).read_bytes()
                      for name in ("BettboxCore", "BettboxCoreSupervisor")}
            signer, calls = self.development_signer()
            with patch.object(seal, "tool", side_effect=signer):
                report = seal.seal(root, signing_mode="apple-development")
            signing = [call for call in calls if "--force" in call]
            self.assertEqual(len(signing), 3)
            self.assertTrue(all(call[call.index("--sign") + 1] == "1" * 40 for call in signing))
            self.assertTrue(any(call[-1].endswith("Public.framework/Public") for call in signing))
            self.assertTrue(any(call[-1].endswith("Public.framework") for call in signing))
            self.assertTrue(any(call[-1].endswith("Bettbox.app") for call in signing))
            self.assertFalse(any(call[-1].endswith(tuple(before)) for call in signing))
            self.assertTrue(any("--deep" in call and "--strict" in call and "--verify" in call for call in calls))
            for name, data in before.items():
                self.assertEqual((root / seal.DESTINATION / "Contents/MacOS" / name).read_bytes(), data)
                self.assertEqual((source / "Contents/MacOS" / name).read_bytes(), data)
            self.assertEqual(report["signingmode"], "apple-development")
            self.assertFalse(report["notarized"])
            self.assertNotIn("Public Fixture", json.dumps(report))
            self.assertEqual(json.loads(((root / seal.DESTINATION).parent / "seal.json").read_text()), report)

    def test_development_tool_stderr_never_reaches_exception_or_success_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.development_bundle(root)
            result = SimpleNamespace(returncode=1, stdout=b"", stderr=b"PUBLIC_RESTRICTED_TOOL_DETAIL")
            with patch.object(seal.subprocess, "run", return_value=result) as run:
                with self.assertRaisesRegex(RuntimeError, "候选签名工具失败") as failure:
                    seal.seal(root, signing_mode="apple-development")
                self.assertNotIn("PUBLIC_RESTRICTED_TOOL_DETAIL", str(failure.exception))
                run.assert_called_once()
            self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_development_cli_failure_prints_only_fixed_failure_marker(self):
        output = io.StringIO()
        result = SimpleNamespace(returncode=1, stdout=b"", stderr=b"PUBLIC_RESTRICTED_TOOL_DETAIL")
        with patch.object(sys, "argv", ["seal_macos_candidate.py", "--signing-mode", "apple-development"]), \
             patch.object(seal.subprocess, "run", return_value=result), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as failure:
                runpy.run_path(str(Path(seal.__file__)), run_name="__main__")
        self.assertEqual(failure.exception.code, 1)
        self.assertEqual(output.getvalue(), "MACOS_CANDIDATE_SEAL_FAIL\n")

    def test_development_tool_start_and_timeout_errors_are_fixed_before_copy(self):
        failures = (OSError("PUBLIC_RESTRICTED_TOOL_DETAIL"),
                    subprocess.TimeoutExpired(["PUBLIC_RESTRICTED_ARGUMENT"], 60,
                                              output=b"PUBLIC_RESTRICTED_OUTPUT",
                                              stderr=b"PUBLIC_RESTRICTED_STDERR"))
        for error in failures:
            with self.subTest(kind=type(error).__name__), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.development_bundle(root)
                with patch.object(seal.subprocess, "run", side_effect=error), \
                     patch.object(seal.shutil, "copytree") as copy:
                    with self.assertRaises(RuntimeError) as failure:
                        seal.seal(root, signing_mode="apple-development")
                    self.assertEqual(str(failure.exception), "候选签名工具失败")
                    self.assertTrue(failure.exception.__suppress_context__)
                    copy.assert_not_called()
                self.assertFalse(((root / seal.DESTINATION).parent / "seal.json").exists())

    def test_development_cli_start_and_timeout_errors_do_not_emit_traceback(self):
        for error in (OSError("PUBLIC_RESTRICTED_TOOL_DETAIL"),
                      subprocess.TimeoutExpired(["PUBLIC_ARGUMENT"], 60, stderr=b"PUBLIC_STDERR")):
            with self.subTest(kind=type(error).__name__):
                output = io.StringIO(); errors = io.StringIO()
                with patch.object(sys, "argv", ["seal_macos_candidate.py", "--signing-mode", "apple-development"]), \
                     patch.object(seal.subprocess, "run", side_effect=error), \
                     contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as failure:
                        runpy.run_path(str(Path(seal.__file__)), run_name="__main__")
                self.assertEqual(failure.exception.code, 1)
                self.assertEqual(output.getvalue(), "MACOS_CANDIDATE_SEAL_FAIL\n")
                self.assertEqual(errors.getvalue(), "")


if __name__ == "__main__": unittest.main()
