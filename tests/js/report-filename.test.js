const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const cases = JSON.parse(fs.readFileSync(path.join(root, 'shared', 'report-filename-cases.json'), 'utf8'));
const naming = require(path.join(root, 'shared', 'report-filename.js'));

for (const fixture of cases) {
  test(`filename fixture: ${fixture.expected}`, () => {
    assert.equal(naming.build(fixture), fixture.expected);
  });
}
