'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createMediaService } = require('../electron/media.cjs');

const ffmpeg = process.env.FFMPEG || (process.platform === 'darwin' ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg');
const ffprobe = process.env.FFPROBE || (process.platform === 'darwin' ? '/opt/homebrew/bin/ffprobe' : 'ffprobe');
const available = spawnSync(ffmpeg, ['-version'], { windowsHide: true }).status === 0;
const opts = { skip: !available, timeout: 180_000 };
let folder, source, silent, portrait, service, clips;
function run(args) {
  const result = spawnSync(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-filter_complex_threads', '2', ...args],
    { shell: false, windowsHide: true, maxBuffer: 2_000_000 });
  assert.equal(result.status, 0, result.stderr?.toString());
}
function rms(data, start, end) {
  let sum = 0, count = 0;
  for (let i = Math.round(start * 16000); i < Math.round(end * 16000); i++) { const v = data.readInt16LE(44 + i * 2) / 32768; sum += v * v; count++; }
  return Math.sqrt(sum / count);
}
async function rgb(file, seconds) {
  const result = spawnSync(ffmpeg, ['-v', 'error', '-ss', String(seconds), '-i', file, '-frames:v', '1', '-vf', 'scale=1:1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1'], { shell: false });
  assert.equal(result.status, 0, result.stderr.toString()); return [...result.stdout];
}
test.before(async () => {
  if (!available) return;
  folder = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-win-media-tests-'));
  source = path.join(folder, "颜色 '$() ;.mp4"); silent = path.join(folder, '静音.mp4'); portrait = path.join(folder, '旋转.mp4');
  run(['-f', 'lavfi', '-i', 'color=red:s=320x180:r=24:d=1', '-f', 'lavfi', '-i', 'color=blue:s=320x180:r=24:d=1',
    '-f', 'lavfi', '-i', 'color=green:s=320x180:r=24:d=1', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=3',
    '-filter_complex', '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]', '-map', '[v]', '-map', '3:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', source]);
  run(['-f', 'lavfi', '-i', 'color=yellow:s=240x160:r=24:d=1', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', silent]);
  run(['-display_rotation:v:0', '90', '-i', silent, '-c', 'copy', portrait]);
  service = createMediaService({ ffmpeg, ffprobe, cacheDir: path.join(folder, 'cache') });
  clips = [{ sourcePath: source, sourceIn: 0.5, sourceOut: 2.5 }, { sourcePath: silent, sourceIn: 0, sourceOut: 1 }, { sourcePath: source, sourceIn: 2, sourceOut: 3 }];
});
test.after(async () => { if (folder) await fs.rm(folder, { recursive: true, force: true }); });

test('probe preserves metadata, audio and rotation; validates local inputs', opts, async () => {
  const value = await service.probe(source);
  assert.equal(value.duration, 3); assert.equal(value.frameRate, 24); assert.equal(value.width, 320); assert.equal(value.height, 180); assert.equal(value.hasAudio, true);
  const rotated = await service.probe(portrait); assert.equal(rotated.width, 160); assert.equal(rotated.height, 240); assert.equal(rotated.hasAudio, false);
  await assert.rejects(service.probe('https://example.com/file.mp4'), /本地/);
  await assert.rejects(service.probe(path.join(folder, 'missing.mp4')), /找不到/);
});
test('playback produces H264 AAC cache without changing the source; cache invalidates on stat change', opts, async () => {
  const before = await fs.readFile(source);
  const a = await service.playback(source); const b = await service.playback(source);
  assert.equal(a, b); assert.notEqual(a, source); assert.deepEqual(await fs.readFile(source), before);
  const info = await service.probe(a); assert.equal(info.hasAudio, true); assert.ok(Math.abs(info.duration - 3) < 0.05);
  const codecs = spawnSync(ffprobe, ['-v', 'error', '-show_entries', 'stream=codec_name', '-of', 'json', a]);
  const names = JSON.parse(codecs.stdout).streams.map(s => s.codec_name); assert.ok(names.includes('h264')); assert.ok(names.includes('aac'));
  const later = new Date(Date.now() + 10000); await fs.utimes(source, later, later);
  assert.notEqual(await service.playback(source), a);
});
test('thumbnail selects a real later frame and handles source orientation', opts, async () => {
  const frame = await service.thumbnail(source, 1.5); const pixel = await rgb(frame, 0);
  assert.ok(pixel[2] > 180 && pixel[0] < 50);
  const tail = await service.thumbnail(source, 999); assert.ok((await fs.stat(tail)).size > 0);
  assert.ok((await fs.stat(await service.thumbnail(portrait, 0.2))).size > 0);
  await assert.rejects(service.thumbnail(source, NaN), /时间/);
});
test('waveform is real PCM RMS and silent footage has no synthetic sound', opts, async () => {
  const values = await service.waveform(source, 80);
  assert.equal(values.length, 80); assert.ok(values.every(x => Number.isFinite(x) && x >= 0 && x <= 1));
  assert.ok(values[40] > 0.06 && values[40] < 0.11);
  assert.deepEqual(await service.waveform(silent), []);
  await assert.rejects(service.waveform(source, 30000), /分段/);
});
test('cut detection uses real visual scene changes', opts, async () => {
  const cuts = await service.detectCuts(source, { threshold: 0.25 });
  assert.ok(cuts.some(t => Math.abs(t - 1) <= 0.13), JSON.stringify(cuts));
  assert.ok(cuts.some(t => Math.abs(t - 2) <= 0.13), JSON.stringify(cuts));
  assert.ok(cuts.every((t, i) => t > 0 && t < 3 && (!i || t - cuts[i - 1] >= 0.3)));
});
test('original PCM follows trims and sequence, padding silent clips and clipping project-relative ranges', opts, async () => {
  const file = path.join(folder, 'original.wav');
  assert.equal(await service.extractAudio(clips, file), file);
  const data = await fs.readFile(file); assert.equal(data.toString('ascii', 0, 4), 'RIFF');
  assert.equal(data.readUInt32LE(24), 16000); assert.equal(data.readUInt16LE(22), 1); assert.equal(data.length, 44 + 4 * 32000);
  assert.ok(rms(data, 0.2, 0.5) > 0.05); assert.ok(rms(data, 2.2, 2.8) < 0.0001); assert.ok(rms(data, 3.2, 3.7) > 0.05);
  const range = path.join(folder, 'range.wav'); await service.extractAudio(clips, range, { start: 1.5, end: 3.5 });
  const selected = await fs.readFile(range); assert.equal(selected.length, 44 + 2 * 32000);
  assert.ok(rms(selected, 0.1, 0.4) > 0.05); assert.ok(rms(selected, 0.6, 1.4) < 0.0001); assert.ok(rms(selected, 1.6, 1.9) > 0.05);
});
test('analysis video preserves selected clip order, durations and 11 MB boundary', opts, async () => {
  const file = await service.prepareAnalysis(clips, { start: 1.5, end: 3.5 });
  try {
    const info = await service.probe(file); assert.ok(Math.abs(info.duration - 2) <= 0.05); assert.equal(info.hasAudio, false);
    assert.ok((await fs.stat(file)).size <= 11_000_000);
    const green = await rgb(file, 0.2), yellow = await rgb(file, 0.8), greenAgain = await rgb(file, 1.7);
    assert.ok(green[1] > 70 && green[0] < 50); assert.ok(yellow[0] > 150 && yellow[1] > 150); assert.ok(greenAgain[1] > 70 && greenAgain[0] < 50);
    assert.deepEqual(await fs.readdir(path.dirname(file)), [path.basename(file)]);
  } finally { await fs.rm(path.dirname(file), { recursive: true, force: true }); }
  await assert.rejects(service.prepareAnalysis(clips, { end: 301 }), /5 分钟/);
});
test('cancellation clears owned temporary files and preserves existing audio output', opts, async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(service.playback(source, { signal: controller.signal }), { name: 'AbortError' });
  const cacheDir = path.join(folder, 'cancel-cache'); const active = new AbortController();
  const cancellable = createMediaService({ ffmpeg, ffprobe, cacheDir, onProgress: p => { if (p.operation === 'extractAudio' && p.progress > 0) active.abort(); } });
  const output = path.join(folder, 'preserved.wav'); const original = Buffer.from('previous result'); await fs.writeFile(output, original);
  await assert.rejects(cancellable.extractAudio(clips, output, { signal: active.signal }), { name: 'AbortError' });
  assert.deepEqual(await fs.readFile(output), original); assert.deepEqual(await fs.readdir(cacheDir), []);
  assert.ok(!(await fs.readdir(folder)).some(x => x.startsWith('.jingdu-audio-')));
});
test('output cannot overwrite a source audio file through a hardlink', opts, async () => {
  const linked = path.join(folder, 'source-alias.wav'); await fs.link(source, linked);
  await assert.rejects(service.extractAudio(clips, linked), /原始素材/);
});

test('audio extraction retains an original delayed audio start as silence', opts, async () => {
  const delayed = path.join(folder, 'delayed.mp4');
  run(['-f', 'lavfi', '-i', 'color=blue:s=160x90:r=24:d=3', '-itsoffset', '0.6', '-f', 'lavfi', '-i',
    'sine=frequency=660:sample_rate=44100:duration=2', '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', delayed]);
  const output = path.join(folder, 'delayed.wav');
  await service.extractAudio([{ sourcePath: delayed, sourceIn: 0, sourceOut: 3 }], output);
  const data = await fs.readFile(output);
  assert.ok(rms(data, 0.1, 0.4) < 0.001); assert.ok(rms(data, 0.9, 1.3) > 0.05);
  assert.ok(rms(data, 2.8, 2.95) < 0.001);
});

test('five-minute moving picture stays complete below 11 MB; active encoder cancellation cleans up', opts, async () => {
  const pattern = path.join(folder, 'pattern.mp4'); const longer = path.join(folder, 'five-minutes.mp4');
  run(['-f', 'lavfi', '-i', 'testsrc2=s=640x360:r=24:d=5', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', pattern]);
  run(['-stream_loop', '59', '-i', pattern, '-c', 'copy', longer]);
  const longClips = [{ sourcePath: longer, sourceIn: 0, sourceOut: 300 }];
  const output = await service.prepareAnalysis(longClips);
  try {
    const stat = await fs.stat(output); const info = await service.probe(output);
    assert.ok(stat.size <= 11_000_000, `${stat.size} bytes`); assert.ok(Math.abs(info.duration - 300) < 0.05, `${info.duration} seconds`);
    console.log(`300-second analysis copy: ${stat.size} bytes, ${info.duration} seconds.`);
  } finally { await fs.rm(path.dirname(output), { recursive: true, force: true }); }
  const cacheDir = path.join(folder, 'active-cancel-cache'); const abort = new AbortController();
  const activeService = createMediaService({ ffmpeg, ffprobe, cacheDir });
  let sawEncoder = false;
  const poll = setInterval(async () => {
    const names = await fs.readdir(cacheDir).catch(() => []);
    for (const name of names.filter(x => x.startsWith('analysis-'))) {
      const stat = await fs.stat(path.join(cacheDir, name, 'part-0.mp4')).catch(() => null);
      if (stat?.size > 0) { sawEncoder = true; abort.abort(); }
    }
  }, 20);
  try { await assert.rejects(activeService.prepareAnalysis(longClips, { signal: abort.signal }), { name: 'AbortError' }); }
  finally { clearInterval(poll); }
  assert.equal(sawEncoder, true); assert.deepEqual(await fs.readdir(cacheDir), []);
});
