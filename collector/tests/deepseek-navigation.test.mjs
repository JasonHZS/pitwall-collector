import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, lstatSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import { apply } from '../deepseek-harness/index.js';

const require = createRequire(import.meta.url);
const { install } = require('../deepseek-harness/install.cjs');
const source = resolve(import.meta.dirname, '../deepseek-harness');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

test('Harness compatibility keeps only the minimum runtime version', {
  skip: !process.env.PITWALL_DSH_TEST_RUNTIME,
}, async () => {
  const runtimeRequire = createRequire(process.env.PITWALL_DSH_TEST_RUNTIME);
  const { evaluatePluginCompatibility } = await import(runtimeRequire.resolve('@deepseek-ai/dsh-app-boot'));
  const manifest = JSON.parse(readFileSync(join(source, 'package.json')));
  for (const version of ['0.2.1-rc.3', '0.2.1-rc.5', '0.2.1-rc.6', '0.2.1', '0.2.2-rc.1', '0.3.0-rc.1', '0.3.0', '1.0.0']) {
    assert.equal(evaluatePluginCompatibility(manifest, {}, version), undefined, version);
  }
  for (const version of ['0.2.1-rc.2', '0.2.0']) {
    assert.ok(evaluatePluginCompatibility(manifest, {}, version), version);
  }
});
async function until(predicate) {
  for (let i = 0; i < 80; i++) { if (predicate()) return; await sleep(25); }
  assert.fail('Timed out waiting for navigation');
}

function bridge(t, { archived = [], ready = Promise.resolve(), browser = false, acceptSelection = true, alter = () => {} } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'pitwall-dsh-'));
  writeFileSync(join(directory, 'installed.json'), '{"v":1}');
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const routes = new Map();
  const disposers = [];
  const effect = fn => { const dispose = fn(); if (typeof dispose === 'function') disposers.push(dispose); };
  apply({ effect, connection: { fetch: { register(value) { routes.set(value.path, value); return () => {}; } } } }, { directory });
  const fetch = request => {
    const route = routes.get(new URL(request.url).pathname);
    return route?.methods.includes(request.method) ? route.fetch(request) : Promise.resolve(new Response(null, { status: 405 }));
  };
  let plugin;
  const window = { location: { protocol: browser ? 'https:' : 'dsh-app:', hostname: 'app' }, __ModuleLoader__: { load(value) { plugin = value.factory(); } } };
  window.top = window;
  const navigated = [];
  const retained = [];
  const row = { retainedBy: {} };
  const catalog = { phase: 'ready', byId: { 'session-one': row, 'session-two': { retainedBy: {} } } };
  vm.runInNewContext(readFileSync(join(source, 'client.js'), 'utf8'), {
    window, AbortController, AbortSignal, setTimeout, clearTimeout,
    fetch: (url, options) => fetch(new Request(`http://localhost${url}`, options)),
  });
  const ctx = { effect,
    uiWorkspace: { openSession(id) { navigated.push(id); if (acceptSelection) catalog.byId[id].retainedBy.mainView = 1; } },
    sessions: { list: { getSnapshot: () => catalog }, retain: id => { retained.push(id); return { ready: typeof ready === 'function' ? ready(id) : ready, release() {} }; } },
    workspaces: { list: { getSnapshot: () => ({ phase: 'ready', archivedSessionIds: archived }) } },
    layout: { panelInfo: { getSnapshot: () => ({ activePanelId: null }) } },
  };
  alter(ctx);
  plugin.apply(ctx);
  t.after(() => { for (const dispose of disposers.reverse()) dispose(); });
  const request = (id, sessionID = 'session-one', expired = false) => writeFileSync(join(directory, 'request.json'), JSON.stringify({ v: 1, id, sessionID, createdAt: Date.now() - (expired ? 10000 : 0), expiresAt: Date.now() + (expired ? -1000 : 5000) }));
  const reply = () => { try { return JSON.parse(readFileSync(join(directory, 'response.json'))); } catch { return null; } };
  const heartbeat = () => { try { return JSON.parse(readFileSync(join(directory, 'listening.json'))); } catch { return null; } };
  return { directory, request, reply, heartbeat, navigated, retained, fetch, routes, ctx };
}

