import test from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeLibrary, createProject, clipsOf, placements, shots, shotAt, locateTime,
  addCut, removeCut, createNote, collectRange, appendCollection, activeCue, toSRT, subtitleCurrent,
  sharedDialogues, formatTime, noteTracks, noteTitle, cueLines, scriptCurrent,
} from '../shared/model.mjs';

// No user files, browser, network, dependencies or fixtures outside this process.
const id = () => crypto.randomUUID();
const clone = value => structuredClone(value);
const near = (actual, expected, message = '') => assert.ok(Math.abs(actual - expected) < 1e-9, `${message}: ${actual} != ${expected}`);
const meta = (title = '测试视频', duration = 10, frameRate = 30) => ({
  title, path: `C:\\素材\\${title}.mp4`, duration, frameRate, width: 1920, height: 1080,
});
const legacy = () => ({
  id: '12345678-1234-1234-1234-123456789ABC', title: '旧 Mac 作品',
  sourcePath: '/Volumes/My PSSD/视频/成片.mp4', duration: 10, frameRate: 30, width: 1920, height: 1080,
  cuts: [3, 6], notes: [{ id: id(), start: 1, end: 2, track: 'camera', title: '视线', body: '方向连续', takeaway: '先建立位置' }],
  createdAt: '2026-09-20T08:04:03Z', updatedAt: '2026-09-20T08:04:03Z',
});
function sequence() {
  const value = createProject([meta('A', 20, 25), meta('B', 40, 24), meta('C', 30, 60)], { combined: true, title: '不同帧率的序列' });
  value.clips[0].sourceIn = 2.16; value.clips[0].sourceOut = 5.32; // 3.16 s
  value.clips[1].sourceIn = 10.25; value.clips[1].sourceOut = 14.25; // 4 s
  value.clips[2].sourceIn = 6.5; value.clips[2].sourceOut = 8.5; // 2 s
  value.duration = value.clips.reduce((s, c) => s + c.sourceOut - c.sourceIn, 0);
  return normalizeLibrary(value)[0];
}
function subtitles(project, cues = [
  { start: 1, end: 2.5, language: 'zh', text: '这是原话', chineseText: '' },
  { start: 3, end: 4.25, language: 'en', text: 'Hello there.', chineseText: '你好。' },
  { start: 6, end: 8, language: 'ja', text: 'こんにちは。', chineseText: '你好。' },
]) {
  return { id: id(), createdAt: '2026-09-20T08:04:03Z', sourceClips: clone(clipsOf(project)),
    sourceDescription: '测试转写', cues: cues.map(item => ({ id: id(), ...item })) };
}
function script(project) {
  return { id: id(), createdAt: '2026-09-20T08:04:03Z', modelID: 'mock-only', sourceClips: clone(clipsOf(project)),
    rangeStart: 0, rangeEnd: project.duration, title: '脚本快照', synopsis: '人物出现。', structure: '引入、发展。',
    caveats: '时间需核对。', inputMode: '测试', sourceMusic: [], originalVolume: 1, timelineNoteIDs: [],
    segments: [{ id: id(), start: 0, end: project.duration, visual: '人站在门边', action: '挥手', dialogue: '这是未定位的整段台词。',
      sound: '待核对', camera: '全景', transition: '直接切换', reasoning: '建立环境', uncertainty: '需核对', screenplay: 'INT. 房间 - 日',
      dialogueCues: [{ id: id(), start: 1, end: 2, speaker: '人物', text: 'Hello.' }] }] };
}

test('legacy Mac JSON gets compatible defaults, stable UUIDs and ISO dates without mutation', () => {
  const raw = legacy(), before = clone(raw);
  const [project] = normalizeLibrary(JSON.stringify(raw));
  assert.equal(project.id, raw.id.toLowerCase());
  assert.equal(project.kind, 'study'); assert.equal(project.originalVolume, 1);
  assert.deepEqual(project.clips, []); assert.deepEqual(project.music, []); assert.deepEqual(project.scriptAnalyses, []);
  assert.equal(project.subtitleTrack, null); assert.equal(project.isDemo, false);
  assert.equal(project.createdAt, raw.createdAt); assert.deepEqual(raw, before);
  assert.equal(clipsOf(project)[0].id, project.id);
  assert.equal(clipsOf(project)[0].sourceProjectID, project.id);
  assert.equal(clipsOf(project)[0].sourceProjectTitle, project.title);
  assert.equal(clipsOf(project)[0].sourceOut, 10);
  assert.deepEqual(normalizeLibrary(JSON.parse(JSON.stringify(project))), [project]);
  assert.deepEqual(noteTracks.map(x => x.id), ['story', 'camera', 'sound', 'learning']);
});

