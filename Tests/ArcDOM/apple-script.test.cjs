// Local Foundation/string checks only. Targeted scripts are compiled, never run.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function localResult(script) {
  assert.doesNotMatch(script, /tell\s+application|execute\s+.*javascript/i);
  return JSON.parse(execFileSync('/usr/bin/osascript', ['-l', 'AppleScript', '-'], {
    input: script, encoding: 'utf8', timeout: 10_000, maxBuffer: 100_000
  }));
}

const value = localResult(scripts.applescript_roundtrip);
assert.equal(value.ok, true);
assert.equal(value.text, scripts.applescript_expected_text);
const error = localResult(scripts.applescript_error);
assert.deepEqual(error, { ok: false, error: 'Fixture failure', code: -1743 });

const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'LiteCU-AppleScriptSyntax-'));
try {
  const source = path.join(folder, 'syntax.applescript');
  fs.writeFileSync(source, scripts.applescript_target_syntax);
  execFileSync('/usr/bin/osacompile', ['-l', 'AppleScript', '-o', path.join(folder, 'syntax.scpt'), source], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 100_000
  });
} finally { fs.rmSync(folder, { recursive: true, force: true }); }
process.stdout.write('3 AppleScript bridge checks passed: literal/JSON roundtrip, error envelope, stable-ID syntax. No Arc script was executed.\n');