for (const [name, alter] of [
  ['openSession removed', ctx => { delete ctx.uiWorkspace.openSession; }],
  ['retain removed', ctx => { delete ctx.sessions.retain; }],
  ['snapshot method removed', ctx => { delete ctx.sessions.list.getSnapshot; }],
  ['catalog shape changed', ctx => { ctx.sessions.list.getSnapshot = () => ({}); }],
  ['archive state changed', ctx => { ctx.workspaces.list.getSnapshot = () => ({ phase: 'ready', archivedSessionIds: null }); }],
  ['panel state changed', ctx => { ctx.layout.panelInfo.getSnapshot = () => ({}); }],
]) {
  test(`incompatible Harness capabilities are reported without navigating: ${name}`, async t => {
    const b = bridge(t, { alter });
    b.request('request-one');
    await until(() => b.heartbeat());
    assert.equal(b.heartbeat().compatible, false);
    assert.deepEqual(b.navigated, []);
  });
}

test('an unready session catalog does not advertise a navigation listener', async t => {
  const b = bridge(t, { alter: ctx => { ctx.sessions.list.getSnapshot = () => ({ phase: 'loading' }); } });
  await sleep(50);
  assert.equal(b.heartbeat(), null);
});

test('changed selection fields are rejected before opening the target', async t => {
  const b = bridge(t, { alter: ctx => { delete ctx.sessions.list.getSnapshot().byId['session-one'].retainedBy; } });
  b.request('request-one');
  await until(() => b.reply());
  assert.equal(b.reply().status, 'incompatible');
  assert.deepEqual(b.navigated, []);
});

test('changed retain contract is rejected and its reference released without navigating', async t => {
  let releases = 0;
  const b = bridge(t, { alter: ctx => { ctx.sessions.retain = () => ({ release() { releases++; } }); } });
  b.request('request-one');
  await until(() => b.reply());
  assert.equal(b.reply().status, 'incompatible');
  assert.equal(releases, 1);
  assert.deepEqual(b.navigated, []);
});

test('capabilities are checked again after loading history and may recover', async t => {
  let release;
  const b = bridge(t, { ready: new Promise(resolve => { release = resolve; }) });
  b.request('request-one');
  await until(() => b.retained.length > 0);
  const snapshot = b.ctx.layout.panelInfo.getSnapshot;
  b.ctx.layout.panelInfo.getSnapshot = () => ({});
  release();
  await until(() => b.reply());
  assert.equal(b.reply().status, 'incompatible');
  assert.deepEqual(b.navigated, []);
  b.ctx.layout.panelInfo.getSnapshot = snapshot;
  b.request('request-two');
  await until(() => b.reply()?.id === 'request-two');
  assert.equal(b.reply().status, 'selected');
});

test('missing Host Fetch capability leaves the bridge inactive without throwing', () => {
  assert.doesNotThrow(() => apply({ connection: {}, effect() { assert.fail('must not register an unusable bridge'); } }, { directory: '/unused' }));
});