test('normalization rejects invalid numbers, dates, text, paths, enums and duplicate identities', () => {
  const base = legacy();
  const mutations = [
    x => x.duration = NaN, x => x.duration = Infinity, x => x.duration = 0, x => x.duration = 86401,
    x => x.frameRate = 0.9, x => x.frameRate = 241, x => x.frameRate = '30',
    x => x.width = 0, x => x.height = 16385, x => x.width = 10.5,
    x => x.title = '   ', x => x.title = '字'.repeat(501), x => x.title = 'bad\0title',
    x => x.sourcePath = 'relative/movie.mp4', x => x.sourcePath = 'https://example.com/movie.mp4',
    x => x.sourcePath = 'C:relative.mp4', x => x.sourcePath = 'C:\\a\0.mp4',
    x => x.id = 'not-uuid', x => x.createdAt = 10, x => x.createdAt = 'yesterday',
    x => x.updatedAt = '2025-02-29T00:00:00Z', x => x.updatedAt = '2026-02-30T00:00:00Z',
    x => x.updatedAt = '2026-01-01T25:00:00Z', x => x.kind = 'unknown', x => x.isDemo = 'true',
    x => x.originalVolume = -0.1, x => x.originalVolume = 1.1,
    x => x.cuts = [NaN], x => x.cuts = [11], x => x.cuts = [-1],
    x => x.notes[0].start = -1, x => x.notes[0].end = 11, x => x.notes[0].start = 3,
    x => x.notes[0].track = 'unknown', x => x.notes[0].body = '字'.repeat(200001),
    x => x.notes.push(clone(x.notes[0])), x => x.clips = null,
  ];
  for (const mutate of mutations) {
    const raw = clone(base); mutate(raw);
    assert.throws(() => normalizeLibrary(raw), undefined, `Must reject ${mutate}`);
  }
  assert.throws(() => normalizeLibrary([base, { ...base, id: base.id.toLowerCase() }]), /重复/);
  assert.throws(() => normalizeLibrary('{invalid JSON}'), /JSON/);
  assert.throws(() => normalizeLibrary(null), /对象/);
  assert.throws(() => normalizeLibrary(3), /对象/);
  assert.deepEqual(normalizeLibrary([]), []);
  for (const sourcePath of ['/tmp/本地.mov', 'D:/素材/本地.mp4', '\\\\server\\share\\movie.mp4']) {
    assert.equal(normalizeLibrary({ ...base, sourcePath })[0].sourcePath, sourcePath);
  }
  assert.equal(normalizeLibrary({ ...base, isDemo: true, sourcePath: '' })[0].sourcePath, '');
  assert.equal(normalizeLibrary({ ...base, createdAt: '2024-02-29T00:00:00.123+08:00' })[0].createdAt, '2024-02-28T16:00:00Z');
});

