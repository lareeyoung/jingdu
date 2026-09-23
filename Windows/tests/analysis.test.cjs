'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createAnalysisService, expectedModelHash, expectedModelSize, _testing: t } = require('../electron/analysis.cjs');
const config = { baseURL: 'http://10.1.2.3:8801/v1/', appID: 'test-app', modelID: 'seed-test', providerModel: '', route: 'passthrough', timeout: 300 };
const key = 'FAKE-TEST-KEY';
const clip = { id: 'clip', title: 'sample', sourcePath: '/test.mp4', sourceDuration: 90, sourceIn: 5, sourceOut: 70, frameRate: 25, width: 1280, height: 720 };
const project = { id: 'project', title: 'sample', duration: 65, clips: [clip], music: [], originalVolume: 1 };
const cue = (id, language = 'en') => ({ id, start: id, end: id + .5, language, text: language === 'zh' ? '原生中文' : `line-${id}`, chineseText: '' });
const track = { id: 'track', createdAt: new Date().toISOString(), sourceClips: [clip], sourceDescription: '本地 Whisper small 原文', cues: [cue(0, 'zh'), cue(1), cue(2, 'ja')].map(c => ({ ...c, id: String(c.id) })) };
const reply = (content, finish_reason = 'stop') => new Response(JSON.stringify({ choices: [{ finish_reason, message: { content } }] }), { status: 200 });
const script = { title: '标题', synopsis: '梗概', structure: '结构', caveats: '依据成片，声音待核对', segments: [{ start: 0, end: 5,
  screenplay: '镜头中的人物起身。', visual: '人物', action: '起身', dialogue: '', dialogueCues: [], sound: '待核对', camera: '中景', transition: '切镜', reasoning: '分析', uncertainty: '估计时间' }] };

