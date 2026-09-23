'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const MAX_ANALYSIS_BYTES = 11_000_000;
const MAX_DURATION = 86400;
const FORMATS = 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpegts,mpeg,mpegvideo,asf,flv,ogg,wav,mp3,aac,flac';
const INPUT = ['-protocol_whitelist', 'file,pipe', '-format_whitelist', FORMATS, '-threads', '2'];
const BASE = ['-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-nostats', '-filter_threads', '2', '-filter_complex_threads', '2'];
const number = value => Number(value).toFixed(8);
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
function aborted() { const e = new Error('媒体处理已取消。'); e.name = 'AbortError'; e.code = 'ABORT_ERR'; return e; }
function check(signal) { if (signal?.aborted) throw aborted(); }
function localPath(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.length > 16000 || /[\0\r\n]/.test(value)) {
    throw new Error('请选择有效的本地文件路径。');
  }
  return path.resolve(value);
}
function fraction(value) {
  const [a, b] = String(value || '0').split('/').map(Number);
  const result = b === undefined ? a : a / b;
  return Number.isFinite(result) && result > 0 ? result : 0;
}
function dimensions(info, long = 1280, short = 720) {
  const ratio = Math.min(1, long / Math.max(info.width, info.height), short / Math.min(info.width, info.height));
  return [Math.max(2, Math.floor(info.width * ratio / 2) * 2), Math.max(2, Math.floor(info.height * ratio / 2) * 2)];
}
function waveHeader(bytes) {
  const b = Buffer.alloc(44);
  b.write('RIFF'); b.writeUInt32LE(bytes + 36, 4); b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32);
  b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(bytes, 40);
  return b;
}

/** Local media only. onProgress receives {operation, progress}, throttled per operation.
 * prepareAnalysis returns an owned temporary MP4: the caller removes its parent
 * directory after upload. All other cached results may be reused. */