test('desktop plugin selects by ID and acknowledges the actual main view', async t => {
  const b = bridge(t);
  b.request('request-one');
  await until(() => b.reply());
  assert.deepEqual(b.navigated, ['session-one']);
  assert.equal(b.reply().status, 'selected');
  assert.equal(b.reply().id, 'request-one');
  assert.equal(lstatSync(join(b.directory, 'response.json')).mode & 0o777, 0o600);
});
test('archived and missing sessions do not navigate', async t => {
  const b = bridge(t, { archived: ['session-one'] });
  b.request('request-one'); await until(() => b.reply()?.id === 'request-one');
  assert.equal(b.reply().status, 'archived');
  b.request('request-two', 'missing'); await until(() => b.reply()?.id === 'request-two');
  assert.equal(b.reply().status, 'missing');
  assert.deepEqual(b.navigated, []);
});
test('an expired request cannot change selection or produce a success reply', async t => {
  const b = bridge(t);
  b.request('expired', 'session-one', true);
  await sleep(650);
  assert.deepEqual(b.navigated, []);
  assert.equal(b.reply(), null);
});
test('a newer request supersedes a still-loading session', async t => {
  let release;
  const b = bridge(t, { ready: new Promise(resolve => { release = resolve; }) });
  b.request('first');
  await sleep(650);
  b.request('second', 'session-two');
  release();
  await until(() => b.reply()?.id === 'second');
  assert.deepEqual(b.navigated, ['session-two']);
});
test('a newer request interrupts a navigation whose history never finishes loading', async t => {
  const b = bridge(t, { ready: id => id === 'session-one' ? new Promise(() => {}) : Promise.resolve() });
  b.request('first');
  await sleep(650);
  b.request('second', 'session-two');
  await until(() => b.reply()?.id === 'second');
  assert.equal(b.reply().status, 'selected');
  assert.deepEqual(b.navigated, ['session-two']);
});
test('calling navigation without selecting the main view is failure', async t => {
  const b = bridge(t, { acceptSelection: false });
  b.request('request-one'); await until(() => b.reply());
  assert.equal(b.reply().status, 'failed');
});
test('an open main panel is dismissed after the target session is selected', async t => {
  let panelId = 'settings';
  let dismissed = 0;
  const b = bridge(t, { alter: ctx => {
    ctx.layout.panelInfo.getSnapshot = () => ({ activePanelId: panelId });
    ctx.layout.selectPanel = id => { dismissed += 1; panelId = id; };
  } });
  b.request('request-one');
  await until(() => b.reply());
  assert.equal(dismissed, 1);
  assert.equal(panelId, null);
  assert.equal(b.reply().status, 'selected');
  assert.deepEqual(b.navigated, ['session-one']);
});
test('a session left behind a panel that stays open is not selected', async t => {
  const b = bridge(t, { alter: ctx => {
    ctx.layout.panelInfo.getSnapshot = () => ({ activePanelId: 'settings' });
    ctx.layout.selectPanel = () => {};
  } });
  b.request('request-one');
  await until(() => b.reply());
  assert.equal(b.reply().status, 'failed');
  assert.deepEqual(b.navigated, ['session-one']);
});
test('a browser client does not listen or follow desktop navigation', async t => {
  const b = bridge(t, { browser: true });
  b.request('request-one'); await sleep(50);
  assert.equal(existsSync(join(b.directory, 'listening.json')), false);
  assert.deepEqual(b.navigated, []);
});

test('host rejects unmatched replies and oversized bodies without persisting them', async t => {
  const b = bridge(t, { browser: true });
  b.request('request-one');
  const post = body => b.fetch(new Request('http://localhost/api/pitwall-navigation/result', { method: 'POST', body }));
  assert.equal(b.routes.get('/api/pitwall-navigation').requestBody, 'buffered', 'Harness cannot construct GET Requests in streaming mode');
  assert.equal(b.routes.get('/api/pitwall-navigation/result').requestBody, 'streaming');
  assert.equal((await post(JSON.stringify({ id: 'another-request', sessionID: 'session-one', status: 'selected' }))).status, 409);
  assert.equal((await post('x'.repeat(5000))).status, 413);
  assert.equal(b.reply(), null);
});

test('removing the installation marker disables even an already loaded host plugin', async t => {
  const b = bridge(t, { browser: true });
  b.request('request-one');
  rmSync(join(b.directory, 'installed.json'));
  const response = await b.fetch(new Request('http://localhost/api/pitwall-navigation'));
  assert.equal(response.status, 503);
  assert.equal(existsSync(join(b.directory, 'listening.json')), false);
});

