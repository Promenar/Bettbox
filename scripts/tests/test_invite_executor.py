import contextlib
import io
import json
import shlex
import subprocess
import sys
import unittest
from unittest.mock import patch

from scripts import run_xboard_invite_check as executor


class InviteExecutorTest(unittest.TestCase):
    def test_isolated_execution_uses_exact_image_and_does_not_echo_inspect(self):
        source = [{'Image': 'sha256:fixture', 'Mounts': [{'Destination': '/data'}],
                   'Config': {'Env': ['PASSWORD=must-not-appear']}}]
        results = [
            subprocess.CompletedProcess([], 0, json.dumps(source).encode(), b''),
            subprocess.CompletedProcess([], 0, b'{"ok":true,"mode":"fixture"}', b''),
        ]
        output = io.StringIO()
        with patch.object(sys, 'argv', ['check', '--ssh-target', 'test-host', '--container', 'test-container']), \
                patch.object(subprocess, 'run', side_effect=results) as run, \
                contextlib.redirect_stdout(output):
            self.assertEqual(executor.main(), 0)
        command = shlex.split(run.call_args_list[1].args[0][-1])
        for option, value in [('--network', 'none'), ('--volumes-from', 'test-container:ro'),
                              ('--cap-drop', 'ALL'), ('--security-opt', 'no-new-privileges')]:
            self.assertEqual(command[command.index(option) + 1], value)
        self.assertIn('--read-only', command)
        self.assertIn('--rm', command)
        self.assertIn('sha256:fixture', command)
        self.assertNotIn('must-not-appear', output.getvalue())
        self.assertNotIn('PASSWORD', output.getvalue())

    def test_unexpected_output_is_rejected_without_echo(self):
        source = [{'Image': 'sha256:fixture', 'Mounts': []}]
        results = [
            subprocess.CompletedProcess([], 0, json.dumps(source).encode(), b''),
            subprocess.CompletedProcess([], 0, b'{"ok":true,"password":"must-not-appear"}', b''),
        ]
        output = io.StringIO()
        with patch.object(sys, 'argv', ['check', '--ssh-target', 'test-host', '--container', 'test-container']), \
                patch.object(subprocess, 'run', side_effect=results), \
                contextlib.redirect_stdout(output), self.assertRaises(ValueError):
            executor.main()
        self.assertEqual(output.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
