"""Behavioral fixtures run in the installed WezTerm Lua runtime, without Lua packages."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResurrectTests(unittest.TestCase):
    def test_lua_fixtures(self):
        wezterm = shutil.which("wezterm")
        assert wezterm is not None, "Install WezTerm to run embedded-Lua regressions"
        fixtures = sorted((ROOT / "tests").glob("*.lua"))
        self.assertTrue(fixtures, "No behavioral fixtures found")
        for fixture in fixtures:
            with self.subTest(fixture=fixture.name), tempfile.TemporaryDirectory(prefix="resurrect-test-") as tmp:
                directory = Path(tmp)
                env = dict(os.environ, RESURRECT_ROOT=ROOT.as_posix(),
                           RESURRECT_TEST_DIR=directory.as_posix(), RESURRECT_FIXTURE=fixture.as_posix())
                config = directory / "wezterm.lua"
                config.write_text('''local wezterm = require 'wezterm'
package.path = os.getenv('RESURRECT_ROOT') .. '/plugin/?.lua;' .. os.getenv('RESURRECT_ROOT') .. '/?/init.lua;' .. package.path
dofile(os.getenv('RESURRECT_FIXTURE'))
local f = assert(io.open(os.getenv('RESURRECT_TEST_DIR') .. '/passed', 'wb'))
assert(f:write('passed'))
assert(f:close())
return {}
''', encoding="utf-8")
                result = subprocess.run([wezterm, "--config-file", str(config), "show-keys", "--lua"],
                                        env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((directory / "passed").exists(), result.stdout + result.stderr)
                self.assertEqual((directory / "passed").read_text(), "passed")


if __name__ == "__main__":
    unittest.main()