test('offline installer preserves user YAML, backs up, is idempotent and uninstalls only its package', {
  skip: !process.env.PITWALL_DSH_TEST_RUNTIME,
}, t => {
  const home = mkdtempSync(join(tmpdir(), 'pitwall-dsh-install-'));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const profile = join(home, '.dsh/profiles/desktop'); mkdirSync(profile, { recursive: true });
  const original = '# user comment\n- id: model\n  config:\n    value: !!js process.env.MY_MODEL\n- insert:\n    - id: user-plugin\n      name: user-plugin\n';
  writeFileSync(join(profile, 'cordis.patch.yml'), original);
  writeFileSync(join(profile, 'package.json'), '{"private":true,"dependencies":{"user-plugin":"1.0.0"}}');
  const options = { home, runtime: process.env.PITWALL_DSH_TEST_RUNTIME, source };
  install('refresh', options);
  assert.equal(existsSync(join(home, '.pitwall')), false, 'upgrading without consent must not create plugin files');
  install('install', options);
  const first = readFileSync(join(profile, 'cordis.patch.yml'), 'utf8');
  assert.match(first, /# user comment/); assert.match(first, /!!js process.env.MY_MODEL/); assert.match(first, /user-plugin/);
  assert.ok(existsSync(join(home, '.pitwall/deepseek-harness/installed.json')));
  install('install', options);
  assert.equal(readFileSync(join(profile, 'cordis.patch.yml'), 'utf8'), first);
  install('refresh', options);
  assert.equal(readFileSync(join(profile, 'cordis.patch.yml'), 'utf8'), first, 'upgrading an installed plugin must not rewrite its profile');
  install('uninstall', options);
  assert.ok(!existsSync(join(home, '.pitwall/deepseek-harness/installed.json')));
  assert.ok(!readFileSync(join(profile, 'cordis.patch.yml'), 'utf8').includes('@pitwall/'));
  assert.match(readFileSync(join(profile, 'cordis.patch.yml'), 'utf8'), /user-plugin/);
  assert.deepEqual(JSON.parse(readFileSync(join(profile, 'package.json'))).dependencies, { 'user-plugin': '1.0.0' });
  writeFileSync(join(profile, 'cordis.patch.yml'), 'not: [valid');
  assert.throws(() => install('install', options));
  assert.equal(readFileSync(join(profile, 'cordis.patch.yml'), 'utf8'), 'not: [valid');
});

test('refresh replaces the old exact-version requirement without rewriting the profile', {
  skip: !process.env.PITWALL_DSH_TEST_RUNTIME,
}, async t => {
  const { home, profile, options } = installedProfile(t);
  const installedManifest = join(home, '.pitwall/plugins/deepseek-harness-navigation/package.json');
  const old = JSON.parse(readFileSync(installedManifest));
  old.version = '1.0.0'; old.engines.dsh = '0.2.1-rc.3';
  writeFileSync(installedManifest, JSON.stringify(old));
  const before = ['package.json', 'cordis.patch.yml'].map(file => readFileSync(join(profile, file), 'utf8'));
  install('refresh', options);
  assert.deepEqual(['package.json', 'cordis.patch.yml'].map(file => readFileSync(join(profile, file), 'utf8')), before);
  const { evaluatePluginCompatibility } = await import(createRequire(options.runtime).resolve('@deepseek-ai/dsh-app-boot'));
  assert.equal(evaluatePluginCompatibility(JSON.parse(readFileSync(installedManifest)), {}, '0.2.1-rc.5'), undefined);
});

function installedProfile(t, patch = '[]\n') {
  const home = mkdtempSync(join(tmpdir(), 'pitwall-dsh-uninstall-'));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const profile = join(home, '.dsh/profiles/desktop');
  mkdirSync(profile, { recursive: true });
  writeFileSync(join(profile, 'cordis.patch.yml'), patch);
  writeFileSync(join(profile, 'package.json'), '{"private":true,"dependencies":{"other":"1.0.0"}}');
  const options = { home, runtime: process.env.PITWALL_DSH_TEST_RUNTIME, source };
  install('install', options);
  return { home, profile, options };
}

for (const damage of ['missing-profile', 'invalid-yaml', 'invalid-manifest', 'missing-runtime']) {
  test(`uninstall removes its local installation despite ${damage}`, { skip: !process.env.PITWALL_DSH_TEST_RUNTIME }, t => {
    const { home, profile, options } = installedProfile(t);
    if (damage === 'missing-profile') rmSync(profile, { recursive: true });
    if (damage === 'invalid-yaml') writeFileSync(join(profile, 'cordis.patch.yml'), readFileSync(join(profile, 'cordis.patch.yml'), 'utf8') + '\n- invalid: [');
    if (damage === 'invalid-manifest') writeFileSync(join(profile, 'package.json'), '{ invalid');
    if (damage === 'missing-runtime') options.runtime = undefined;
    const beforePatch = existsSync(join(profile, 'cordis.patch.yml')) && readFileSync(join(profile, 'cordis.patch.yml'), 'utf8');
    assert.doesNotThrow(() => install('uninstall', options));
    assert.equal(existsSync(join(home, '.pitwall/deepseek-harness/installed.json')), false);
    assert.equal(existsSync(join(home, '.pitwall/plugins/deepseek-harness-navigation/index.js')), false);
    assert.equal(existsSync(join(profile, 'node_modules/@pitwall/deepseek-harness-navigation')), false);
    if (damage === 'invalid-yaml' || damage === 'missing-runtime') assert.equal(readFileSync(join(profile, 'cordis.patch.yml'), 'utf8'), beforePatch);
    if (damage === 'invalid-manifest') assert.equal(readFileSync(join(profile, 'package.json'), 'utf8'), '{ invalid');
    if (damage === 'missing-profile') assert.equal(existsSync(profile), false, 'uninstall must not recreate a deleted profile');
    if (damage === 'invalid-yaml' || damage === 'missing-runtime') {
      assert.equal(existsSync(join(home, '.pitwall/deepseek-harness/cleanup-pending.json')), true);
      writeFileSync(join(profile, 'cordis.patch.yml'), '[]\n');
      install('uninstall', options);
      assert.equal(existsSync(join(home, '.pitwall/deepseek-harness/cleanup-pending.json')), false);
    }
  });
}

test('install and uninstall preserve user empty insert rows and their comments', { skip: !process.env.PITWALL_DSH_TEST_RUNTIME }, t => {
  const { profile, options } = installedProfile(t, '# keep this comment\n- insert: [] # placeholder for later\n');
  for (const action of ['install', 'uninstall']) {
    install(action, options);
    const patch = readFileSync(join(profile, 'cordis.patch.yml'), 'utf8');
    assert.match(patch, /keep this comment/);
    assert.match(patch, /placeholder for later/);
    assert.match(patch, /insert: \[\]/);
  }
});

test('uninstall ignores the package name in preserved user comments', { skip: !process.env.PITWALL_DSH_TEST_RUNTIME }, t => {
  const { home, profile, options } = installedProfile(t, '- insert:\n    - id: user-plugin\n      name: user-plugin # keep @pitwall/deepseek-harness-navigation in this note\n');
  install('uninstall', options);
  const patch = readFileSync(join(profile, 'cordis.patch.yml'), 'utf8');
  assert.match(patch, /keep @pitwall\/deepseek-harness-navigation/);
  assert.doesNotMatch(patch, /id: pitwall-navigation/);
  assert.equal(existsSync(join(home, '.pitwall/deepseek-harness/cleanup-pending.json')), false);
  install('uninstall', options);
  assert.equal(existsSync(join(home, '.pitwall/deepseek-harness/cleanup-pending.json')), false);
});

test('Harness backup retention is independent of hook backups and user directories', { skip: !process.env.PITWALL_DSH_TEST_RUNTIME }, t => {
  const { home, profile, options } = installedProfile(t);
  const backups = join(home, '.pitwall/backups');
  mkdirSync(join(backups, '20261029-120000'));
  mkdirSync(join(backups, 'deepseek-user-notes'));
  for (let i = 0; i < 12; i++) {
    writeFileSync(join(profile, 'package.json'), JSON.stringify({ private: true, dependencies: { other: `1.0.${i}` } }));
    install('install', options);
  }
  assert.equal(readdirSync(backups).filter(n => /^deepseek-[0-9]{13}-[a-f0-9]{6}$/.test(n)).length, 10);
  assert.ok(existsSync(join(backups, '20261029-120000')));
  assert.ok(existsSync(join(backups, 'deepseek-user-notes')));
});

// ---- 提问应答方：user-questions/request 瀑布 ----

function questionBridge(t, { listen = true, questionWaitMs } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'pitwall-dsh-q-'));
  const directory = join(home, '.pitwall', 'deepseek-harness');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  writeFileSync(join(directory, 'installed.json'), '{"v":1}');
  const approvals = join(home, '.pitwall', 'approvals');
  const beat = () => { mkdirSync(approvals, { recursive: true }); writeFileSync(join(approvals, 'listening'), ''); };
  if (listen) beat();
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const listeners = new Map();
  const disposers = [];
  const effect = fn => { const dispose = fn(); if (typeof dispose === 'function') disposers.push(dispose); };
  apply({
    effect,
    connection: { fetch: { register() { return () => {}; } } },
    on(name, fn, options) { listeners.set(name, { fn, options }); return () => {}; },
  }, { directory, ...(questionWaitMs ? { questionWaitMs } : {}) });
  t.after(() => { for (const dispose of disposers.reverse()) dispose(); });
  const listener = listeners.get('user-questions/request');
  assert.ok(listener, 'the plugin registers a question answerer');
  const agent = { session: { id: 'sess-1', cwd: '/tmp/proj' } };
  const ask = (questions, extra = {}) => listener.fn.call({}, { agent, questions, ...extra }, () => 'delegated');
  const requests = () => { try { return readdirSync(join(approvals, 'requests')).filter(f => f.endsWith('.json')); } catch { return []; } };
  return { approvals, beat, ask, requests, listener, home, directory };
}

