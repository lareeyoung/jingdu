'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { serveMediaFile, parseRange, CHUNK_SIZE } = require('../electron/media-protocol.cjs');

let folder, file;
const request = (headers = {}, options = {}) => new Request('jingdu://media/test-token', { headers, ...options });
before(async () => {
  folder = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-media-protocol-'));
  file = path.join(folder, 'clip.mp4');
  await fs.writeFile(file, 'abcdefghijklmnopqrstuvwxyz');
});
after(async () => { await fs.rm(folder, { recursive: true, force: true }); });

test('complete request advertises byte ranges and length', async () => {
  const response = await serveMediaFile(request(), file);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('accept-ranges'), 'bytes');
  assert.equal(response.headers.get('content-type'), 'video/mp4');
  assert.equal(response.headers.get('content-length'), '26');
  assert.equal(response.headers.get('content-range'), null);
  assert.equal(await response.text(), 'abcdefghijklmnopqrstuvwxyz');
});

test('seeks return 206, exact Content-Range/Length and matching bytes', async () => {
  for (const [range, contentRange, text] of [
    ['bytes=4-7', 'bytes 4-7/26', 'efgh'], ['bytes=20-', 'bytes 20-25/26', 'uvwxyz'],
    ['bytes=-3', 'bytes 23-25/26', 'xyz'], ['bytes=23-100', 'bytes 23-25/26', 'xyz'],
    ['bytes=-100', 'bytes 0-25/26', 'abcdefghijklmnopqrstuvwxyz'], ['bytes=0-0', 'bytes 0-0/26', 'a']
  ]) {
    const response = await serveMediaFile(request({ Range: range }), file);
    assert.equal(response.status, 206, range);
    assert.equal(response.headers.get('content-range'), contentRange);
    assert.equal(response.headers.get('content-length'), String(text.length));
    assert.equal(await response.text(), text);
  }
});

test('invalid, multiple and unsatisfiable ranges never serve misleading bytes', async () => {
  for (const range of ['bytes=26-', 'bytes=8-7', 'bytes=-0', 'bytes=-', 'bytes=1-2,4-5', 'items=0-2', 'bytes=9007199254740992-', 'bytes=1e3-']) {
    const response = await serveMediaFile(request({ Range: range }), file);
    assert.equal(response.status, 416, range);
    assert.equal(response.headers.get('content-range'), 'bytes */26');
    assert.equal(response.headers.get('content-length'), '0');
    assert.equal(await response.text(), '');
  }
});

test('HEAD ignores Range and returns metadata without a body', async () => {
  const response = await serveMediaFile(request({ Range: 'bytes=5-8' }, { method: 'HEAD' }), file);
  assert.equal(response.status, 200); assert.equal(response.headers.get('content-length'), '26');
  assert.equal(response.body, null);
});

test('empty files, unknown files, directories and unsupported methods are bounded', async () => {
  const empty = path.join(folder, 'empty.mp4'); await fs.writeFile(empty, '');
  const full = await serveMediaFile(request(), empty);
  assert.equal(full.status, 200); assert.equal(full.body, null); assert.equal(full.headers.get('content-length'), '0');
  const partial = await serveMediaFile(request({ Range: 'bytes=0-' }), empty);
  assert.equal(partial.status, 416); assert.equal(partial.headers.get('content-range'), 'bytes */0');
  assert.equal((await serveMediaFile(request(), path.join(folder, 'missing'))).status, 404);
  assert.equal((await serveMediaFile(request(), folder)).status, 404);
  const post = await serveMediaFile(request({}, { method: 'POST' }), file);
  assert.equal(post.status, 405); assert.equal(post.headers.get('allow'), 'GET, HEAD');
});

test('thumbnail and audio content types remain correct', async () => {
  for (const [name, mime] of [['thumb.JPG', 'image/jpeg'], ['sound.wav', 'audio/wav'], ['movie.webm', 'video/webm']]) {
    const source = path.join(folder, name); await fs.writeFile(source, 'fixture');
    const response = await serveMediaFile(request({}, { method: 'HEAD' }), source);
    assert.equal(response.headers.get('content-type'), mime);
  }
});

test('If-Range only slices a matching current Last-Modified representation', async () => {
  const head = await serveMediaFile(request({}, { method: 'HEAD' }), file);
  const matched = await serveMediaFile(request({ Range: 'bytes=4-7', 'If-Range': head.headers.get('last-modified') }), file);
  assert.equal(matched.status, 206); assert.equal(await matched.text(), 'efgh');
  for (const validator of ['Wed, 01 Jan 2020 00:00:00 GMT', '"unknown-etag"', 'invalid-date']) {
    const response = await serveMediaFile(request({ Range: 'bytes=4-7', 'If-Range': validator }), file);
    assert.equal(response.status, 200); assert.equal(await response.text(), 'abcdefghijklmnopqrstuvwxyz');
  }
});

test('large sparse video is read by bounded stream chunks and can seek to its tail', async () => {
  const large = path.join(folder, 'large.mp4'), size = 512 * 1024 * 1024;
  const handle = await fs.open(large, 'w');
  try { await handle.truncate(size); await handle.write(Buffer.from('tail'), 0, 4, size - 4); }
  finally { await handle.close(); }
  const response = await serveMediaFile(request(), large), reader = response.body.getReader();
  assert.equal(response.headers.get('content-length'), String(size));
  const first = await reader.read(); assert.equal(first.value.length, CHUNK_SIZE);
  await reader.cancel();
  const tail = await serveMediaFile(request({ Range: 'bytes=-4' }), large);
  assert.equal(tail.status, 206); assert.equal(tail.headers.get('content-range'), `bytes ${size - 4}-${size - 1}/${size}`);
  assert.equal(await tail.text(), 'tail');
  await fs.unlink(large);
});

test('aborted requests stop reads; cancelling a stream does not read the rest', async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(serveMediaFile(request({}, { signal: controller.signal }), file), { name: 'AbortError' });
  const source = path.join(folder, 'abort.mp4');
  const handle = await fs.open(source, 'w'); try { await handle.truncate(CHUNK_SIZE * 8); } finally { await handle.close(); }
  const during = new AbortController(), response = await serveMediaFile(request({}, { signal: during.signal }), source);
  const reader = response.body.getReader(); await reader.read(); during.abort();
  await assert.rejects(reader.read(), { name: 'AbortError' });
  const cancelled = await serveMediaFile(request(), source); await cancelled.body.cancel();
});

test('range arithmetic stays exact beyond 32-bit offsets', () => {
  assert.deepEqual(parseRange('bytes=4294967296-4294967299', 8589934592), { start: 4294967296, end: 4294967299 });
  assert.deepEqual(parseRange('bytes=-4', 8589934592), { start: 8589934588, end: 8589934591 });
});
