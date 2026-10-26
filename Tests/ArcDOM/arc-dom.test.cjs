// Run only in an isolated Node VM with a fake DOM. No browser or Apple Events.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

class FakeElement {
  constructor(tag = 'BUTTON', text = 'Continue') {
    this.tagName = tag;
    this.innerText = text;
    this.attrs = {};
    this.labels = [];
    this.type = tag === 'INPUT' ? 'text' : '';
    this.disabled = false;
    this.readOnly = false;
    this.isConnected = true;
    this.style = { visibility: 'visible', display: 'block', opacity: '1' };
    this.rect = { left: 20, top: 30, right: 140, bottom: 70, width: 120, height: 40 };
    this.children = [];
    this.events = [];
    this.clicks = 0;
    this.href = 'https://example.com/original';
    this.target = '_self';
  }
  getAttribute(name) { return name === 'type' ? this.type || null : this.attrs[name] ?? null; }
  getBoundingClientRect() { return { ...this.rect }; }
  contains(node) { return this.children.includes(node) || this.children.some(child => child.contains(node)); }
  click() { this.clicks++; }
  dispatchEvent(event) { this.events.push(event.type); }
}
class FakeInput extends FakeElement {
  constructor() { super('INPUT', ''); this.attrs['aria-label'] = 'Search'; this._value = ''; }
  get value() { return this._value; }
  set value(value) { this._value = this.rejectValue ? '' : String(value); }
}
class FakeTextarea extends FakeElement {
  constructor() { super('TEXTAREA', ''); this.attrs['aria-label'] = 'Message'; this._value = ''; }
  get value() { return this._value; }
  set value(value) { this._value = String(value); }
}

function page(elements = [new FakeElement()]) {
  const doc = {
    title: 'Test page', body: { innerText: 'A page for fixture tests' }, nodes: elements,
    querySelectorAll() { return this.nodes; },
    hit: elements[0],
    elementFromPoint(x, y) { this.hitPoint = { x, y }; return this.hit; }
  };
  const context = vm.createContext({
    document: doc, location: { href: 'https://example.com/page' },
    innerWidth: 1000, innerHeight: 800, getComputedStyle: element => element.style,
    HTMLInputElement: FakeInput, HTMLTextAreaElement: FakeTextarea,
    Event: class { constructor(type, options) { this.type = type; this.bubbles = options?.bubbles; } },
    URL, scrolls: [], scrollBy(options) { this.scrolls.push(options); }
  });
  context.window = context;
  return { context, doc, elements };
}
function run(fixture, name) {
  const raw = vm.runInContext(scripts[name], fixture.context, { timeout: 1000 });
  assert.equal(typeof raw, 'string', 'The page bridge must return explicit JSON text');
  return JSON.parse(raw);
}
function observed(element = new FakeElement()) {
  const fixture = page([element]);
  assert.equal(run(fixture, 'snapshot').ok, true);
  return fixture;
}
function rejected(fixture, script = 'click', pattern) {
  const result = run(fixture, script);
  assert.equal(result.ok, false);
  if (pattern) assert.match(result.error, pattern);
  assert.equal(fixture.elements[0].clicks, 0);
  return result;
}

let passed = 0;
let failed = 0;
function test(name, body) {
  try { body(); passed++; process.stdout.write(`PASS ${name}\n`); }
  catch (error) { failed++; process.stderr.write(`FAIL ${name}: ${error.message}\n`); }
}

