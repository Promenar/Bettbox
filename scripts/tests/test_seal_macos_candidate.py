"""候选签名前检查真实文件结构及固定签名身份，错误不进入签名发布。"""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import plistlib
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


if __name__ == "__main__": unittest.main()
