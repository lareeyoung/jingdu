// Hidden integration tests of Jingdu itself, using an isolated temporary library.
// No account, model service, user library or user credentials are read here.
const fs = require('node:fs/promises');
const crypto = require('node:crypto');
async function runSmoke({ win, media, model, saveLibrary, probeFile }) {
  const js = code => win.webContents.executeJavaScript(code, true);
  async function until(expression, label, timeout = 20000) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
      if (await js(expression)) return;
      await new Promise(resolve => setTimeout(resolve, 80));
    }
    throw new Error('Timed out: ' + label + '; media=' + JSON.stringify(await js('({time:document.querySelector("#video")?.currentTime,ready:document.querySelector("#video")?.readyState,duration:document.querySelector("#video")?.duration,active:Array.from(document.querySelectorAll("#reader .current")).map(x=>x.dataset.cueId)})')) + '; ' + await js('document.querySelector("#toast")?.textContent || document.body.innerText.slice(-500)'));
  }
  const click = selector => js(`document.querySelector(${JSON.stringify(selector)}).click()`);
  await until('document.documentElement.dataset.ready === "true"', 'initial application');
  const state = await js('({app:!!document.querySelector("#app .workspace"),api:!!window.jingdu,node:typeof window.require})');
  if (!state.app || !state.api || state.node !== 'undefined') throw new Error('Renderer isolation failed');
  if (!probeFile) return state;
  const metadata = await media.probe(probeFile);
  if (metadata.duration < 3) throw new Error('Smoke fixture must last at least 3 seconds');
  const proxy = await media.playback(probeFile);
  if (!(await fs.stat(proxy)).size) throw new Error('Empty playback proxy');
  const project = model.createProject([{ ...metadata, path: probeFile, title: '离线验证素材' }, { ...metadata, path: probeFile, title: '第二段素材' }], { combined: true, title: 'Windows 离线验证 · 非模型生成' });
  project.clips[0].sourceOut = 2;
  const secondSourceStart = metadata.duration - 2;
  project.clips[1].sourceIn = secondSourceStart;
  project.clips[1].sourceOut = metadata.duration;
  project.duration = 4;
  project.cuts = [1, 3];
  const cues = [
    { id: crypto.randomUUID(), start: 0.2, end: 0.9, language: 'en', text: 'First test caption.', chineseText: '第一句测试字幕。' },
    { id: crypto.randomUUID(), start: 2.2, end: 2.9, language: 'ja', text: 'テストです。', chineseText: '这是测试。' },
  ];
  project.subtitleTrack = { id: crypto.randomUUID(), createdAt: new Date().toISOString(), sourceClips: structuredClone(project.clips), sourceDescription: '离线验证样例，非模型识别', cues };
  await saveLibrary([project]);
  await win.loadURL('jingdu://app/renderer/index.html');
  await until('document.documentElement.dataset.ready === "true" && document.querySelector("#video")?.readyState >= 2', 'fixture playback');
  await click('[data-action="play"]');
  await until('document.querySelector("#video").currentTime > 0.15 && !document.querySelector("#video").paused', 'actual renderer decoding');
  await click('[data-action="play"]');
  await click('[data-action="next-shot"]');
  await until('document.querySelector("#shot-number").textContent === "SHOT 02" && Math.abs(document.querySelector("#video").currentTime-1)<0.03', 'second shot navigation');
  await click('[data-action="next-frame"]');
  await until(`Math.abs(document.querySelector('#video').currentTime-${1 + 1 / metadata.frameRate})<0.012`, 'frame step beyond first shot');
  await click('[data-action="reader-subtitles"]');
  await click(`#reader [data-cue-id="${cues[1].id}"]`);
  await until(`document.querySelector('#reader [data-cue-id="${cues[1].id}"]').classList.contains('current') && Math.abs(document.querySelector('#video').currentTime-${secondSourceStart + 0.2})<0.03 && document.querySelector('#video').readyState>=2`, 'subtitle seek across trimmed media');
  await click('#follow');
  await click(`#reader [data-cue-id="${cues[0].id}"]`);
  if (!(await js(`Math.abs(document.querySelector('#video').currentTime-${secondSourceStart + 0.2})<0.03`))) throw new Error('Disabled follow still seeks');
  await click('#follow');
  await click('[data-action="play"]');
  await until(`document.querySelector('#video').currentTime>${secondSourceStart + 1.1} && !document.querySelector('#video').paused`, 'play after second media seek');
  await click('[data-action="play"]');
  if (!(await js('document.querySelector(".context-shot.is-current")?.dataset.seek === "3"'))) throw new Error('Adjacent shot previews did not follow playback');
  // Subsequent playback and seeks must preserve both language rows.
  if (!(await js(`document.querySelector('#reader [data-cue-id="${cues[1].id}"] .translation').textContent === '这是测试。'`))) throw new Error('Translation row missing');
  state.media = { probe: true, transcode: true, rendererPlayback: true, seek: true, frameStep: true, bilingualFollow: true };
  return state;
}
module.exports = { runSmoke };