test('createProject creates validated sequences and refuses ambiguous or invalid inputs', () => {
  const single = createProject([meta()]);
  assert.equal(single.title, '测试视频'); assert.equal(single.duration, 10);
  assert.equal(single.sourcePath, meta().path); assert.equal(single.clips.length, 1);
  assert.match(single.createdAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const joined = createProject([meta('A', 4), meta('B', 6, 25)], { combined: true, title: '两个素材' });
  assert.equal(joined.duration, 10); assert.equal(joined.title, '两个素材'); assert.equal(joined.clips.length, 2);
  assert.notEqual(joined.clips[0].id, joined.clips[1].id);
  assert.throws(() => createProject([meta('A'), meta('B')]), /combined/);
  assert.throws(() => createProject([]), /至少/);
  assert.throws(() => createProject([meta('A', -3)]), /时长/);
  assert.throws(() => createProject([meta('A', 50000), meta('B', 50000)], { combined: true }), /时长/);
  const bad = clone(joined); bad.duration++;
  assert.throws(() => normalizeLibrary(bad), /不一致/);
  bad.duration--; bad.sourcePath = '/wrong/file.mp4';
  assert.throws(() => normalizeLibrary(bad), /不一致/);
  const duplicate = clone(joined); duplicate.clips[1].id = duplicate.clips[0].id;
  assert.throws(() => normalizeLibrary(duplicate), /重复/);
});

test('placements and seek conversion preserve trimmed source coordinates across seams', () => {
  const project = sequence(), placed = placements(project);
  near(placed[0].start, 0); near(placed[0].end, 3.16);
  near(placed[1].start, 3.16); near(placed[1].end, 7.16);
  near(placed[2].start, 7.16); near(placed[2].end, 9.16);
  for (const [index, item] of placed.entries()) {
    const first = locateTime(project, item.start);
    assert.equal(first.index, index); assert.equal(first.clip.id, item.clip.id); near(first.sourceTime, item.clip.sourceIn);
    for (let frame = 1; frame < Math.floor((item.end - item.start) * item.clip.frameRate); frame++) {
      const time = item.start + frame / item.clip.frameRate;
      const located = locateTime(project, time);
      assert.equal(located.index, index);
      near(located.sourceTime, item.clip.sourceIn + frame / item.clip.frameRate, 'Frame seeking uses clip placement, not shot start');
    }
  }
  const ending = locateTime(project, project.duration);
  assert.equal(ending.index, 2); near(ending.sourceTime, 8.5);
  near(locateTime(project, -10).sourceTime, 2.16);
  near(locateTime(project, 100).sourceTime, 8.5);
  assert.equal(locateTime({ duration: 0, clips: [] }, 0), null);
});

test('later shots seek inside their clip, and cuts use each source frame grid', () => {
  let project = sequence();
  project = addCut(project, 1.111);
  project = addCut(project, placements(project)[1].start + 1.111);
  project = addCut(project, placements(project)[2].start + 0.411);
  const placed = placements(project);
  near(project.cuts[0], Math.round((2.16 + 1.111) * 25) / 25 - 2.16);
  near(project.cuts[1], placed[1].start + Math.round((10.25 + 1.111) * 24) / 24 - 10.25);
  near(project.cuts[2], placed[2].start + Math.round((6.5 + 0.411) * 60) / 60 - 6.5);
  const all = shots(project);
  assert.equal(all.length, 6);
  for (const shot of all) {
    assert.equal(shotAt(project, shot.start).index, shot.index);
    const location = locateTime(project, shot.start);
    const next = locateTime(project, shot.start + 1 / location.clip.frameRate);
    if (next.index === location.index) near(next.sourceTime - location.sourceTime, 1 / location.clip.frameRate);
    near(location.sourceTime, location.clip.sourceIn + shot.start - location.start);
  }
  assert.equal(shotAt(project, project.duration).index, all.length - 1);
  assert.equal(shotAt(project, -1).index, 0);
  assert.equal(shotAt({ duration: 0, clips: [] }, 0), null);
  const atSecondShot = locateTime(project, all[3].start);
  assert.ok(atSecondShot.sourceTime > atSecondShot.clip.sourceIn + 1, 'A later shot must not restart the source clip');
});

test('mandatory seams cannot be removed; cuts ignore duplicate, edge and invalid edit requests', () => {
  const project = sequence();
  let changed = addCut(project, 1);
  const oldCuts = clone(changed.cuts);
  for (const time of [1, 1.0000000001, NaN, Infinity, -1, 0, project.duration, project.duration + 1, placements(project)[1].start]) {
    changed = addCut(changed, time);
  }
  assert.deepEqual(changed.cuts, oldCuts); assert.deepEqual(project.cuts, []);
  const count = shots(changed).length;
  changed = removeCut(changed, placements(project)[1].start);
  assert.equal(shots(changed).length, count);
  changed = removeCut(changed, 1.0000001);
  assert.equal(changed.cuts.length, 0); assert.equal(shots(changed).length, 3);
  const old = normalizeLibrary(legacy())[0];
  const duplicate = normalizeLibrary({ ...old, cuts: [0, 3, 3.00000001, 6, 10] })[0];
  assert.deepEqual(duplicate.cuts, [3, 6]);
});

test('valid tiny clips retain separate mandatory seam boundaries', () => {
  const project = createProject([meta('A', 1), meta('tiny', 0.00000005), meta('B', 1)], { combined: true });
  assert.equal(shots(project).length, 3);
  assert.equal(locateTime(project, 1.000000025).index, 1);
  assert.equal(shotAt(project, 1.000000025).index, 1);
});

test('note ranges support endpoint points, validate tracks and use useful summaries', () => {
  const project = normalizeLibrary(legacy())[0];
  const regular = createNote(project, { time: 4, track: 'story' });
  assert.equal(regular.start, 4); assert.equal(regular.end, 6); assert.equal(regular.track, 'story');
  const endpoint = createNote(project, { time: 10, track: 'learning' });
  assert.equal(endpoint.start, 10); assert.equal(endpoint.end, 10);
  assert.equal(createNote(project, { start: 2, end: 7 }).end, 7);
  assert.throws(() => createNote(project, { time: -1 }));
  assert.throws(() => createNote(project, { start: 3, end: 2 }));
  assert.throws(() => createNote(project, { start: 1, end: 11 }));
  assert.throws(() => createNote(project, { time: NaN }));
  assert.throws(() => createNote(project, { track: 'invalid' }));
  assert.equal(noteTitle({ ...regular, title: ' 明确标题 ', body: '正文' }), '明确标题');
  assert.equal(noteTitle({ ...regular, body: '\n  第一行  \n第二行' }), '第一行');
  assert.equal(noteTitle({ ...regular, takeaway: '心得首行\n更多' }), '心得首行');
  assert.match(noteTitle(regular), /^叙事逻辑 · /);
});

test('collecting across three clips maps source trims, cuts, notes and subtitle cues exactly', () => {
  let project = sequence();
  project = addCut(project, 2.4); project = addCut(project, 5.2); project = addCut(project, 7.8);
  project.notes = [
    { ...createNote(project, { start: 0, end: 1 }), title: '外部' },
    { ...createNote(project, { start: 1, end: 3 }), body: '左侧裁切' },
    { ...createNote(project, { start: 2.5, end: 7.5 }), body: '跨三个素材' },
    { ...createNote(project, { start: 7, end: 8.5 }), body: '右侧裁切' },
    { ...createNote(project, { start: 8, end: 8 }), body: '终点标记' },
    { ...createNote(project, { start: 8.1, end: 8.1 }), body: '选区外点' },
  ];
  project.subtitleTrack = subtitles(project, [
    { start: 1, end: 2.5, language: 'zh', text: '左侧字幕', chineseText: '' },
    { start: 3, end: 7.5, language: 'en', text: 'Across the sequence.', chineseText: '跨越素材。' },
    { start: 7.5, end: 9, language: 'zh', text: '右侧字幕', chineseText: '右侧字幕' },
  ]);
  project.scriptAnalyses = [script(project)];
  const before = clone(project), collected = collectRange(project, 2, 8, '选段练习');
  assert.deepEqual(project, before); assert.equal(collected.kind, 'remix'); assert.equal(collected.title, '选段练习');
  near(collected.duration, 6); assert.equal(collected.clips.length, 3);
  near(collected.clips[0].sourceIn, 4.16); near(collected.clips[0].sourceOut, 5.32);
  near(collected.clips[1].sourceIn, 10.25); near(collected.clips[1].sourceOut, 14.25);
  near(collected.clips[2].sourceIn, 6.5); near(collected.clips[2].sourceOut, 7.34);
  for (let index = 0; index < 3; index++) {
    assert.equal(collected.clips[index].sourceProjectID, project.id);
    assert.equal(collected.clips[index].sourceProjectTitle, project.title);
    assert.notEqual(collected.clips[index].id, project.clips[index].id);
  }
  assert.equal(collected.notes.length, 4);
  assert.deepEqual(collected.notes.map(x => [x.start, x.end]), [[0, 1], [0.5, 5.5], [5, 6], [6, 6]]);
  assert.equal(collected.notes[1].body, '跨三个素材');
  assert.ok(collected.notes.every(x => !project.notes.some(y => y.id === x.id)));
  assert.equal(subtitleCurrent(collected), true);
  assert.deepEqual(collected.subtitleTrack.cues.map(x => [x.start, x.end]), [[0, 0.5], [1, 5.5], [5.5, 6]]);
  assert.equal(collected.subtitleTrack.cues[1].chineseText, '跨越素材。');
  assert.ok(collected.subtitleTrack.cues.every(x => !project.subtitleTrack.cues.some(y => y.id === x.id)));
  for (let index = 0; index < project.cuts.length; index++) near(collected.cuts[index], project.cuts[index] - 2);
  assert.deepEqual(collected.scriptAnalyses, []);
  assert.equal(shots(collected).length, 6);
  const nested = collectRange(collected, 0.5, 4, '再次选段');
  assert.equal(nested.clips[0].sourceProjectID, project.id);
  assert.equal(nested.clips[0].sourceProjectTitle, project.title);
  assert.equal(subtitleCurrent(nested), true);
  assert.throws(() => collectRange(project, -1, 3));
  assert.throws(() => collectRange(project, 5, 5));
  assert.throws(() => collectRange(project, 2, 30));
});

test('collect at an exact seam starts the next clip and does not carry stale subtitles', () => {
  const project = sequence(), seam = placements(project)[1].start;
  project.subtitleTrack = subtitles(project);
  project.subtitleTrack.sourceClips[0].sourcePath = '/old/source.mp4';
  const collected = collectRange(project, seam, placements(project)[1].end);
  assert.equal(collected.clips.length, 1); assert.equal(collected.clips[0].sourcePath, project.clips[1].sourcePath);
  near(collected.clips[0].sourceIn, 10.25); near(collected.clips[0].sourceOut, 14.25);
  assert.equal(collected.subtitleTrack, null);
});

test('normalization retains known script, precise dialogue, subtitle and music fields', () => {
  const project = createProject([meta()]);
  project.scriptAnalyses = [script(project)]; project.subtitleTrack = subtitles(project);
  project.music = [{ id: id(), title: '配乐', sourcePath: 'D:/music/track.wav', sourceDuration: 20, sourceIn: 5, sourceOut: 10, timelineStart: 2, volume: 0.3 }];
  const normalized = normalizeLibrary(JSON.stringify(project))[0];
  assert.deepEqual(normalized.scriptAnalyses, project.scriptAnalyses);
  assert.deepEqual(normalized.subtitleTrack, project.subtitleTrack);
  assert.deepEqual(normalized.music, project.music);
  assert.deepEqual(normalizeLibrary(JSON.stringify(normalized))[0], normalized);
  const collected = collectRange(normalized, 4, 8);
  assert.equal(collected.music.length, 1);
  assert.equal(collected.music[0].sourceIn, 7); assert.equal(collected.music[0].sourceOut, 10);
  assert.equal(collected.music[0].timelineStart, 0); assert.equal(collected.music[0].volume, 0.3);
});

test('script validation rejects overlapping/out-of-range segments, cues and duplicate IDs', () => {
  const base = createProject([meta()]); base.scriptAnalyses = [script(base)];
  const mutations = [
    p => p.scriptAnalyses[0].rangeEnd = 11,
    p => p.scriptAnalyses[0].segments[0].start = -1,
    p => p.scriptAnalyses[0].segments[0].end = 11,
    p => p.scriptAnalyses[0].segments.push(clone(p.scriptAnalyses[0].segments[0])),
    p => p.scriptAnalyses[0].segments[0].visual = '字'.repeat(20001),
    p => p.scriptAnalyses[0].segments[0].dialogueCues[0].start = -1,
    p => p.scriptAnalyses[0].segments[0].dialogueCues[0].end = 11,
    p => p.scriptAnalyses[0].segments[0].dialogueCues[0].text = '',
    p => p.scriptAnalyses[0].segments[0].dialogueCues.push(clone(p.scriptAnalyses[0].segments[0].dialogueCues[0])),
    p => p.scriptAnalyses[0].sourceClips[0].sourceOut = 11,
    p => p.scriptAnalyses[0].timelineNoteIDs = [p.id, p.id.toUpperCase()],
    p => p.scriptAnalyses.push(clone(p.scriptAnalyses[0])),
    p => p.scriptAnalyses = Array.from({ length: 21 }, () => script(base)),
  ];
  for (const mutate of mutations) { const project = clone(base); mutate(project); assert.throws(() => normalizeLibrary(project)); }
  const oldSchema = clone(base); delete oldSchema.scriptAnalyses[0].segments[0].screenplay;
  delete oldSchema.scriptAnalyses[0].segments[0].dialogueCues;
  assert.equal(normalizeLibrary(oldSchema)[0].scriptAnalyses[0].segments[0].screenplay, '');
  assert.deepEqual(normalizeLibrary(oldSchema)[0].scriptAnalyses[0].segments[0].dialogueCues, []);
  // A stored old analysis is validated against its original snapshot, not the
  // current project's shortened duration, so later edits cannot erase history.
  const shortened = clone(base); shortened.duration = 5; shortened.clips[0].sourceOut = 5;
  assert.equal(normalizeLibrary(shortened)[0].scriptAnalyses[0].rangeEnd, 10);
});

test('subtitle validation requires ordered ranges, valid translations and unique IDs', () => {
  const base = createProject([meta()]); base.subtitleTrack = subtitles(base);
  const mutations = [
    p => p.subtitleTrack.cues[0].end = 0,
    p => p.subtitleTrack.cues[0].start = NaN,
    p => p.subtitleTrack.cues[1].start = 2,
    p => p.subtitleTrack.cues[2].end = 11,
    p => p.subtitleTrack.cues[1].chineseText = 'No Chinese here',
    p => p.subtitleTrack.cues[0].chineseText = '不同中文',
    p => p.subtitleTrack.cues[0].language = 'unknown',
    p => p.subtitleTrack.cues[0].text = '  ',
    p => p.subtitleTrack.cues[0].text = '字'.repeat(5001),
    p => p.subtitleTrack.cues[1].id = p.subtitleTrack.cues[0].id,
    p => p.subtitleTrack.sourceClips = [],
  ];
  for (const mutate of mutations) { const project = clone(base); mutate(project); assert.throws(() => normalizeLibrary(project)); }
  const shortened = clone(base); shortened.duration = 5; shortened.clips[0].sourceOut = 5;
  assert.equal(normalizeLibrary(shortened)[0].subtitleTrack.cues[2].end, 8);
});

test('subtitle validity ignores names/IDs/background music but detects video order and trims', () => {
  const project = sequence(); project.subtitleTrack = subtitles(project);
  assert.equal(subtitleCurrent(project), true);
  const renamed = clone(project); renamed.title = '更名'; renamed.clips[0].title = '改名'; renamed.clips[0].id = id(); renamed.originalVolume = 0;
  renamed.music = [{ id: id() }];
  assert.equal(subtitleCurrent(renamed), true);
  for (const key of ['sourcePath', 'sourceDuration', 'sourceIn', 'sourceOut', 'frameRate', 'width', 'height']) {
    const changed = clone(project); changed.clips[0][key] = typeof changed.clips[0][key] === 'string' ? '/new.mov' : changed.clips[0][key] + 0.1;
    assert.equal(subtitleCurrent(changed), false, key);
  }
  const reordered = clone(project); reordered.clips.reverse(); assert.equal(subtitleCurrent(reordered), false);
  assert.equal(subtitleCurrent(createProject([meta()])), false);
});

test('local foreign speech remains usable before translation; incomplete translated SRT is rejected', () => {
  const project = createProject([meta()]);
  project.subtitleTrack = subtitles(project);
  project.subtitleTrack.cues[1].chineseText = '';
  project.subtitleTrack.cues[2].chineseText = '  ';
  const normalized = normalizeLibrary(project)[0];
  assert.equal(subtitleCurrent(normalized), true);
  assert.equal(sharedDialogues(normalized)[1].text, 'Hello there.');
  assert.ok(toSRT(normalized.subtitleTrack.cues, 'original').includes('Hello there.'));
  assert.throws(() => toSRT(normalized.subtitleTrack.cues, 'chinese'), /尚未完成中文翻译/);
  assert.throws(() => toSRT(normalized.subtitleTrack.cues, 'bilingual'), /尚未完成中文翻译/);
  assert.throws(() => toSRT(normalized.subtitleTrack.cues), /只导出原文/);
  const wrongTranslation = clone(project);
  wrongTranslation.subtitleTrack.cues[1].chineseText = 'still English';
  assert.throws(() => normalizeLibrary(wrongTranslation), /译文必须包含中文/);
  normalized.subtitleTrack.cues[1].chineseText = '你好。';
  normalized.subtitleTrack.cues[2].chineseText = '你好。';
  assert.ok(toSRT(normalized.subtitleTrack.cues).includes('Hello there.\n你好。'));
});

test('appendCollection retains history and correctly offsets video, notes, music and subtitles', () => {
  const destination = createProject([meta('灵感空间', 10)]), fragment = collectRange(sequence(), 1, 5, '收集片段');
  destination.kind = 'remix'; destination.cuts = [4];
  destination.notes = [createNote(destination, { start: 2, end: 3 })];
  destination.scriptAnalyses = [script(destination)];
  destination.subtitleTrack = subtitles(destination);
  fragment.cuts = [0.5]; fragment.notes = [createNote(fragment, { start: 1, end: 2 })];
  fragment.subtitleTrack = subtitles(fragment, [{ start: 0.5, end: 2, language: 'en', text: 'A fragment.', chineseText: '一个片段。' }]);
  fragment.music = [{ id: id(), title: '配乐', sourcePath: 'D:/music/track.wav', sourceDuration: 10,
    sourceIn: 1, sourceOut: 3, timelineStart: 1, volume: 0.4 }];
  const leftBefore = clone(destination), rightBefore = clone(fragment);
  const appended = appendCollection(destination, fragment);
  assert.deepEqual(destination, leftBefore); assert.deepEqual(fragment, rightBefore);
  assert.equal(appended.id, destination.id); assert.equal(appended.kind, 'remix'); near(appended.duration, 14);
  assert.equal(appended.clips.length, 3); assert.equal(appended.clips[0].id, destination.clips[0].id);
  assert.equal(appended.clips[1].sourceProjectID, fragment.clips[0].sourceProjectID);
  assert.notEqual(appended.clips[1].id, fragment.clips[0].id);
  assert.equal(appended.notes[0].id, destination.notes[0].id);
  assert.deepEqual(appended.notes.map(x => [x.start, x.end]), [[2, 3], [11, 12]]);
  assert.notEqual(appended.notes[1].id, fragment.notes[0].id);
  const expectedCut = normalizeLibrary(fragment)[0].cuts[0] + destination.duration;
  assert.ok(appended.cuts.some(value => Math.abs(value - expectedCut) < 1e-9));
  assert.ok(shots(appended).some(value => value.start === 10));
  assert.equal(appended.music[0].timelineStart, 11);
  assert.deepEqual(appended.scriptAnalyses, destination.scriptAnalyses);
  assert.equal(scriptCurrent(appended, appended.scriptAnalyses[0]), false);
  assert.equal(subtitleCurrent(appended), true);
  assert.equal(appended.subtitleTrack.cues.length, 4);
  assert.deepEqual(appended.subtitleTrack.cues.slice(0, 3), destination.subtitleTrack.cues);
  assert.equal(appended.subtitleTrack.cues[3].start, 10.5); assert.equal(appended.subtitleTrack.cues[3].end, 12);
  assert.equal(activeCue(appended.subtitleTrack.cues, 9), null);
  assert.equal(activeCue(appended.subtitleTrack.cues, 10.5).text, 'A fragment.');
  const twice = appendCollection(appended, fragment);
  assert.equal(twice.clips.length, 5); assert.equal(twice.notes.length, 3);
  assert.equal(twice.subtitleTrack.cues.length, 5);
  assert.equal(new Set(twice.clips.map(x => x.id)).size, 5);
  assert.equal(new Set(twice.notes.map(x => x.id)).size, 3);
  assert.equal(new Set(twice.subtitleTrack.cues.map(x => x.id)).size, 5);
  assert.equal(subtitleCurrent(twice), true);
});

test('appendCollection preserves accurate partial subtitle intervals without fabricated gap filling', () => {
  const destination = createProject([meta('左侧', 10)]), fragment = createProject([meta('右侧', 5)]);
  destination.subtitleTrack = subtitles(destination);
  const leftOnly = appendCollection(destination, fragment);
  assert.equal(subtitleCurrent(leftOnly), true);
  assert.deepEqual(leftOnly.subtitleTrack.cues, destination.subtitleTrack.cues);
  assert.match(leftOnly.subtitleTrack.sourceDescription, /部分区间/);
  assert.match(leftOnly.subtitleTrack.sourceDescription, /10–15 秒.*没有与当前素材一致的字幕/);
  assert.equal(activeCue(leftOnly.subtitleTrack.cues, 12), null);
  const subtitlesRight = subtitles(fragment, [{ start: 1, end: 3, language: 'zh', text: '右侧字幕', chineseText: '' }]);
  fragment.subtitleTrack = subtitlesRight; destination.subtitleTrack = null;
  const rightOnly = appendCollection(destination, fragment);
  assert.equal(subtitleCurrent(rightOnly), true);
  assert.equal(rightOnly.subtitleTrack.cues.length, 1);
  assert.deepEqual(rightOnly.subtitleTrack.cues.map(x => [x.start, x.end]), [[11, 13]]);
  assert.equal(activeCue(rightOnly.subtitleTrack.cues, 2), null);
  assert.match(rightOnly.subtitleTrack.sourceDescription, /0–10 秒.*没有与当前素材一致的字幕/);
  const none = clone(fragment); none.subtitleTrack = null;
  const stale = subtitles(destination); stale.sourceClips[0].sourcePath = '/old/video.mp4'; destination.subtitleTrack = stale;
  const oldTrack = appendCollection(destination, none);
  assert.deepEqual(oldTrack.subtitleTrack, stale);
  assert.equal(subtitleCurrent(oldTrack), false);
  const stalePlusCurrent = appendCollection(destination, fragment);
  assert.equal(subtitleCurrent(stalePlusCurrent), true);
  assert.equal(stalePlusCurrent.subtitleTrack.cues.length, 1);
  assert.equal(stalePlusCurrent.subtitleTrack.cues[0].text, '右侧字幕');
});

test('active captions use exclusive ends and gaps remain silent', () => {
  const project = createProject([meta()]); const cues = subtitles(project).cues;
  assert.equal(activeCue(cues, 0), null); assert.equal(activeCue(cues, 1).id, cues[0].id);
  assert.equal(activeCue(cues, 2.5), null); assert.equal(activeCue(cues, 3).id, cues[1].id);
  assert.equal(activeCue(cues, 8), null); assert.equal(activeCue(cues, NaN), null);
  const touching = [{ ...cues[0], end: 3 }, cues[1]];
  assert.equal(activeCue(touching, 3).id, cues[1].id);
});

test('SRT keeps Chinese once, bilingual text on separate lines and millisecond carry exact', () => {
  const cues = [
    { id: id(), start: 0.0014, end: 1.9996, language: 'zh', text: '  只有中文  ', chineseText: '只有中文' },
    { id: id(), start: 59.9996, end: 60.9996, language: 'en', text: 'Hello\r\nworld.', chineseText: '你好世界。' },
    { id: id(), start: 3599.9996, end: 3601.0004, language: 'ja', text: 'はい。', chineseText: '是的。' },
  ];
  const output = toSRT(cues);
  assert.equal(output, '1\n00:00:00,001 --> 00:00:02,000\n只有中文\n\n2\n00:01:00,000 --> 00:01:01,000\nHello\nworld.\n你好世界。\n\n3\n01:00:00,000 --> 01:00:01,000\nはい。\n是的。\n');
  assert.equal((output.match(/只有中文/g) ?? []).length, 1);
  assert.ok(!toSRT(cues, 'original').includes('你好世界'));
  assert.ok(!toSRT(cues, 'chinese').includes('Hello'));
  assert.ok(toSRT(cues, 'chinese').includes('只有中文'));
  assert.deepEqual(cueLines({ language: 'zh', text: '中文', chineseText: '中文' }), ['中文']);
  assert.deepEqual(cueLines({ language: 'en', text: '中文', chineseText: '中文' }), ['中文']);
  assert.throws(() => toSRT([{ ...cues[0], start: 1.0001, end: 1.0002 }]), /毫秒/);
  assert.throws(() => toSRT(cues, 'invalid'), /模式/);
  assert.equal(toSRT([]), '');
});

test('unified dialogue cues prioritize valid subtitles, fall back to timed current script only', () => {
  const project = createProject([meta()]); const analysis = script(project); project.scriptAnalyses = [analysis];
  assert.equal(scriptCurrent(project, analysis), true);
  const modelCues = sharedDialogues(project);
  assert.equal(modelCues.length, 1); assert.equal(modelCues[0].text, 'Hello.');
  assert.equal(modelCues[0].speaker, '人物'); assert.equal(modelCues[0].source, 'script'); assert.equal(modelCues[0].language, null);
  project.subtitleTrack = subtitles(project);
  const authoritative = sharedDialogues(project, analysis);
  assert.equal(authoritative.length, 3); assert.equal(authoritative[0].source, 'subtitle');
  assert.equal(authoritative[1].chineseText, '你好。');
  project.subtitleTrack.sourceClips[0].sourceIn = 1;
  assert.equal(sharedDialogues(project)[0].source, 'script');
  const stale = clone(analysis); stale.sourceClips[0].sourcePath = '/old.mov';
  assert.deepEqual(sharedDialogues(project, stale), []);
  project.scriptAnalyses[0].segments[0].dialogueCues = [];
  assert.deepEqual(sharedDialogues(project), [], 'Do not invent timing for free-form dialogue text');
  project.scriptAnalyses[0].originalVolume = 0.5;
  assert.equal(scriptCurrent(project, project.scriptAnalyses[0]), false);
});

test('timecode uses non-drop frame rounding and handles invalid input defensively', () => {
  assert.equal(formatTime(0), '00:00:00:00');
  assert.equal(formatTime(1 + 12 / 25, 25), '00:00:01:12');
  assert.equal(formatTime(59 + 29.6 / 30, 30), '00:01:00:00');
  assert.equal(formatTime(3600), '01:00:00:00');
  assert.equal(formatTime(NaN), '00:00:00:00');
  assert.equal(formatTime(-10), '00:00:00:00');
  assert.equal(formatTime(1, 0), '00:00:01:00');
  assert.equal(formatTime(1001, 30000 / 1001), '00:16:40:00');
});