const twoQuestions = [
  { id: 'q1', question: '哪个方案？', header: '方案', options: [{ label: 'A' }, { label: 'B', description: '慢' }] },
  { id: 'q2', question: '补充说明', options: [] },
];

async function pendingRequest(b) {
  for (let i = 0; i < 80; i++) { if (b.requests().length) return b.requests()[0]; await sleep(25); }
  assert.fail('request file was not written');
}

test('Pitwall answers a question and the batch returns through the waterfall', async t => {
  const b = questionBridge(t);
  const pending = b.ask(twoQuestions);
  const file = await pendingRequest(b);
  const request = JSON.parse(readFileSync(join(b.approvals, 'requests', file)));
  assert.equal(request.agent, 'deepseek-harness');
  assert.equal(request.session_id, 'sess-1');
  assert.equal(request.cwd, '/tmp/proj');
  assert.equal(request.tool_name, 'ask_user_question');
  assert.equal(request.answer_format, 'answers-batch-v1');
  assert.equal(request.pid, process.pid);
  assert.deepEqual(request.tool_input.questions.map(q => q.id), ['q1', 'q2']);
  writeFileSync(join(b.approvals, 'decisions', request.id),
    JSON.stringify({ answers: [{ id: 'q1', selected: ['B'] }, { id: 'q2', selected: [], custom: '都可以' }] }));
  assert.deepEqual(await pending, { answers: [{ id: 'q1', selected: ['B'] }, { id: 'q2', selected: [], custom: '都可以' }] });
  assert.equal(existsSync(join(b.approvals, 'requests', file)), false);
  assert.equal(existsSync(join(b.approvals, 'decisions', request.id)), false);
});