test('snapshot exports current IDs and visible text', () => {
  const f = page();
  const result = run(f, 'snapshot');
  assert.equal(result.elements[0].id, 'observation-one:0');
  assert.equal(result.elements[0].name, 'Continue');
  assert.equal(result.url, 'https://example.com/page');
});
test('snapshot hides CSS-invisible controls and password values', () => {
  const hidden = new FakeElement(); hidden.style.visibility = 'hidden';
  const transparent = new FakeElement(); transparent.style.opacity = '0';
  const password = new FakeInput(); password.type = 'password'; password.value = 'fixture-secret';
  const result = run(page([hidden, transparent, password]), 'snapshot');
  assert.equal(result.elements.length, 1);
  assert.equal(result.elements[0].type, 'password');
  assert.equal(Object.hasOwn(result.elements[0], 'value'), false);
});
test('an unchanged visible target is clicked once', () => {
  const f = observed();
  assert.equal(run(f, 'click').ok, true);
  assert.equal(f.elements[0].clicks, 1);
});
test('a new observation invalidates old element IDs', () => {
  const f = observed(); run(f, 'next_snapshot'); rejected(f, 'click', /Page changed/);
});
test('navigation invalidates old element IDs', () => {
  const f = observed(); f.context.location.href = 'https://example.com/other'; rejected(f, 'click', /Page changed/);
});
test('unknown element IDs do not dispatch', () => rejected(observed(), 'missing_click', /Target changed/));
test('detached elements do not dispatch', () => {
  const f = observed(); f.elements[0].isConnected = false; rejected(f, 'click', /Target changed/);
});
test('changed labels do not dispatch', () => {
  const f = observed(); f.elements[0].innerText = 'Delete account'; rejected(f, 'click', /Target changed/);
});
test('same-label link destination changes do not dispatch', () => {
  const f = observed(new FakeElement('A', 'Continue'));
  f.elements[0].href = 'https://example.com/changed'; rejected(f, 'click', /Target changed/);
});
test('changed input type does not dispatch', () => {
  const f = observed(new FakeInput()); f.elements[0].type = 'email'; rejected(f, 'type', /Target changed/);
  assert.equal(f.elements[0].value, '');
});
for (const [property, value] of [['visibility', 'hidden'], ['visibility', 'collapse'], ['display', 'none'], ['opacity', '0']]) {
  test(`target that becomes ${property}:${value} does not dispatch`, () => {
    const f = observed(); f.elements[0].style[property] = value; rejected(f, 'click', /no longer available/);
  });
}
test('disabled targets do not dispatch', () => {
  const f = observed(); f.elements[0].disabled = true; rejected(f, 'click', /no longer available/);
});
test('offscreen targets do not dispatch', () => {
  const f = observed(); f.elements[0].rect.top = 900; rejected(f, 'click', /no longer available/);
});
test('an overlay blocks the click', () => {
  const f = observed(); f.doc.hit = new FakeElement('DIV', 'Overlay'); rejected(f, 'click', /covers/);
});
test('a target child at the hit point is accepted', () => {
  const f = observed(); const child = new FakeElement('SPAN', 'Label'); f.elements[0].children.push(child); f.doc.hit = child;
  assert.equal(run(f, 'click').ok, true);
});
test('partly clipped targets use a point inside the viewport', () => {
  const f = observed(); f.elements[0].rect = { left: -100, right: 20, top: -20, bottom: 20, width: 120, height: 40 };
  assert.equal(run(f, 'click').ok, true);
  assert.deepEqual(f.doc.hitPoint, { x: 10, y: 10 });
});
for (const type of ['password', 'file', 'hidden']) {
  test(`${type} inputs cannot be clicked or typed`, () => {
    const input = new FakeInput(); input.type = type;
    const f = observed(input); rejected(f, 'click', /handle it directly/); rejected(f, 'type', /handle it directly/);
    assert.equal(input.value, '');
  });
}
test('non-HTTP link actions are rejected', () => {
  const link = new FakeElement('A'); link.href = 'javascript:alert(1)'; rejected(observed(link), 'click', /HTTP/);
});
test('links with embedded credentials are rejected', () => {
  const link = new FakeElement('A'); link.href = 'https://fixture-user:fixture-pass@example.com'; rejected(observed(link), 'click', /credentials/);
});
test('new-tab links are rejected', () => {
  const link = new FakeElement('A'); link.target = '_blank'; rejected(observed(link), 'click', /another tab/);
});
test('typing writes escaped text and dispatches input/change without clicking', () => {
  const input = new FakeInput(); const f = observed(input);
  assert.equal(run(f, 'type').ok, true);
  assert.equal(input.value, scripts.expected_text);
  assert.deepEqual(input.events, ['input', 'change']);
  assert.equal(input.clicks, 0);
  assert.equal(f.context.injected, undefined);
});
test('textarea uses its native value setter', () => {
  const input = new FakeTextarea(); const f = observed(input);
  assert.equal(run(f, 'type').ok, true); assert.equal(input.value, scripts.expected_text);
});
test('read-only text fields reject typing', () => {
  const input = new FakeInput(); input.readOnly = true; rejected(observed(input), 'type', /editable/); assert.equal(input.value, '');
});
test('failed value retention reports possible partial application', () => {
  const input = new FakeInput(); input.rejectValue = true; rejected(observed(input), 'type', /partially applied/);
});
test('scroll uses the observed page and requested bounded distance', () => {
  const f = observed(); assert.equal(run(f, 'scroll').ok, true);
  assert.equal(f.context.scrolls.length, 1); assert.equal(f.context.scrolls[0].top, 600);
  run(f, 'next_snapshot'); assert.equal(run(f, 'scroll').ok, false); assert.equal(f.context.scrolls.length, 1);
});
test('unavailable page actions cannot execute code', () => rejected(observed(), 'unsupported', /Unsupported/));

process.stdout.write(`${passed} Arc DOM checks passed; ${failed} failed. No browser was controlled.\n`);
if (failed) process.exitCode = 1;
