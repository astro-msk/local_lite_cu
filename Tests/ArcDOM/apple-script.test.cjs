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
const additions = localResult(scripts.applescript_added_ids);
assert.deepEqual(additions, {
  ok: true, no_change: [], one_new: ['new-id'], several_new: ['new-a', 'new-b'],
  duplicate_new: ['new-id'], old_closed: []
});
const invalid = localResult(scripts.applescript_invalid_id);
assert.equal(invalid.ok, false);
assert.match(invalid.error, /invalid object identifier/);
assert.deepEqual(localResult(scripts.applescript_phase_error), {
  ok: false, error: 'Creating the Arc task tab: Fixture failure', code: -1700
});

const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'LiteCU-AppleScriptSyntax-'));
try {
  for (const name of ['applescript_target_syntax', 'applescript_creation_syntax', 'applescript_navigation_syntax', 'applescript_evaluation_syntax']) {
    assert.doesNotMatch(scripts[name], /\bexists\s+(window|tab)\b/, 'Arc has no exists command; use observed ID membership');
    assert.doesNotMatch(scripts[name], /\bset\s+\w+\s+to\s+(window|tab)\s+id\b/i, 'Do not evaluate Arc object references into malformed returned descriptors');
    const source = path.join(folder, name + '.applescript');
    fs.writeFileSync(source, scripts[name]);
    execFileSync('/usr/bin/osacompile', ['-l', 'AppleScript', '-o', path.join(folder, name + '.scpt'), source], {
      encoding: 'utf8', timeout: 10_000, maxBuffer: 100_000
    });
  }
} finally { fs.rmSync(folder, { recursive: true, force: true }); }
process.stdout.write('9 AppleScript bridge checks passed: literal/JSON roundtrip, error/phase envelopes, ID differences, invalid IDs, and all operation syntax. No Arc script was executed.\n');