function createMediaService({ ffmpeg = 'ffmpeg', ffprobe = 'ffprobe', cacheDir, onProgress = () => {} }) {
  const root = localPath(cacheDir);
  for (const executable of [ffmpeg, ffprobe]) {
    if (typeof executable !== 'string' || !executable || executable.length > 16000 || /[\0\r\n]/.test(executable)) {
      throw new Error('媒体处理程序的位置无效。');
    }
  }
  const ready = fsp.mkdir(root, { recursive: true, mode: 0o700 });
  const metadata = new Map();
  let active = 0;
  const queue = [];
  function acquire(signal) {
    check(signal);
    if (active < 2) { active++; return Promise.resolve(); }
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, signal, cancel: null };
      entry.cancel = () => { const i = queue.indexOf(entry); if (i >= 0) queue.splice(i, 1); reject(aborted()); };
      signal?.addEventListener('abort', entry.cancel, { once: true });
      queue.push(entry);
    });
  }
  function release() {
    active--;
    const next = queue.shift();
    if (next) { next.signal?.removeEventListener('abort', next.cancel); active++; next.resolve(); }
  }
  function progress(operation) {
    let last = -1, at = 0;
    return value => {
      value = Math.max(last, Math.min(1, Math.max(0, value)));
      if (value !== 0 && value !== 1 && last > 0 && Date.now() - at < 120) return;
      if (value === last) return;
      last = value; at = Date.now();
      try { onProgress({ operation, progress: value }); } catch { /* Observers cannot break processing. */ }
    };
  }
  async function run(executable, args, { signal, timeout = 20 * 60_000, maxBytes = 2_000_000, onData, onLine } = {}) {
    if (args.length > 1024 || args.some(x => typeof x !== 'string' || x.includes('\0')) ||
        executable.length + args.reduce((sum, x) => sum + x.length + 3, 0) > 30000) {
      throw new Error('素材路径或处理参数过长，请缩短文件路径或减少片段。');
    }
    await acquire(signal);
    try {
      check(signal);
      return await new Promise((resolve, reject) => {
        let child, timer, escalation, failure, stderr = '', pending = '', count = 0;
        const chunks = [];
        function stop(error) {
          if (failure) return;
          failure = error;
          child?.kill('SIGTERM');
          escalation = setTimeout(() => child?.kill('SIGKILL'), 1500);
          escalation.unref();
        }
        const cancel = () => stop(aborted());
        try { child = spawn(executable, args, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }); }
        catch (e) { reject(new Error(`无法启动媒体程序：${e.message}`)); return; }
        signal?.addEventListener('abort', cancel, { once: true });
        if (signal?.aborted) cancel();
        timer = setTimeout(() => stop(new Error('媒体处理超时，请缩短范围或检查素材。')), timeout);
        child.stdout.on('data', data => {
          count += data.length;
          if (count > maxBytes) { stop(new Error('媒体程序输出异常，已停止处理。')); return; }
          try { if (onData) onData(data); else chunks.push(data); } catch (e) { stop(e); }
        });
        child.stderr.on('data', data => {
          const text = data.toString('utf8');
          stderr = (stderr + text).slice(-16000);
          pending += text;
          const lines = pending.split(/\r?\n/); pending = lines.pop().slice(-8000);
          for (const line of lines) { try { onLine?.(line); } catch (e) { stop(e); } }
        });
        child.on('error', e => { failure ||= new Error(`无法启动媒体程序，请检查 FFmpeg 安装：${e.message}`); });
        child.on('close', code => {
          clearTimeout(timer); clearTimeout(escalation); signal?.removeEventListener('abort', cancel);
          if (failure) reject(failure);
          else if (code !== 0) reject(new Error(`媒体处理失败（${code}）。${stderr.slice(-1800)}`));
          else resolve(Buffer.concat(chunks));
        });
      });
    } finally { release(); }
  }
  async function source(file, signal) {
    check(signal);
    const input = localPath(file);
    let real, stat;
    try { real = await fsp.realpath(input); stat = await fsp.stat(real); }
    catch { throw new Error(`找不到或无法读取素材：${path.basename(input)}`); }
    if (!stat.isFile() || stat.size <= 0) throw new Error('素材为空或不是普通文件。');
    return { path: real, key: hash(['media-v1', real, stat.size, stat.mtimeMs, stat.ctimeMs, stat.ino].join('|')), stat };
  }
  async function inspect(file, signal) {
    const s = await source(file, signal);
    if (metadata.has(s.key)) return { ...metadata.get(s.key), source: s };
    const data = await run(ffprobe, ['-v', 'error', ...INPUT, '-probesize', '32000000', '-analyzeduration', '10000000',
      '-show_entries', 'format=duration:stream=codec_type,width,height,avg_frame_rate,r_frame_rate,duration:stream_tags=rotate:stream_side_data=rotation',
      '-of', 'json', '-i', s.path], { signal, timeout: 30_000 });
    let json;
    try { json = JSON.parse(data.toString('utf8')); } catch { throw new Error('无法识别媒体信息。'); }
    const streams = Array.isArray(json.streams) ? json.streams : [];
    const v = streams.find(x => x.codec_type === 'video');
    const duration = Number(json.format?.duration) || Math.max(0, ...streams.map(x => Number(x.duration) || 0));
    if (!Number.isFinite(duration) || duration <= 0 || duration > MAX_DURATION) throw new Error('素材时长无效，支持 24 小时以内的媒体。');
    let width = Number(v?.width) || 0, height = Number(v?.height) || 0;
    const rotation = Number(v?.side_data_list?.find(x => x.rotation !== undefined)?.rotation ?? v?.tags?.rotate ?? 0);
    if (Math.abs(Math.round(rotation / 90)) % 2 === 1) [width, height] = [height, width];
    if (v && (width <= 0 || height <= 0 || Math.max(width, height) > 16384)) throw new Error('视频尺寸无效或过大。');
    const result = { duration, frameRate: fraction(v?.avg_frame_rate) || fraction(v?.r_frame_rate) || 30,
      width, height, hasAudio: streams.some(x => x.codec_type === 'audio'), videoDuration: Number(v?.duration) || duration };
    if (metadata.size > 256) metadata.delete(metadata.keys().next().value);
    metadata.set(s.key, result);
    return { ...result, source: s };
  }
  async function probe(file, { signal } = {}) {
    const { duration, frameRate, width, height, hasAudio } = await inspect(file, signal);
    return { duration, frameRate, width, height, hasAudio };
  }
  function videoOnly(info) { if (!info.width || !info.height) throw new Error('这份素材没有可读取的视频画面。'); }
  async function validCache(file) { try { const s = await fsp.lstat(file); return s.isFile() && !s.isSymbolicLink() && s.size > 0; } catch { return false; } }
  async function temporary(prefix) { await ready; return fsp.mkdtemp(path.join(root, `${prefix}-`)); }
  async function commit(temp, destination) {
    if (await validCache(destination)) return destination;
    try { await fsp.rename(temp, destination); }
    catch (e) { if (!(await validCache(destination))) throw e; }
    return destination;
  }
  function reportLine(report, duration) {
    return line => { const m = /^out_time_us=(\d+)/.exec(line); if (m) report(Math.min(0.99, Number(m[1]) / 1_000_000 / duration)); };
  }
  async function playback(file, { signal } = {}) {
    const report = progress('playback'); report(0);
    const info = await inspect(file, signal); videoOnly(info); await ready;
    const output = path.join(root, `playback-${info.source.key}.mp4`);
    if (await validCache(output)) { check(signal); report(1); return output; }
    const folder = await temporary('playback');
    try {
      const temp = path.join(folder, 'video.mp4');
      const [w, h] = dimensions(info, 1920, 1920);
      const fps = Math.min(60, Math.max(1, info.frameRate));
      await run(ffmpeg, [...BASE, '-progress', 'pipe:2', ...INPUT, '-i', info.source.path,
        '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn', '-map_metadata', '-1',
        '-vf', `scale=${w}:${h},setsar=1,fps=${number(fps)}`, '-c:v', 'libx264', '-threads', '2', '-preset', 'veryfast', '-crf', '21',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-movflags', '+faststart', temp],
      { signal, onLine: reportLine(report, info.duration) });
      check(signal); const result = await commit(temp, output); report(1); return result;
    } finally { await fsp.rm(folder, { recursive: true, force: true }); }
  }
  async function thumbnail(file, seconds, { signal } = {}) {
    const report = progress('thumbnail'); report(0);
    const info = await inspect(file, signal); videoOnly(info); await ready;
    if (!Number.isFinite(seconds) || seconds < 0) throw new Error('截图时间无效。');
    const at = Math.min(seconds, Math.max(0, info.videoDuration - 1 / Math.max(1, info.frameRate)));
    const output = path.join(root, `frame-${info.source.key}-${hash(number(at)).slice(0, 16)}.jpg`);
    if (await validCache(output)) { check(signal); report(1); return output; }
    const folder = await temporary('thumbnail');
    try {
      const temp = path.join(folder, 'frame.jpg'); const [w, h] = dimensions(info, 640, 640);
      await run(ffmpeg, [...BASE, '-ss', number(at), ...INPUT, '-i', info.source.path,
        '-map', '0:v:0', '-frames:v', '1', '-an', '-vf', `scale=${w}:${h},setsar=1`, '-q:v', '3', '-update', '1', temp], { signal, timeout: 60_000 });
      if (!(await validCache(temp))) throw new Error('没有取得这一时刻的画面，请选择稍早的位置。');
      check(signal); const result = await commit(temp, output); report(1); return result;
    } finally { await fsp.rm(folder, { recursive: true, force: true }); }
  }
  async function waveform(file, bins = 1600, { signal } = {}) {
    if (!Number.isInteger(bins) || bins < 1 || bins > 20000) throw new Error('波形分段数须为 1–20000。');
    const report = progress('waveform'); report(0); const info = await inspect(file, signal);
    if (!info.hasAudio) { report(1); return []; }
    const sums = new Float64Array(bins), counts = new Uint32Array(bins);
    let carry = Buffer.alloc(0), sample = 0; const expected = Math.ceil(info.duration * 8000);
    await run(ffmpeg, [...BASE, ...INPUT, '-i', info.source.path, '-map', '0:a:0', '-vn',
      '-af', `aresample=8000:async=1:first_pts=0,apad,atrim=end=${number(info.duration)}`, '-ac', '1', '-ar', '8000', '-f', 'f32le', 'pipe:1'], {
      signal, maxBytes: (expected + 16000) * 4,
      onData(data) {
        const bytes = carry.length ? Buffer.concat([carry, data]) : data; const length = bytes.length - bytes.length % 4;
        for (let i = 0; i < length; i += 4) {
          const value = bytes.readFloatLE(i); const bin = Math.min(bins - 1, Math.floor(sample++ / expected * bins));
          if (Number.isFinite(value)) { sums[bin] += value * value; counts[bin]++; }
        }
        carry = Buffer.from(bytes.subarray(length)); report(Math.min(0.99, sample / expected));
      }
    });
    check(signal); report(1);
    return Array.from(sums, (value, i) => counts[i] ? Math.min(1, Math.sqrt(value / counts[i])) : 0);
  }
  async function detectCuts(file, { threshold = 0.32, signal } = {}) {
    if (!Number.isFinite(threshold) || threshold < 0.01 || threshold > 1) throw new Error('切镜灵敏度应为 0.01–1。');
    const report = progress('detectCuts'); report(0); const info = await inspect(file, signal); videoOnly(info);
    const sampleFPS = Math.min(8, 3600 / info.duration); const cuts = [];
    await run(ffmpeg, [...BASE, '-loglevel', 'info', '-progress', 'pipe:2', ...INPUT, '-i', info.source.path, '-map', '0:v:0', '-an',
      '-vf', `fps=${number(sampleFPS)},scale=96:54,select='gt(scene,${number(threshold)})',showinfo`, '-f', 'null', '-'], {
      signal, onLine(line) {
        reportLine(report, info.duration)(line);
        if (!line.includes('showinfo')) return;
        const m = /pts_time:([\d.e+-]+)/.exec(line); if (!m) return;
        const t = Number(m[1]);
        if (Number.isFinite(t) && t >= 0.15 && t <= info.duration - 0.15 && (!cuts.length || t - cuts[cuts.length - 1] >= 0.3)) cuts.push(t);
      }
    });
    check(signal); report(1); return cuts;
  }
  async function selectedClips(clips, start, end, signal, limit = MAX_DURATION) {
    if (!Array.isArray(clips) || !clips.length || clips.length > 500) throw new Error('请选择 1–500 段视频素材。');
    if (!Number.isFinite(start) || start < 0 || (end !== undefined && (!Number.isFinite(end) || end <= start))) throw new Error('所选时间范围无效。');
    let total = 0; const all = [];
    for (const clip of clips) {
      check(signal); const info = await inspect(clip.sourcePath, signal); videoOnly(info);
      const sourceIn = clip.sourceIn ?? 0; const sourceOut = clip.sourceOut ?? (clip.duration === undefined ? info.duration : sourceIn + clip.duration);
      if (!Number.isFinite(sourceIn) || !Number.isFinite(sourceOut) || sourceIn < 0 || sourceOut <= sourceIn || sourceOut > info.duration + 0.05) throw new Error('素材的入点或出点超出实际视频时长。');
      const length = sourceOut - sourceIn;
      all.push({ info, sourceIn, length, timelineStart: total }); total += length;
      if (total > MAX_DURATION) throw new Error('作品总时长不能超过 24 小时。');
    }
    end ??= total;
    if (start >= total || end > total + 0.00001 || end - start > limit + 0.00001) throw new Error(limit === 300 ? '一次最多分析 5 分钟，请在作品范围内缩短选段。' : '所选范围超出作品时长。');
    const selected = all.flatMap(c => {
      const a = Math.max(start, c.timelineStart), b = Math.min(end, c.timelineStart + c.length);
      return b > a ? [{ ...c, sourceIn: c.sourceIn + a - c.timelineStart, length: b - a }] : [];
    });
    return { selected, all, duration: end - start };
  }
  async function protectOutput(output, all) {
    const resolved = await fsp.realpath(output).catch(() => output);
    const stat = await fsp.stat(output).catch(() => null);
    for (const clip of all) {
      if (resolved === clip.info.source.path || (process.platform === 'win32' && resolved.toLowerCase() === clip.info.source.path.toLowerCase()) ||
          (stat && stat.ino && stat.ino === clip.info.source.stat.ino && stat.dev === clip.info.source.stat.dev)) {
        throw new Error('输出位置指向原始素材，请更换文件名。');
      }
    }
  }
  async function writeAll(handle, buffer) {
    let offset = 0;
    while (offset < buffer.length) { const { bytesWritten } = await handle.write(buffer, offset, buffer.length - offset); if (!bytesWritten) throw new Error('临时磁盘无法写入。'); offset += bytesWritten; }
  }
  async function extractAudio(clips, outPath, { start = 0, end, signal } = {}) {
    const report = progress('extractAudio'); report(0); const output = localPath(outPath);
    if (path.extname(output).toLowerCase() !== '.wav') throw new Error('原声输出须使用 .wav 文件。');
    const plan = await selectedClips(clips, start, end, signal); await protectOutput(output, plan.all);
    await fsp.mkdir(path.dirname(output), { recursive: true });
    const folder = await temporary('audio'); const staging = path.join(path.dirname(output), `.jingdu-audio-${crypto.randomUUID()}.wav`);
    let handle;
    try {
      const totalSamples = Math.round(plan.duration * 16000); const totalBytes = totalSamples * 2;
      if (totalBytes + 36 > 0xffffffff) throw new Error('音频过长，请缩短范围。');
      handle = await fsp.open(staging, 'wx', 0o600); await writeAll(handle, waveHeader(totalBytes));
      let elapsed = 0, writtenSamples = 0;
      for (let i = 0; i < plan.selected.length; i++) {
        check(signal); const c = plan.selected[i]; elapsed += c.length;
        const frames = Math.round(elapsed * 16000) - writtenSamples; writtenSamples += frames;
        let remaining = frames * 2;
        if (c.info.hasAudio) {
          const pcm = path.join(folder, `part-${i}.pcm`);
          await run(ffmpeg, [...BASE, ...INPUT, '-i', c.info.source.path, '-map', '0:a:0', '-vn',
            '-af', 'aresample=16000:async=1:first_pts=0,apad', '-ss', number(c.sourceIn), '-t', number(frames / 16000),
            '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-f', 's16le', pcm], { signal });
          const stream = fs.createReadStream(pcm);
          try { for await (const chunk of stream) { check(signal); const part = chunk.subarray(0, remaining); await writeAll(handle, part); remaining -= part.length; if (!remaining) break; } }
          finally { stream.destroy(); }
          await fsp.rm(pcm, { force: true });
        }
        const zeros = Buffer.alloc(65536);
        while (remaining > 0) { check(signal); const n = Math.min(remaining, zeros.length); await writeAll(handle, zeros.subarray(0, n)); remaining -= n; }
        report(Math.min(0.99, elapsed / plan.duration));
      }
      await handle.close(); handle = null; check(signal); await protectOutput(output, plan.all);
      await fsp.rename(staging, output); report(1); return output;
    } finally { await handle?.close(); await fsp.rm(staging, { force: true }); await fsp.rm(folder, { recursive: true, force: true }); }
  }
  const preparedAnalyses = new Map();
  async function releaseAnalysis(file) {
    const folder = preparedAnalyses.get(file);
    if (!folder) return false;
    await fsp.rm(folder, { recursive: true, force: true });
    preparedAnalyses.delete(file);
    return true;
  }
  async function prepareAnalysis(clips, { start = 0, end, signal } = {}) {
    const report = progress('prepareAnalysis'); report(0);
    const plan = await selectedClips(clips, start, end, signal, 300);
    const folder = await temporary('analysis'); let complete = false;
    try {
      const [w, h] = dimensions(plan.all[0].info, plan.duration > 90 ? 960 : 1280, plan.duration > 90 ? 540 : 720);
      const bitrate = Math.floor(Math.min(2_200_000, 9_000_000 * 8 / plan.duration));
      const fps = 24; let elapsed = 0, emittedFrames = 0; const files = [];
      for (let i = 0; i < plan.selected.length; i++) {
        check(signal); const c = plan.selected[i]; elapsed += c.length;
        const frames = Math.round(elapsed * fps) - emittedFrames; emittedFrames += frames;
        if (!frames) continue;
        const name = `part-${i}.mp4`; const out = path.join(folder, name);
        await run(ffmpeg, [...BASE, ...INPUT, '-ss', number(c.sourceIn), '-t', number(c.length), '-i', c.info.source.path,
          '-map', '0:v:0', '-an', '-sn', '-dn', '-map_metadata', '-1', '-vf',
          `fps=${fps},scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,tpad=stop_mode=add:stop_duration=${number(c.length)},trim=end_frame=${frames},setpts=N/(${fps}*TB)`,
          '-frames:v', String(frames), '-c:v', 'libx264', '-threads', '2', '-preset', 'veryfast', '-b:v', String(bitrate),
          '-maxrate', String(bitrate), '-bufsize', String(bitrate * 2), '-pix_fmt', 'yuv420p', '-video_track_timescale', '24000', out], { signal });
        files.push(name); report(0.85 * elapsed / plan.duration);
      }
      if (!files.length) throw new Error('选中的范围不足一帧，请扩大范围。');
      const manifest = path.join(folder, 'parts.txt');
      await fsp.writeFile(manifest, files.map(name => `file '${name}'`).join('\n'));
      let output = path.join(folder, 'analysis.mp4');
      await run(ffmpeg, [...BASE, '-protocol_whitelist', 'file,pipe', '-f', 'concat', '-safe', '1', '-i', manifest,
        '-map', '0:v:0', '-an', '-c:v', 'copy', '-movflags', '+faststart', output], { signal });
      let stat = await fsp.stat(output);
      if (stat.size > MAX_ANALYSIS_BYTES) {
        const reduced = path.join(folder, 'analysis-small.mp4'); const lower = Math.floor(bitrate * 0.65);
        await run(ffmpeg, [...BASE, ...INPUT, '-i', output, '-an', '-c:v', 'libx264', '-threads', '2', '-preset', 'veryfast',
          '-b:v', String(lower), '-maxrate', String(lower), '-bufsize', String(lower * 2), '-pix_fmt', 'yuv420p', '-movflags', '+faststart', reduced], { signal });
        output = reduced; stat = await fsp.stat(output);
      }
      if (!stat.size || stat.size > MAX_ANALYSIS_BYTES) throw new Error('分析视频压缩后仍超过 11 MB，请缩短选段。');
      const info = await inspect(output, signal);
      if (Math.abs(info.duration - plan.duration) > 0.1) throw new Error('分析视频时长校验未通过，请缩短选段后重试。');
      check(signal);
      for (const name of await fsp.readdir(folder)) if (path.join(folder, name) !== output) await fsp.rm(path.join(folder, name), { force: true });
      check(signal); complete = true; preparedAnalyses.set(output, folder); report(1); return output;
    } finally { if (!complete) await fsp.rm(folder, { recursive: true, force: true }); }
  }
  return { probe, playback, thumbnail, waveform, detectCuts, extractAudio, prepareAnalysis, releaseAnalysis };
}

module.exports = { createMediaService };