test('the answerer prepends so Pitwall answers before the native card', async t => {
  const b = questionBridge(t);
  assert.equal(b.listener.options?.prepend, true);
});

test('no Pitwall listener means the native card keeps the request', async t => {
  const b = questionBridge(t, { listen: false });
  assert.equal(await b.ask(twoQuestions), 'delegated');
  assert.deepEqual(b.requests(), []);
});

test('timed, intented and malformed questions all delegate without writing a request', async t => {
  const b = questionBridge(t);
  assert.equal(await b.ask(twoQuestions, { wait: { callId: 'c1', timed: true } }), 'delegated');
  assert.equal(await b.ask([{ id: 'q1', question: 'Q?', intent: { kind: 'plan-review', approve: 'OK' }, options: [{ label: 'OK' }], detail: 'plan' }]), 'delegated');
  assert.equal(await b.ask([{ question: 'no id', options: [{ label: 'A' }] }]), 'delegated');
  assert.equal(await b.ask([{ id: 'q', question: 'same', options: [{ label: 'A' }] }, { id: 'q', question: 'same2', options: [{ label: 'B' }] }]), 'delegated');
  assert.equal(await b.ask([{ id: 'q', question: 'same', options: [{ label: 'A' }] }, { id: 'q2', question: 'same', options: [{ label: 'B' }] }]), 'delegated');
  assert.equal(await b.ask('not-an-array'), 'delegated');
  assert.equal(await b.ask([]), 'delegated');
  assert.deepEqual(b.requests(), []);
});

