'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createStorage, atomicJSON, readJSON } = require('../electron/storage.cjs');

// Deterministic opaque tokens model OS encryption. Never use real credentials,
// Electron safeStorage, user data directories, or the user's operating-system key store.
function mockSafeStorage() {
  const values = new Map();
  return {
    available: true, decryptCalls: 0, encryptCalls: 0, failDecrypt: false,
    isEncryptionAvailable() { return this.available; },
    encryptString(value) {
      this.encryptCalls++;
      const encrypted = Buffer.from(`opaque-test-ciphertext-${this.encryptCalls}`);
      values.set(encrypted.toString('hex'), value); return encrypted;
    },
    decryptString(buffer) {
      this.decryptCalls++;
      if (this.failDecrypt || !values.has(buffer.toString('hex'))) throw new Error('mock Windows account cannot decrypt');
      return values.get(buffer.toString('hex'));
    }
  };
}
async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-storage-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const safe = mockSafeStorage();
  return { directory, safe, store: createStorage(directory, safe), file: name => path.join(directory, name) };
}
const config = { baseURL: 'https://relay.example.test', appID: 'test-account-A', modelID: 'seed-fixture', route: 'passthrough', timeout: 300 };

test('empty storage returns defaults without creating or decrypting credentials', async t => {
  const { store, safe, directory } = await fixture(t);
  assert.deepEqual(await store.load(), []);
  const settings = await store.settings();
  assert.equal(settings.hasKey, false); assert.equal(settings.key, undefined);
  assert.equal(settings.modelID, 'doubao-seed-2-1-pro-260628');
  assert.equal(safe.decryptCalls, 0); assert.deepEqual(await fs.readdir(directory), []);
});
test('only opaque encrypted bytes persist; settings never return the Key', async t => {
  const { store, safe, directory, file } = await fixture(t);
  const key = 'FAKE-STORAGE-TEST-KEY-NEVER-REAL';
  await store.saveSettings({ ...config, key, hasKey: true, clearKey: false });
  const credential = JSON.parse(await fs.readFile(file('credential.json'), 'utf8'));
  assert.equal(credential.account, config.baseURL + '|' + config.appID);
  assert.equal(Buffer.from(credential.encrypted, 'base64').toString(), 'opaque-test-ciphertext-1');
  const storedSettings = JSON.parse(await fs.readFile(file('settings.json'), 'utf8'));
  for (const field of ['key', 'hasKey', 'clearKey']) assert.equal(Object.hasOwn(storedSettings, field), false);
  const settings = await store.settings(); assert.equal(settings.key, undefined); assert.equal(settings.hasKey, true);
  assert.equal(safe.encryptCalls, 1); assert.equal(safe.decryptCalls, 0);
  for (const name of await fs.readdir(directory)) assert.ok(!(await fs.readFile(file(name), 'utf8')).includes(key), `${name} must not contain the fake plaintext Key`);
  assert.equal(await store.key(config), key); assert.equal(safe.decryptCalls, 1);
});
test('different relay address or account cannot trigger a decryption attempt', async t => {
  const { store, safe } = await fixture(t);
  await store.saveSettings({ ...config, key: 'FAKE-ACCOUNT-KEY' });
  await assert.rejects(store.key({ ...config, appID: 'other-account' }), /此服务/);
  await assert.rejects(store.key({ ...config, baseURL: 'https://other.example.test' }), /此服务/);
  assert.equal(safe.decryptCalls, 0);
  assert.equal(await store.key(config), 'FAKE-ACCOUNT-KEY');
});
test('unavailable OS encryption refuses Key writes and retains existing settings/credential', async t => {
  const { store, safe, file } = await fixture(t);
  await store.saveSettings({ ...config, key: 'FAKE-ORIGINAL-KEY' });
  const settingsBefore = await fs.readFile(file('settings.json'));
  const credentialBefore = await fs.readFile(file('credential.json'));
  safe.available = false;
  await assert.rejects(store.saveSettings({ ...config, modelID: 'changed', key: 'FAKE-REPLACEMENT-KEY' }), /未保存 Key/);
  assert.deepEqual(await fs.readFile(file('settings.json')), settingsBefore);
  assert.deepEqual(await fs.readFile(file('credential.json')), credentialBefore);
  await assert.rejects(store.key(config), /安全存储不可用/);
  assert.equal(safe.decryptCalls, 0);
});
test('wrong Windows account produces a safe error and does not replace encrypted data', async t => {
  const { store, safe, file } = await fixture(t);
  await store.saveSettings({ ...config, key: 'FAKE-WINDOWS-ACCOUNT-KEY' });
  const before = await fs.readFile(file('credential.json'));
  safe.failDecrypt = true;
  await assert.rejects(store.key(config), error => /当前 Windows 账户/.test(error.message) && !/FAKE|opaque|mock/.test(error.message));
  assert.deepEqual(await fs.readFile(file('credential.json')), before);
});
test('saving settings without a Key preserves it; explicit clear removes it', async t => {
  const { store, safe, file } = await fixture(t);
  await store.saveSettings({ ...config, key: 'FAKE-PRESERVED-KEY' });
  await store.saveSettings({ ...config, modelID: 'new-model', key: '' });
  assert.equal(await store.key(config), 'FAKE-PRESERVED-KEY'); assert.equal(safe.encryptCalls, 1);
  await store.saveSettings({ ...config, clearKey: true });
  await assert.rejects(fs.access(file('credential.json')), { code: 'ENOENT' });
  assert.equal((await store.settings()).hasKey, false);
  await assert.rejects(store.key(config), /保存此服务的 Key/);
});
test('library saves capture input immediately and retain the preceding successful version as backup', async t => {
  const { store, directory, file } = await fixture(t);
  const first = [{ id: 'project-1', title: 'first', notes: ['original'] }];
  const pending = store.save(first);
  first[0].title = 'mutated-after-save'; first[0].notes.push('later');
  await pending;
  assert.deepEqual(await store.load(), [{ id: 'project-1', title: 'first', notes: ['original'] }]);
  const second = [{ id: 'project-1', title: 'second', notes: ['original', 'next'] }];
  await store.save(second);
  assert.deepEqual(await store.load(), second);
  assert.deepEqual(await readJSON(file('library.json.backup')), [{ id: 'project-1', title: 'first', notes: ['original'] }]);
  assert.ok((await fs.readdir(directory)).every(name => !name.endsWith('.tmp')));
});
test('queued concurrent saves produce complete JSON and an ordered final backup', async t => {
  const { store, file, directory } = await fixture(t);
  await store.save([{ sequence: -1 }]);
  const values = Array.from({ length: 20 }, (_, sequence) => [{ sequence, body: '字'.repeat(1000) }]);
  let stopped = false, reads = 0;
  const watch = (async () => {
    while (!stopped) {
      const value = JSON.parse(await fs.readFile(file('library.json'), 'utf8'));
      assert.ok(Array.isArray(value) && value.length === 1); reads++;
    }
  })();
  try {
    const results = await Promise.allSettled(values.map(value => store.save(value)));
    for (const result of results) if (result.status === 'rejected') throw result.reason;
  }
  finally { stopped = true; await watch; }
  assert.ok(reads > 0);
  assert.deepEqual(await store.load(), values.at(-1));
  assert.deepEqual(await readJSON(file('library.json.backup')), values.at(-2));
  assert.ok((await fs.readdir(directory)).every(name => !name.endsWith('.tmp')));
});
test('atomic JSON failure preserves destination and cleans temporary output', async t => {
  const { file, directory } = await fixture(t);
  const blocked = file('blocked.json'); await fs.mkdir(blocked); await fs.writeFile(path.join(blocked, 'keep.txt'), 'untouched');
  await assert.rejects(atomicJSON(blocked, { shouldNotCommit: true }));
  assert.equal(await fs.readFile(path.join(blocked, 'keep.txt'), 'utf8'), 'untouched');
  assert.deepEqual(await fs.readdir(directory), ['blocked.json']);
  await atomicJSON(file('okay.json'), { valid: true });
  assert.deepEqual(await readJSON(file('okay.json')), { valid: true });
});
test('temporary Windows rename locks retry without removing the last good file', async t => {
  const { file } = await fixture(t), target = file('locked.json');
  await atomicJSON(target, { previous: true });
  const original = fs.rename; let attempts = 0;
  fs.rename = async (from, to) => {
    if (to === target && attempts++ < 12) {
      assert.deepEqual(await readJSON(target), { previous: true });
      throw Object.assign(new Error('temporary reader lock'), { code: 'EPERM' });
    }
    return original(from, to);
  };
  try { await atomicJSON(target, { updated: true }); }
  finally { fs.rename = original; }
  assert.equal(attempts, 13); assert.deepEqual(await readJSON(target), { updated: true });
});
test('malformed JSON never silently falls back or leaks contents in error text', async t => {
  const { file } = await fixture(t);
  const broken = '{"secret":"FAKE-PARSE-ONLY-KEY",'; await fs.writeFile(file('bad.json'), broken);
  await assert.rejects(readJSON(file('bad.json'), []), error => /已保留原文件/.test(error.message) && !error.message.includes('FAKE-PARSE'));
  assert.equal(await fs.readFile(file('bad.json'), 'utf8'), broken);
});
test('corrupt library discovered on load locks writes and preserves the last valid backup', async t => {
  const { store, file } = await fixture(t);
  const previous = '[{"id":"recoverable-project"}]', corrupt = '[{"id":"damaged-project",';
  await fs.writeFile(file('library.json.backup'), previous); await fs.writeFile(file('library.json'), corrupt);
  await assert.rejects(store.load(), /无法读取|损坏/);
  await assert.rejects(store.save([]), /无法读取|损坏|保留|备份/);
  assert.equal(await fs.readFile(file('library.json'), 'utf8'), corrupt);
  assert.equal(await fs.readFile(file('library.json.backup'), 'utf8'), previous);
});
test('library damaged after a successful load is detected before backup rotation or overwrite', async t => {
  const { store, file } = await fixture(t);
  await store.save([{ id: 'first' }]); await store.save([{ id: 'second' }]);
  const previous = await fs.readFile(file('library.json.backup'), 'utf8');
  assert.deepEqual(await store.load(), [{ id: 'second' }]);
  const corrupt = '[{"incomplete":'; await fs.writeFile(file('library.json'), corrupt);
  await assert.rejects(store.save([{ id: 'third' }]), /无法读取|损坏|保留|备份/);
  assert.equal(await fs.readFile(file('library.json'), 'utf8'), corrupt);
  assert.equal(await fs.readFile(file('library.json.backup'), 'utf8'), previous);
});