test('URL validation keeps HTTP private and rejects credential/query tricks', () => {
  for (const url of ['http://localhost:8888', 'http://127.0.0.1', 'http://172.16.0.4', 'http://192.168.2.4', 'http://[::1]', 'https://example.test/root']) assert.doesNotThrow(() => t.validateConfig({ ...config, baseURL: url }));
  for (const url of ['http://example.test', 'http://172.32.1.1', 'http://127.1', 'http://0177.0.0.1', 'http://0x7f000001', 'https://me:key@example.test', 'https://example.test?key=secret', 'https://example.test#secret']) assert.throws(() => t.validateConfig({ ...config, baseURL: url }));
  assert.throws(() => t.validateConfig({ ...config, appID: 'a\r\nx:bad' }));
  assert.throws(() => t.validateConfig({ ...config, timeout: 901 }));
});
test('model list uses canonical path, required auth, no redirects, deduplicated IDs', async () => {
  let request;
  const api = createAnalysisService({ fetchImpl: async (url, options) => { request = { url, options }; return new Response(JSON.stringify({ data: [{ id: 'b' }, { id: 'a' }, { id: 'b' }, {}] })); } });
  assert.deepEqual(await api.models(config, key), ['a', 'b']);
  assert.equal(request.url, 'http://10.1.2.3:8801/v1/models');
  assert.equal(request.options.method, 'GET'); assert.equal(request.options.redirect, 'manual');
  assert.equal(request.options.headers.Appid, config.appID); assert.equal(request.options.headers.Authorization, `Bearer ${key}`);
  assert.equal(request.options.headers['X-Model-Timeout'], '300');
});
test('provider error is redacted and HTTP 500 distinguishes upload timeout', async () => {
  const api = createAnalysisService({ fetchImpl: async () => new Response(JSON.stringify({ error: { message: `proxy:read req body error: i/o timeout ${key} Bearer stolen-other-key` } }), { status: 500 }) });
  await assert.rejects(api.models(config, key), error => /上传阶段超时/.test(error.message) && !error.message.includes(key) && !error.message.includes('stolen-other-key'));
  const redirect = createAnalysisService({ fetchImpl: async (_url, options) => { assert.equal(options.redirect, 'manual'); return new Response('', { status: 302 }); } });
  await assert.rejects(redirect.models(config, key), /跳转/);
});
test('cancellation reaches fetch, and oversized/truncated model results are refused', async () => {
  const controller = new AbortController();
  const api = createAnalysisService({ fetchImpl: (_url, options) => new Promise((_, reject) => { options.signal.addEventListener('abort', () => reject(Object.assign(new Error('abort'), { name: 'AbortError' }))); controller.abort(); }) });
  await assert.rejects(api.models(config, key, { signal: controller.signal }), { name: 'AbortError' });
  const large = createAnalysisService({ fetchImpl: async () => new Response('small', { headers: { 'content-length': String(9 * 1024 * 1024) } }) });
  await assert.rejects(large.models(config, key), /过大/);
  const truncated = createAnalysisService({ fetchImpl: async () => reply('{"translations":[]}', 'length') });
  await assert.rejects(truncated.translate(track, config, key), /截断/);
});
test('translation batches non-Chinese lines by stable integer indices, preserves original/time/id', async () => {
  let sent; const api = createAnalysisService({ fetchImpl: async (url, options) => {
    sent = { url, body: JSON.parse(options.body) }; return reply(JSON.stringify({ translations: [{ id: 2, chinese: '第二句' }, { id: 1, chinese: '第一句' }] }));
  } });
  const result = await api.translate(track, config, key);
  assert.match(sent.url, /v1\/model\/generations\?provider_model=seed-test$/);
  assert.equal(sent.body.thinking.type, 'disabled'); assert.equal(sent.body.max_tokens, 8000);
  const input = JSON.parse(sent.body.messages[0].content.split('输入：')[1]);
  assert.deepEqual(input.map(c => c.id), [1, 2]); assert.equal(result.cues[0].chineseText, '');
  assert.deepEqual(result.cues.map(c => ({ ...c, chineseText: '' })), track.cues);
  assert.equal(result.cues[1].chineseText, '第一句'); assert.equal(result.cues[2].chineseText, '第二句');
  assert.equal(track.cues[1].chineseText, ''); assert.match(result.sourceDescription, /Seed/);
});
test('Chinese-only tracks need no network; foreign duplicate/missing/wrong ids or unsupported output fail', async () => {
  const onlyChinese = { ...track, cues: [track.cues[0]] };
  const api = createAnalysisService({ fetchImpl: async () => assert.fail('Chinese must not be translated again') });
  assert.deepEqual((await api.translate(onlyChinese, null, null)).cues, onlyChinese.cues);
  const invalid = [
    { translations: [{ id: 1, chinese: '一' }, { id: 1, chinese: '二' }] },
    { translations: [{ id: 1, chinese: '一' }] },
    { translations: [{ id: 1, chinese: '一' }, { id: 8, chinese: '二' }] },
    { translations: [{ id: 1, chinese: 'English' }, { id: 2, chinese: '二' }] },
    { translations: [{ id: 1, chinese: '一', start: 8 }, { id: 2, chinese: '二' }] }
  ];
  for (const payload of invalid) {
    const service = createAnalysisService({ fetchImpl: async () => reply(JSON.stringify(payload)) });
    await assert.rejects(service.translate(track, config, key));
  }
});
test('script protocol has data video without fps, shared subtitle evidence, absolute output time', async () => {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-analysis-test-'));
  try {
    const video = path.join(folder, 'video.mp4'); await fs.writeFile(video, 'fixture');
    let sent, preparation;
    const api = createAnalysisService({ media: { prepareAnalysis: async (...args) => { preparation = args; return video; } }, fetchImpl: async (url, options) => { sent = { url, body: JSON.parse(options.body) }; return reply(JSON.stringify(script)); } });
    const current = { ...project, subtitleTrack: track };
    const result = await api.generateScript(current, { ...config, route: 'chatCompletions' }, key, { start: 1, end: 6 });
    assert.equal(sent.url, 'http://10.1.2.3:8801/v1/chat/completions');
    assert.deepEqual(Object.keys(sent.body.messages[0].content[1].video_url), ['url']);
    assert.match(sent.body.messages[0].content[0].text, /"original":"line-1"/);
    assert.match(sent.body.messages[0].content[0].text, /本次已有有效共享字幕/);
    assert.equal(result.segments[0].start, 1); assert.equal(result.segments[0].end, 6);
    assert.equal(result.subtitleTrackID, track.id); assert.deepEqual(result.segments[0].dialogueCues, []);
    assert.equal(preparation[1].start, 1); assert.equal(preparation[1].end, 6);
    await assert.rejects(api.generateScript(project, config, key, { start: 1, end: 70 }), /范围/);
    await fs.truncate(video, 11_000_001);
    await assert.rejects(api.generateScript(project, config, key, { start: 1, end: 6 }), /11 MB/);
  } finally { await fs.rm(folder, { recursive: true, force: true }); }
});
test('stale subtitle evidence is excluded; shared cues cannot be overwritten by model copies', () => {
  const stale = { ...project, subtitleTrack: { ...track, sourceClips: [{ ...clip, sourceIn: 6 }] } };
  assert.equal(t.currentTrack(stale), null); assert.match(t.scriptPrompt(stale, 0, 5, '', 'storyboard', null), /未取得原声台词/);
  const modified = structuredClone(script); modified.segments[0].dialogue = '错误复制'; modified.segments[0].dialogueCues = [{ start: 0, end: 1, speaker: '', text: '错误复制' }];
  const result = t.parseScript(JSON.stringify(modified), project, 0, 5, 'seed', track);
  assert.equal(result.segments[0].dialogue, ''); assert.deepEqual(result.segments[0].dialogueCues, []);
});
test('script video copies are released after success, network failure and cancellation', async () => {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-script-cleanup-'));
  try {
    for (const outcome of ['success', 'failure', 'cancel']) {
      const video = path.join(folder, outcome + '.mp4'); await fs.writeFile(video, 'fixture');
      const controller = new AbortController(); let released = 0;
      const api = createAnalysisService({ media: {
        prepareAnalysis: async () => video,
        releaseAnalysis: async file => { assert.equal(file, video); ++released; await fs.rm(file); }
      }, fetchImpl: async () => {
        if (outcome === 'failure') throw new Error('offline');
        if (outcome === 'cancel') controller.abort();
        return reply(JSON.stringify(script));
      } });
      const operation = api.generateScript(project, config, key, { start: 0, end: 5, signal: controller.signal });
      if (outcome === 'success') await operation; else await assert.rejects(operation);
      assert.equal(released, 1); await assert.rejects(fs.access(video));
    }
  } finally { await fs.rm(folder, { recursive: true, force: true }); }
});
test('JSON duplicate keys and script nonfinite/overlapping/out-of-bounds values are rejected', () => {
  assert.throws(() => t.parseJSON('{"translations":[{"id":1,"id":2}]}'), /重复/);
  assert.throws(() => t.parseJSON('{"a":1,"\u0061":2}'), /重复/);
  for (const pair of [[-1, 1], [1, 1], [0, 6], ['0', 1]]) {
    const bad = structuredClone(script); [bad.segments[0].start, bad.segments[0].end] = pair;
    assert.throws(() => t.parseScript(JSON.stringify(bad), project, 0, 5, 'seed', null));
  }
  const overlap = structuredClone(script); overlap.segments.push({ ...overlap.segments[0], start: 4 });
  assert.throws(() => t.parseScript(JSON.stringify(overlap), project, 0, 5, 'seed', null));
});
test('Whisper windows offset accurately, clamp decoder padding, preserve real speech and skip blank markers', () => {
  const output = { result: { language: 'en' }, transcription: [
    { offsets: { from: 0, to: 0 }, text: '[BLANK_AUDIO]' },
    { offsets: { from: 100, to: 1000 }, text: 'Hello' },
    { offsets: { from: 1000, to: 1000 }, text: ',' },
    { offsets: { from: 1010, to: 30000 }, text: 'world' },
    { offsets: { from: 30000, to: 30100 }, text: 'padding' }
  ] };
  const cues = t.parseWhisper(output, 30, 29.98);
  assert.deepEqual(cues.map(c => [c.start, c.end, c.text, c.chineseText]), [[30.1, 31, 'Hello,', ''], [31.01, 30 + 29.98, 'world', '']]);
  const conflict = structuredClone(output); conflict.transcription[3].offsets.from = 800;
  assert.throws(() => t.parseWhisper(conflict, 0, 30), /时间/);
  const point = { result: { language: 'zh' }, transcription: [{ offsets: { from: 0, to: 0 }, text: '你' }, { offsets: { from: 0, to: 100 }, text: '好' }] };
  assert.equal(t.parseWhisper(point, 60, 1)[0].text, '你好');
  point.transcription.pop(); assert.throws(() => t.parseWhisper(point, 0, 1), /对齐/);
  for (const lang of ['zh', 'en', 'ja', 'ko', 'es', 'fr']) assert.doesNotThrow(() => t.parseWhisper({ result: { language: lang }, transcription: [] }, 0, 1));
  assert.throws(() => t.parseWhisper({ result: { language: 'de' }, transcription: [] }, 0, 1));
});
function wave(seconds, sample = 100) {
  const count = Math.round(seconds * 16000), wav = Buffer.alloc(44 + count * 2);
  wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8); wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24); wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(count * 2, 40);
  for (let i = 44; i < wav.length; i += 2) wav.writeInt16LE(sample, i); return wav;
}
test('transcribe service uses 30-second source-audio windows and cleans every temporary file', async () => {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-whisper-test-'));
  try {
    // Sparse fixture models permit header/runtime validation without a real model or model call.
    const model = path.join(folder, 'fixture-model.bin'), handle = await fs.open(model, 'w');
    const header = Buffer.alloc(48); header.writeUInt32LE(0x67676d6c, 0); header.writeUInt32LE(51865, 4); header.writeUInt32LE(768, 12); header.writeUInt32LE(12, 20);
    await handle.write(header); await handle.truncate(expectedModelSize); await handle.close();
    const windows = [], files = [];
    const api = createAnalysisService({ modelPath: model, whisperPath: 'fixture-whisper', media: { extractAudio: async (clips, out, options) => {
      assert.deepEqual(clips, project.clips); windows.push([options.start, options.end]); files.push(out);
      await fs.writeFile(out, wave(options.end - options.start)); return out;
    } }, runWhisper: async (_executable, args) => {
      assert.equal(args[args.indexOf('-l') + 1], 'auto'); assert.ok(!args.includes('-tr'));
      await fs.writeFile(args[args.indexOf('-of') + 1] + '.json', JSON.stringify({ result: { language: 'en' }, transcription: [{ offsets: { from: 100, to: 200 }, text: 'Hi' }] }));
    } });
    const result = await api.transcribe(project);
    assert.deepEqual(windows, [[0, 30], [30, 60], [60, 65]]);
    assert.deepEqual(result.cues.map(c => c.start), [.1, 30.1, 60.1]);
    assert.ok(result.cues.every(c => c.chineseText === '')); assert.match(result.sourceDescription, /尚未调用模型翻译/);
    for (const file of files) await assert.rejects(fs.access(file));
    assert.equal(expectedModelHash, '55356645c2b361a969dfd0ef2c5a50d530afd8d5');
    assert.equal(t.hasSignal(wave(1, 0), 1), false); assert.equal(t.hasSignal(wave(1), 1), true);
    assert.throws(() => t.hasSignal(wave(1), 2), /时长/);
  } finally { await fs.rm(folder, { recursive: true, force: true }); }
});