test('an undecided request times out and delegates back to the native card', async t => {
  const b = questionBridge(t, { questionWaitMs: 300 });
  const pending = b.ask(twoQuestions);
  const file = await pendingRequest(b);
  assert.equal(await pending, 'delegated');
  assert.equal(existsSync(join(b.approvals, 'requests', file)), false);
});

test('an invalid answer batch delegates instead of hanging the waterfall', async t => {
  const b = questionBridge(t);
  for (const bad of [
    'not json',
    JSON.stringify({ answers: [{ id: 'q1', selected: ['A'] }] }),                       // 缺一道题
    JSON.stringify({ answers: [{ id: 'q1', selected: ['A'] }, { id: 'q1', selected: [] }] }), // 重复 id
    JSON.stringify({ answers: [{ id: 'q1', selected: ['A'] }, { id: 'q9', selected: [] }] }), // 未知 id
    JSON.stringify({ answers: [{ id: 'q1', selected: ['Z'] }, { id: 'q2', selected: [] }] }), // 非选项
  ]) {
    const pending = b.ask(twoQuestions);
    const file = await pendingRequest(b);
    const { id } = JSON.parse(readFileSync(join(b.approvals, 'requests', file)));
    writeFileSync(join(b.approvals, 'decisions', id), bad);
    assert.equal(await pending, 'delegated', bad);
  }
});

test('stale heartbeat or an aborted signal hands the request back while waiting', async t => {
  const b = questionBridge(t, { questionWaitMs: 5_000 });
  const controller = new AbortController();
  const pending = b.ask(twoQuestions, { signal: controller.signal });
  await pendingRequest(b);
  controller.abort();
  assert.equal(await pending, 'delegated');
  // 监听过期：等决定时心跳停了也让位。
  const stale = b.ask(twoQuestions);
  await pendingRequest(b);
  rmSync(join(b.approvals, 'listening'), { force: true });
  assert.equal(await stale, 'delegated');
});

test('an already-cancelled request delegates without touching Pitwall', async t => {
  const b = questionBridge(t);
  assert.equal(await b.ask(twoQuestions, { signal: AbortSignal.abort() }), 'delegated');
  assert.deepEqual(b.requests(), []);
});

