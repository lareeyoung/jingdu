/** Portable, dependency-free Jingdu project model. All editing helpers are immutable.
 * Dates use whole-second ISO 8601 so Swift JSONDecoder.dateDecodingStrategy.iso8601
 * can read Windows exports. Source paths are references; this module does no I/O.
 */
export const noteTracks = Object.freeze([
  { id: 'story', title: '叙事逻辑', symbol: 'story' },
  { id: 'camera', title: '镜头设计', symbol: 'camera' },
  { id: 'sound', title: '声音设计', symbol: 'sound' },
  { id: 'learning', title: '学习启发', symbol: 'learning' },
].map(Object.freeze));

const DAY = 86400;
const EPS = 1e-7;
const languages = new Set(['zh', 'en', 'ja', 'ko', 'es', 'fr']);
const trackIDs = new Set(noteTracks.map(x => x.id));
const utf8 = new TextEncoder();
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
const newID = () => globalThis.crypto.randomUUID();
const fail = text => { throw new Error(text); };
const clamp = (n, a, b) => Math.max(a, Math.min(b, n));
const copy = value => structuredClone(value);

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label}必须是对象。`);
  return value;
}
function number(value, min, max, label, integer = false) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
    fail(`${label}无效，须在 ${min}–${max} 之间${integer ? '且为整数' : ''}。`);
  }
  return value;
}
function text(value, max, label, { required = false, fallback } = {}) {
  if (value === undefined && fallback !== undefined) value = fallback;
  if (typeof value !== 'string' || value.includes('\0') || value.length > max * 2 || [...value].length > max || (required && !value.trim())) {
    fail(`${label}${required ? '不能为空，' : ''}必须为不含空字符的文字，最多 ${max} 字。`);
  }
  return value;
}
function uuid(value, label) {
  if (value === undefined) return newID();
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) fail(`${label}不是有效 UUID。`);
  return value.toLowerCase();
}
function date(value, label) {
  if (value === undefined) return now();
  if (typeof value !== 'string') fail(`${label}必须为 ISO 8601 日期。`);
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) fail(`${label}必须为 ISO 8601 日期。`);
  const [, y, m, d, hh, mm, ss, zone] = match;
  const year = +y, month = +m, day = +d;
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1] || +hh > 23 || +mm > 59 || +ss > 59 ||
      (zone !== 'Z' && (+zone.slice(1, 3) > 23 || +zone.slice(4, 6) > 59)) || !Number.isFinite(Date.parse(value))) fail(`${label}不是有效日期。`);
  return new Date(value).toISOString().replace(/\.\d{3}Z$/, 'Z');
}
function list(value, max, label, fallback = []) {
  if (value === undefined) return fallback;
  if (!Array.isArray(value) || value.length > max) fail(`${label}必须为数组，最多 ${max} 项。`);
  return value;
}
function unique(items, label, key = x => x.id) {
  const ids = items.map(key);
  if (new Set(ids).size !== ids.length) fail(`${label}存在重复 ID。`);
  return items;
}
function path(value, label, allowEmpty = false) {
  value = text(value, 32767, label);
  if (allowEmpty && value === '') return value;
  // POSIX, Windows drive paths and UNC shares; never interpret a URL as media.
  if (!value.startsWith('/') && !/^[A-Za-z]:[\\/]/.test(value) && !/^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$)/.test(value)) fail(`${label}必须使用本机绝对路径。`);
  return value;
}
function duration(value, label) {
  number(value, 0, DAY, label);
  if (value === 0) fail(`${label}须大于 0。`);
  return value;
}
function interval(start, end, limit, label, point = false, lower = 0) {
  number(start, lower, limit, `${label}起点`);
  number(end, lower, limit, `${label}终点`);
  if (point ? end < start : end <= start) fail(`${label}终点必须${point ? '不小于' : '大于'}起点。`);
}
function optionalUUID(value, label) { return value == null ? null : uuid(value, label); }
function boolean(value, fallback, label) {
  if (value === undefined) return fallback;
  if (typeof value !== 'boolean') fail(`${label}必须为布尔值。`);
  return value;
}

function video(raw, label = '视频片段') {
  object(raw, label);
  const result = {
    id: uuid(raw.id, `${label} ID`),
    title: text(raw.title, 500, `${label}名称`, { fallback: '' }),
    sourcePath: path(raw.sourcePath, `${label}路径`),
    sourceDuration: duration(raw.sourceDuration, `${label}源时长`),
    sourceIn: raw.sourceIn, sourceOut: raw.sourceOut,
    frameRate: number(raw.frameRate, 1, 240, `${label}帧率`),
    width: number(raw.width, 1, 16384, `${label}宽度`, true),
    height: number(raw.height, 1, 16384, `${label}高度`, true),
    sourceProjectID: optionalUUID(raw.sourceProjectID, `${label}来源 ID`),
    sourceProjectTitle: raw.sourceProjectTitle == null ? null : text(raw.sourceProjectTitle, 500, `${label}来源名称`),
  };
  interval(result.sourceIn, result.sourceOut, result.sourceDuration, label);
  return result;
}
function music(raw, limit, label = '音乐') {
  object(raw, label);
  const result = {
    id: uuid(raw.id, `${label} ID`), title: text(raw.title, 500, `${label}名称`, { fallback: '' }),
    sourcePath: path(raw.sourcePath, `${label}路径`), sourceDuration: duration(raw.sourceDuration, `${label}源时长`),
    sourceIn: raw.sourceIn, sourceOut: raw.sourceOut,
    timelineStart: number(raw.timelineStart, 0, limit, `${label}时间轴起点`),
    volume: number(raw.volume === undefined ? 0.8 : raw.volume, 0, 1, `${label}音量`),
  };
  interval(result.sourceIn, result.sourceOut, result.sourceDuration, label);
  if (result.timelineStart + result.sourceOut - result.sourceIn > limit + EPS) fail(`${label}超出项目时长。`);
  return result;
}
function note(raw, limit) {
  object(raw, '笔记');
  if (!trackIDs.has(raw.track)) fail('笔记轨道无效。');
  interval(raw.start, raw.end, limit, '笔记', true);
  return {
    id: uuid(raw.id, '笔记 ID'), start: raw.start, end: raw.end, track: raw.track,
    title: text(raw.title, 500, '笔记标题', { fallback: '' }),
    body: text(raw.body, 200000, '笔记正文', { fallback: '' }),
    takeaway: text(raw.takeaway, 200000, '笔记启发', { fallback: '' }),
  };
}
function videos(value, label) {
  const items = unique(list(value, 10000, label).map(x => video(x, label)), label);
  if (!items.length) fail(`${label}不能为空。`);
  duration(items.reduce((sum, c) => sum + c.sourceOut - c.sourceIn, 0), `${label}总时长`);
  return items;
}
function cue(raw, limit, previousEnd = 0) {
  object(raw, '字幕');
  interval(raw.start, raw.end, limit, '字幕', false, previousEnd);
  if (!languages.has(raw.language)) fail('字幕语言无效。');
  const original = text(raw.text, 5000, '字幕原文', { required: true });
  const chinese = text(raw.chineseText, 5000, '字幕中文', { fallback: '' });
  if (raw.language === 'zh') {
    if (chinese.trim() && chinese.trim() !== original.trim()) fail('中文字幕无需另写不同译文。');
  // Local recognition can finish before optional translation. Preserve usable
  // source speech, but never accept a nonempty non-Chinese "translation".
  } else if (chinese.trim() && !/\p{Script=Han}/u.test(chinese)) fail('非中文字幕的译文必须包含中文，尚未翻译时请留空。');
  return { id: uuid(raw.id, '字幕 ID'), start: raw.start, end: raw.end, language: raw.language, text: original, chineseText: chinese };
}
function subtitle(raw) {
  object(raw, '字幕轨道');
  const sourceClips = videos(raw.sourceClips, '字幕视频快照');
  const limit = sourceClips.reduce((sum, c) => sum + c.sourceOut - c.sourceIn, 0);
  let previousEnd = 0;
  const cues = unique(list(raw.cues, 5000, '字幕').map(item => {
    const result = cue(item, limit, previousEnd); previousEnd = result.end; return result;
  }), '字幕');
  return {
    id: uuid(raw.id, '字幕轨道 ID'), createdAt: date(raw.createdAt, '字幕创建日期'), sourceClips, cues,
    sourceDescription: text(raw.sourceDescription, 5000, '字幕来源', { required: true, fallback: '导入字幕' }),
  };
}
function analysis(raw) {
  object(raw, '脚本分析');
  const sourceClips = videos(raw.sourceClips, '脚本视频快照');
  const limit = sourceClips.reduce((sum, c) => sum + c.sourceOut - c.sourceIn, 0);
  interval(raw.rangeStart, raw.rangeEnd, limit, '脚本分析');
  const result = {
    id: uuid(raw.id, '脚本 ID'), createdAt: date(raw.createdAt, '脚本创建日期'),
    modelID: text(raw.modelID, 200, '模型名称', { required: true }), sourceClips,
    rangeStart: raw.rangeStart, rangeEnd: raw.rangeEnd,
    title: text(raw.title, 500, '脚本标题', { required: true }),
    synopsis: text(raw.synopsis, 200000, '脚本梗概', { fallback: '' }),
    structure: text(raw.structure, 200000, '脚本结构', { fallback: '' }),
    caveats: text(raw.caveats, 200000, '脚本限制', { fallback: '' }),
    inputMode: text(raw.inputMode, 100, '脚本输入方式', { required: true }),
    sourceMusic: unique(list(raw.sourceMusic, 10000, '脚本音乐快照').map(x => music(x, limit)), '脚本音乐快照'),
    originalVolume: number(raw.originalVolume === undefined ? 1 : raw.originalVolume, 0, 1, '脚本原声音量'),
    timelineNoteIDs: unique(list(raw.timelineNoteIDs, 100000, '脚本关联笔记').map(x => uuid(x, '脚本关联笔记 ID')), '脚本关联笔记', x => x),
  };
  let previousEnd = result.rangeStart;
  const dialogueIDs = new Set();
  let byteCount = utf8.encode(result.title + result.synopsis + result.structure + result.caveats).length;
  result.segments = unique(list(raw.segments, 2000, '脚本段落').map(item => {
    object(item, '脚本段落'); interval(item.start, item.end, result.rangeEnd, '脚本段落', false, previousEnd);
    const segment = { id: uuid(item.id, '脚本段落 ID'), start: item.start, end: item.end };
    for (const key of ['visual', 'action', 'dialogue', 'sound', 'camera', 'transition', 'reasoning', 'uncertainty', 'screenplay']) {
      segment[key] = text(item[key], 20000, `脚本 ${key}`, { fallback: '' });
      byteCount += utf8.encode(segment[key]).length;
    }
    let cueEnd = segment.start;
    segment.dialogueCues = list(item.dialogueCues, 200, '段落台词').map(item => {
      object(item, '台词'); interval(item.start, item.end, segment.end, '台词', false, cueEnd);
      const value = { id: uuid(item.id, '台词 ID'), start: item.start, end: item.end,
        speaker: text(item.speaker, 200, '说话人', { fallback: '' }), text: text(item.text, 5000, '台词内容', { required: true }) };
      if (dialogueIDs.has(value.id)) fail('脚本台词存在重复 ID。');
      dialogueIDs.add(value.id); cueEnd = value.end;
      byteCount += utf8.encode(value.speaker + value.text).length;
      return value;
    });
    previousEnd = segment.end;
    return segment;
  }), '脚本段落');
  if (!result.segments.length) fail('脚本至少需要一个段落。');
  if (dialogueIDs.size > 10000 || byteCount > 4 * 1024 * 1024) fail('脚本文字或台词数量过多。');
  return result;
}

/** Accepts a decoded Mac library array, one project, or its JSON representation. */
export function normalizeLibrary(input) {
  if (typeof input === 'string') {
    if (utf8.encode(input).length > 100 * 1024 * 1024) fail('作品库超过 100 MB。');
    try { input = JSON.parse(input); } catch { fail('作品库不是有效 JSON。'); }
  }
  const raws = Array.isArray(input) ? input : [input];
  return unique(list(raws, 10000, '作品库').map(raw => {
    object(raw, '项目');
    const isDemo = boolean(raw.isDemo, false, '演示项目标记');
    const result = {
      id: uuid(raw.id, '项目 ID'), title: text(raw.title, 500, '项目名称', { required: true }),
      sourcePath: path(raw.sourcePath, '项目源路径', isDemo), duration: duration(raw.duration, '项目时长'),
      frameRate: number(raw.frameRate, 1, 240, '项目帧率'),
      width: number(raw.width, 1, 16384, '项目宽度', true), height: number(raw.height, 1, 16384, '项目高度', true),
      createdAt: date(raw.createdAt, '项目创建日期'), updatedAt: date(raw.updatedAt, '项目更新日期'), isDemo,
      kind: raw.kind === undefined ? 'study' : raw.kind,
      originalVolume: number(raw.originalVolume === undefined ? 1 : raw.originalVolume, 0, 1, '原声音量'),
    };
    if (!['study', 'remix'].includes(result.kind)) fail('项目类型无效。');
    result.clips = unique(list(raw.clips, 10000, '视频片段').map(x => video(x)), '视频片段');
    if (result.clips.length) {
      const total = result.clips.reduce((sum, c) => sum + c.sourceOut - c.sourceIn, 0);
      if (Math.abs(total - result.duration) > Math.max(1e-6, total * 1e-9) || result.sourcePath !== result.clips[0].sourcePath) fail('项目时长或源路径与视频片段不一致。');
    }
    result.music = unique(list(raw.music, 10000, '音乐').map(x => music(x, result.duration)), '音乐');
    result.notes = unique(list(raw.notes, 100000, '笔记').map(x => note(x, result.duration)), '笔记');
    result.cuts = normalizedCuts(result, list(raw.cuts, 100000, '切点').map(x => number(x, 0, result.duration, '切点时间')));
    result.scriptAnalyses = unique(list(raw.scriptAnalyses, 20, '脚本分析').map(analysis), '脚本分析');
    result.subtitleTrack = raw.subtitleTrack == null ? null : subtitle(raw.subtitleTrack);
    return result;
  }), '作品库项目');
}

/** Legacy projects expose a stable synthetic clip whose identity is project.id. */
export function clipsOf(project) {
  if (project.clips?.length) return project.clips;
  if (!Number.isFinite(project.duration) || project.duration <= 0) return [];
  return [{ id: project.id, title: project.title, sourcePath: project.sourcePath,
    sourceDuration: project.duration, sourceIn: 0, sourceOut: project.duration,
    frameRate: project.frameRate, width: project.width, height: project.height,
    sourceProjectID: project.id, sourceProjectTitle: project.title }];
}

export function placements(project) {
  let start = 0;
  return clipsOf(project).map(clip => {
    const end = start + (clip.sourceOut - clip.sourceIn);
    const value = { clip, start, end }; start = end; return value;
  });
}

/** Half-open clip intervals: a seam belongs to the next clip; EOF to the last. */
export function locateTime(project, time) {
  const items = placements(project);
  if (!items.length) return null;
  const timeInProject = clamp(Number.isFinite(time) ? time : 0, 0, project.duration);
  let index = items.findIndex(item => timeInProject >= item.start && timeInProject < item.end);
  if (index < 0) index = items.length - 1;
  const { clip, start, end } = items[index];
  return { clip, index, sourceTime: clamp(clip.sourceIn + timeInProject - start, clip.sourceIn, clip.sourceOut), start, end };
}

function normalizedCuts(project, cuts) {
  const result = [];
  for (const value of cuts) {
    if (!Number.isFinite(value) || value <= 0 || value >= project.duration) continue;
    const located = locateTime(project, value);
    if (!located) continue;
    const rate = located.clip.frameRate;
    const source = Math.round(located.sourceTime * rate) / rate;
    const snapped = located.start + source - located.clip.sourceIn;
    if (snapped > located.start + EPS && snapped < located.end - EPS) result.push(snapped);
  }
  return result.sort((a, b) => a - b).filter((x, i, xs) => i === 0 || Math.abs(x - xs[i - 1]) >= EPS);
}

export function shots(project) {
  if (!Number.isFinite(project.duration) || project.duration <= 0) return [];
  const seams = placements(project).slice(1).map(x => x.start);
  // Even a very short valid clip owns a seam. Only identical boundaries can
  // collapse; applying the cut snap tolerance here would erase short clips.
  const interior = [...new Set([...normalizedCuts(project, project.cuts ?? []), ...seams])].sort((a, b) => a - b);
  const edges = [0, ...interior, project.duration];
  return edges.slice(0, -1).map((start, index) => ({ index, start, end: edges[index + 1] }));
}

export function shotAt(project, time) {
  const items = shots(project);
  if (!items.length) return null;
  const value = clamp(Number.isFinite(time) ? time : 0, 0, project.duration);
  return items.find(item => value >= item.start && value < item.end) ?? items[items.length - 1];
}

export function addCut(project, time) {
  return { ...project, cuts: normalizedCuts(project, [...(project.cuts ?? []), time]), updatedAt: now() };
}
export function removeCut(project, time) {
  const target = normalizedCuts(project, [time])[0];
  return { ...project, cuts: normalizedCuts(project, project.cuts ?? []).filter(x => target === undefined || Math.abs(x - target) >= EPS), updatedAt: now() };
}

export function createProject(metas, { title, combined = false } = {}) {
  list(metas, 10000, '导入素材');
  if (!metas?.length) fail('请至少选择一个视频。');
  if (!combined && metas.length !== 1) fail('合并多个视频时请启用 combined。');
  const id = newID();
  const clips = metas.map(meta => {
    object(meta, '视频元数据');
    return video({ id: newID(), title: meta.title ?? String(meta.path ?? '').split(/[\\/]/).pop(), sourcePath: meta.path,
      sourceDuration: meta.duration, sourceIn: 0, sourceOut: meta.duration,
      frameRate: meta.frameRate, width: meta.width, height: meta.height });
  });
  const first = clips[0];
  return normalizeLibrary({ id, title: title ?? (clips.length === 1 ? first.title : `${first.title} 等 ${clips.length} 个素材`),
    sourcePath: first.sourcePath, duration: clips.reduce((sum, c) => sum + c.sourceOut - c.sourceIn, 0),
    frameRate: first.frameRate, width: first.width, height: first.height, clips, cuts: [], notes: [] })[0];
}

export function createNote(project, { time = 0, track = 'camera', start, end } = {}) {
  const from = start === undefined ? time : start;
  const until = end === undefined ? Math.min(project.duration, Math.max(from + 0.5, shotAt(project, from)?.end ?? from)) : end;
  return note({ start: from, end: until, track, title: '', body: '', takeaway: '' }, project.duration);
}

export function noteTitle(note) {
  if (note.title?.trim()) return note.title.trim();
  for (const field of [note.body, note.takeaway]) {
    const line = field?.split(/\r\n|[\r\n]/).find(x => x.trim());
    if (line) return line.trim();
  }
  return `${noteTracks.find(x => x.id === note.track)?.title ?? '笔记'} · ${formatTime(note.start)}`;
}

function sameClips(left, right) {
  const keys = ['sourcePath', 'sourceDuration', 'sourceIn', 'sourceOut', 'frameRate', 'width', 'height'];
  return left?.length > 0 && left.length === right.length && left.every((clip, i) => keys.every(key => clip[key] === right[i][key]));
}
/** A boolean. Stale subtitle tracks remain in the project for export/recovery. */
export function subtitleCurrent(project) {
  return !!project.subtitleTrack && sameClips(project.subtitleTrack.sourceClips, clipsOf(project));
}

export function scriptCurrent(project, value) {
  if (!value || !sameClips(value.sourceClips, clipsOf(project)) || value.rangeStart < 0 || value.rangeEnd > project.duration ||
      (value.originalVolume ?? 1) !== (project.originalVolume ?? 1)) return false;
  const old = value.sourceMusic ?? [], current = project.music ?? [];
  const keys = ['sourcePath', 'sourceDuration', 'sourceIn', 'sourceOut', 'timelineStart', 'volume'];
  return old.length === current.length && old.every((item, index) => keys.every(key => item[key] === current[index][key]));
}

/** Collects a continuous timeline interval, preserving source coordinates and provenance. */
export function collectRange(project, start, end, title) {
  interval(start, end, project.duration, '收集范围');
  const source = normalizeLibrary(project)[0];
  const clips = placements(source).flatMap(item => {
    const from = Math.max(start, item.start), until = Math.min(end, item.end);
    if (until <= from) return [];
    return [{ ...copy(item.clip), id: newID(),
      sourceIn: clamp(item.clip.sourceIn + from - item.start, item.clip.sourceIn, item.clip.sourceOut),
      sourceOut: clamp(item.clip.sourceIn + until - item.start, item.clip.sourceIn, item.clip.sourceOut),
      sourceProjectID: item.clip.sourceProjectID ?? source.id, sourceProjectTitle: item.clip.sourceProjectTitle ?? source.title }];
  });
  const first = clips[0], length = clips.reduce((sum, c) => sum + c.sourceOut - c.sourceIn, 0);
  const result = { id: newID(), title: title ?? `${source.title} · 灵感片段`, kind: 'remix', sourcePath: first.sourcePath,
    duration: length, frameRate: first.frameRate, width: first.width, height: first.height, clips,
    cuts: source.cuts.filter(x => x > start && x < end).map(x => x - start),
    notes: source.notes.flatMap(item => {
      // A point at the final source endpoint remains a clickable final marker.
      const point = item.start === item.end;
      if (point ? item.start < start || item.start > end : item.end <= start || item.start >= end) return [];
      return [{ ...copy(item), id: newID(), start: clamp(item.start - start, 0, length), end: clamp(item.end - start, 0, length) }];
    }), originalVolume: source.originalVolume, music: [], scriptAnalyses: [] };
  // Imported music is preserved and trimmed as data, even though first-release
  // Windows playback/export does not yet mix it.
  result.music = source.music.flatMap(item => {
    const from = Math.max(start, item.timelineStart), until = Math.min(end, item.timelineStart + item.sourceOut - item.sourceIn);
    if (until <= from) return [];
    return [{ ...copy(item), id: newID(), timelineStart: from - start,
      sourceIn: item.sourceIn + from - item.timelineStart, sourceOut: Math.min(item.sourceOut, item.sourceIn + until - item.timelineStart) }];
  });
  if (subtitleCurrent(source)) {
    result.subtitleTrack = { ...copy(source.subtitleTrack), id: newID(), createdAt: now(), sourceClips: copy(clips),
      cues: source.subtitleTrack.cues.flatMap(item => {
        const from = Math.max(start, item.start), until = Math.min(end, item.end);
        return until > from ? [{ ...copy(item), id: newID(), start: clamp(from - start, 0, length), end: clamp(until - start, 0, length) }] : [];
      }) };
  }
  return normalizeLibrary(result)[0];
}

/** Append a collected fragment without deleting earlier notes or script history.
 * Only currently aligned subtitles enter the new timeline; missing ranges stay
 * empty and are identified in the source description, never filled by guesses.
 */
export function appendCollection(destination, fragment) {
  const left = normalizeLibrary(destination)[0], right = normalizeLibrary(fragment)[0];
  const offset = left.duration;
  duration(offset + right.duration, '追加后的项目时长');
  const appendedClips = clipsOf(right).map(clip => ({ ...copy(clip), id: newID(),
    sourceProjectID: clip.sourceProjectID ?? right.id, sourceProjectTitle: clip.sourceProjectTitle ?? right.title }));
  const result = { ...copy(left), updatedAt: now(), kind: 'remix',
    clips: [...copy(clipsOf(left)), ...appendedClips], duration: offset + right.duration,
    cuts: [...left.cuts, ...right.cuts.map(time => time + offset)],
    notes: [...copy(left.notes), ...right.notes.map(item => ({ ...copy(item), id: newID(), start: item.start + offset, end: item.end + offset }))],
    music: [...copy(left.music), ...right.music.map(item => ({ ...copy(item), id: newID(), timelineStart: item.timelineStart + offset }))],
    // Old sourceClips snapshots intentionally remain untouched: scriptCurrent
    // will report them stale, while their original text stays available.
    scriptAnalyses: copy(left.scriptAnalyses),
  };
  const hasLeft = subtitleCurrent(left), hasRight = subtitleCurrent(right);
  if (hasLeft || hasRight) {
    const description = value => [...value].slice(0, 1800).join('');
    const leftSource = hasLeft ? description(left.subtitleTrack.sourceDescription) : '没有与当前素材一致的字幕，此区间留空。';
    const rightSource = hasRight ? description(right.subtitleTrack.sourceDescription) : '没有与当前素材一致的字幕，此区间留空。';
    result.subtitleTrack = {
      id: newID(), createdAt: now(), sourceClips: copy(result.clips),
      cues: [
        ...(hasLeft ? copy(left.subtitleTrack.cues) : []),
        ...(hasRight ? right.subtitleTrack.cues.map(item => ({ ...copy(item), id: newID(), start: item.start + offset, end: item.end + offset })) : []),
      ],
      sourceDescription: [
        '灵感追加：字幕仅保留各素材已有的有效记录，缺失或未识别的部分区间保持空白；没有补写台词。',
        `原空间（0–${offset} 秒）：${leftSource}`,
        `追加片段（${offset}–${result.duration} 秒）：${rightSource}`,
      ].join('\n'),
    };
  }
  return normalizeLibrary(result)[0];
}

export function activeCue(cues, time) {
  if (!Number.isFinite(time)) return null;
  return (cues ?? []).find(item => time >= item.start && time < item.end) ?? null;
}

export function cueLines(value, mode = 'bilingual') {
  if (!['original', 'chinese', 'bilingual'].includes(mode)) fail('字幕导出模式无效。');
  const original = value.text.trim().replace(/\r\n?/g, '\n');
  const chinese = (value.chineseText ?? '').trim().replace(/\r\n?/g, '\n');
  if (value.language === 'zh' || mode === 'original') return [original];
  if (mode === 'chinese') return [chinese];
  return original === chinese ? [original] : [original, chinese];
}

/** Millisecond rounding is performed before splitting into time components. */
export function toSRT(cues, mode = 'bilingual') {
  if (!['original', 'chinese', 'bilingual'].includes(mode)) fail('字幕导出模式无效。');
  let previousEnd = 0;
  const validated = unique(list(cues, 5000, '字幕').map(item => {
    const result = cue(item, DAY, previousEnd); previousEnd = result.end; return result;
  }), '字幕');
  if (mode !== 'original' && validated.some(item => item.language !== 'zh' && !item.chineseText.trim())) {
    fail('部分外语字幕尚未完成中文翻译。请先补全翻译，或选择只导出原文。');
  }
  const stamp = milliseconds => {
    const pad = (value, width = 2) => String(value).padStart(width, '0');
    return `${pad(Math.floor(milliseconds / 3600000))}:${pad(Math.floor(milliseconds / 60000) % 60)}:${pad(Math.floor(milliseconds / 1000) % 60)},${pad(milliseconds % 1000, 3)}`;
  };
  return validated.map((item, index) => {
    const start = Math.round(item.start * 1000), end = Math.round(item.end * 1000);
    if (end <= start) fail(`第 ${index + 1} 条字幕不足 1 毫秒，无法准确导出 SRT。`);
    return `${index + 1}\n${stamp(start)} --> ${stamp(end)}\n${cueLines(item, mode).join('\n')}\n`;
  }).join('\n');
}

/** Unified evidence timeline: current subtitles override model dialogue cues. */
export function sharedDialogues(project, selectedAnalysis) {
  if (subtitleCurrent(project)) return project.subtitleTrack.cues.map(item => ({ ...copy(item), speaker: '', source: 'subtitle' }));
  const selected = selectedAnalysis ?? [...(project.scriptAnalyses ?? [])].reverse().find(item => scriptCurrent(project, item));
  if (!scriptCurrent(project, selected)) return [];
  return selected.segments.flatMap(segment => (segment.dialogueCues ?? []).map(item => ({ ...copy(item),
    language: null, chineseText: '', source: 'script' }))).sort((a, b) => a.start - b.start);
}

export function formatTime(seconds, fps = 30) {
  const rate = Number.isFinite(fps) && fps >= 1 && fps <= 240 ? fps : 30;
  const frames = Math.round(clamp(Number.isFinite(seconds) ? seconds : 0, 0, DAY) * rate);
  const nominal = Math.round(rate), total = Math.floor(frames / nominal);
  const pad = n => String(n).padStart(2, '0');
  return `${pad(Math.floor(total / 3600))}:${pad(Math.floor(total / 60) % 60)}:${pad(total % 60)}:${pad(frames % nominal)}`;
}