test('cancelling during setup still delegates and cleans up', async t => {
  const b = questionBridge(t, { questionWaitMs: 5_000 });
  const controller = new AbortController();
  const pending = b.ask(twoQuestions, { signal: controller.signal });
  controller.abort();
  assert.equal(await pending, 'delegated');
  assert.deepEqual(b.requests(), []);
});

test('removing the install marker makes pending and new questions delegate', async t => {
  const b = questionBridge(t, { questionWaitMs: 5_000 });
  const pending = b.ask(twoQuestions);
  const file = await pendingRequest(b);
  rmSync(join(b.directory, 'installed.json'));
  assert.equal(await pending, 'delegated');
  assert.equal(existsSync(join(b.approvals, 'requests', file)), false);
  assert.equal(await b.ask(twoQuestions), 'delegated');
  assert.deepEqual(b.requests(), []);
});

// 真实 cordis 与 dsh-scope（仅在有 Harness runtime 时）：作用域瀑布确实先到我们、让位才到下游。
test('a real cordis waterfall answers through Pitwall first and delegates to the native card', { skip: !process.env.PITWALL_DSH_TEST_RUNTIME }, async t => {
  const runtimeRequire = createRequire(process.env.PITWALL_DSH_TEST_RUNTIME);
  const { Context } = await import(runtimeRequire.resolve('@deepseek-ai/cordis'));
  const { scopeTarget } = await import(runtimeRequire.resolve('@deepseek-ai/dsh-scope'));
  const b = questionBridge(t);
  const home = mkdtempSync(join(tmpdir(), 'pitwall-dsh-cordis-'));
  const directory = join(home, '.pitwall', 'deepseek-harness');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  writeFileSync(join(directory, 'installed.json'), '{"v":1}');
  const approvals = join(home, '.pitwall', 'approvals');
  mkdirSync(approvals, { recursive: true });
  writeFileSync(join(approvals, 'listening'), '');
  t.after(() => rmSync(home, { recursive: true, force: true }));

  const root = new Context();
  root.provide('connection');
  root.set('connection', { fetch: { register() { return () => {}; } } });
  const seen = [];
  root.on('user-questions/request', () => { seen.push('native'); return 'native-answer'; });
  const stop = [];
  apply({ effect: fn => { const d = fn(); if (typeof d === 'function') stop.push(d); }, on: (...a) => root.on(...a), connection: root.connection }, { directory });
  t.after(() => { for (const d of stop.reverse()) d(); });

  const agent = { session: { id: 'sess-9', cwd: '/tmp/proj' } };
  const dispatch = questions => root.waterfall(scopeTarget(root, agent), 'user-questions/request',
    { agent, questions }, () => 'no-provider');
  const requests = () => { try { return readdirSync(join(approvals, 'requests')).filter(f => f.endsWith('.json')); } catch { return []; } };

  // Pitwall 作答：原生应答方不触发。
  const pending = dispatch(twoQuestions);
  const file = await pendingRequest({ requests });
  const { id } = JSON.parse(readFileSync(join(approvals, 'requests', file)));
  writeFileSync(join(approvals, 'decisions', id), JSON.stringify({ answers: [{ id: 'q1', selected: ['A'] }, { id: 'q2', selected: [], custom: 'x' }] }));
  assert.deepEqual(await pending, { answers: [{ id: 'q1', selected: ['A'] }, { id: 'q2', selected: [], custom: 'x' }] });
  assert.deepEqual(seen, []);

  // 没有决定、超时让位：原生应答方接管并把结果传回瀑布。
  const timedOut = dispatch(twoQuestions);
  await pendingRequest({ requests });
  rmSync(join(approvals, 'listening'), { force: true });
  assert.equal(await timedOut, 'native-answer');
  assert.deepEqual(seen, ['native']);
});
