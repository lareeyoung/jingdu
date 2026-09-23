const { app, BrowserWindow, ipcMain, dialog, protocol, net, session, safeStorage, shell, Menu } = require('electron');
const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { pathToFileURL } = require('node:url');
const { createStorage, atomicJSON } = require('./storage.cjs');
const { createMediaService } = require('./media.cjs');
const { serveMediaFile } = require('./media-protocol.cjs');
const { createAnalysisService, expectedModelHash, expectedModelSize } = require('./analysis.cjs');

protocol.registerSchemesAsPrivileged([{ scheme: 'jingdu', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);
app.setName('镜读 Windows');
const smoke = process.argv.includes('--smoke-test');
if (smoke) app.setPath('userData', path.join(os.tmpdir(), 'jingdu-smoke-' + process.pid));
else app.setPath('userData', path.join(app.getPath('appData'), 'Jingdu-Windows'));
let win, store, media, model, library = [], job = null, loadError = null;
let closing = false;
const fileTokens = new Map();
const root = path.resolve(__dirname, '..');
const videoExtensions = ['mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi'];
const toolRoot = app.isPackaged ? path.join(process.resourcesPath, 'tools') : path.join(root, 'resources');
function tool(name) {
  const exe = process.platform === 'win32' ? '.exe' : '';
  const bundled = path.join(toolRoot, name + exe);
  if (fsSync.existsSync(bundled)) return bundled;
  if (!app.isPackaged && process.platform === 'darwin') {
    const local = name === 'whisper-cli' ? path.join(root, '..', 'Resources', 'SubtitleEngine', name) : '/opt/homebrew/bin/' + name;
    if (fsSync.existsSync(local)) return local;
  }
  return bundled;
}
function fileURL(file) {
  const existing = [...fileTokens].find(([, value]) => value === file);
  if (existing) return 'jingdu://media/' + existing[0];
  const token = crypto.randomUUID(); fileTokens.set(token, file); return 'jingdu://media/' + token;
}
function project(id) { const p = library.find(p => p.id === id); if (!p) throw new Error('项目不存在，请重新选择。'); return p; }
function progress(data) { if (win && !win.isDestroyed()) win.webContents.send('jingdu:progress', { ...data, projectId: job?.projectId }); }
async function runJob(projectId, operation, fn) {
  if (job) throw new Error('请等待当前任务完成，或先取消。');
  job = { projectId, operation, controller: new AbortController() };
  progress({ operation, progress: 0, message: '正在准备…', busy: true });
  try { return await fn(job.controller.signal); }
  catch (e) { if (job?.controller.signal.aborted || e.name === 'AbortError') throw new Error('已取消，原有内容已保留。'); throw e; }
  finally { progress({ operation, busy: false, progress: 1 }); job = null; }
}
async function saveLibrary(next) {
  if (loadError) throw new Error(loadError);
  const validated = model.normalizeLibrary(next);
  await store.save(validated); library = validated; return library;
}
function sameSequence(a, b) {
  return JSON.stringify(model.clipsOf(a).map(c => [c.sourcePath,c.sourceIn,c.sourceOut])) === JSON.stringify(model.clipsOf(b).map(c => [c.sourcePath,c.sourceIn,c.sourceOut]));
}
async function applyGenerated(snapshot, changes) {
  job?.controller.signal.throwIfAborted();
  const current = project(snapshot.id);
  if (!sameSequence(snapshot, current)) throw new Error('任务期间素材顺序发生变化，请重新生成。');
  const next = { ...current, ...changes, updatedAt: new Date().toISOString() };
  await saveLibrary(library.map(p => p.id === next.id ? next : p)); return next;
}
function analysisService(config) {
  return createAnalysisService({ media, whisperPath: tool('whisper-cli'), modelPath: config.modelPath, onProgress: progress });
}
function register(channel, fn) {
  ipcMain.handle('jingdu:' + channel, async (event, payload) => {
    if (!win || event.sender !== win.webContents || event.senderFrame !== win.webContents.mainFrame || !event.senderFrame.url.startsWith('jingdu://app/')) throw new Error('无效的应用请求。');
    return fn(payload || {});
  });
}
async function boot() {
  model = await import(pathToFileURL(path.join(root, 'shared/model.mjs')).href);
  store = createStorage(app.getPath('userData'), safeStorage);
  try { library = model.normalizeLibrary(await store.load()); }
  catch (e) { loadError = e.message; library = []; }
  media = createMediaService({ ffmpeg: tool('ffmpeg'), ffprobe: tool('ffprobe'), cacheDir: path.join(app.getPath('userData'), 'Cache'), onProgress: progress });
  protocol.handle('jingdu', async request => {
    const url = new URL(request.url);
    if (url.hostname === 'media') {
      const file = fileTokens.get(url.pathname.slice(1));
      if (!file) return new Response('Not found', { status: 404 });
      return serveMediaFile(request, file);
    }
    if (url.hostname !== 'app') return new Response('Not found', { status: 404 });
    const relative = decodeURIComponent(url.pathname === '/' ? '/renderer/index.html' : url.pathname).slice(1);
    const file = path.resolve(root, relative);
    if (!file.startsWith(root + path.sep) || !/^(renderer|shared)[/\\]/.test(relative)) return new Response('Forbidden', { status: 403 });
    return net.fetch(pathToFileURL(file).href);
  });
  session.defaultSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  Menu.setApplicationMenu(null);
  win = new BrowserWindow({ width: 1480, height: 940, minWidth: 1024, minHeight: 720, title: '镜读 · Frame Study', icon: path.join(root, 'assets/icon.ico'), backgroundColor: '#101214', show: !smoke,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), sandbox: true, nodeIntegration: false, contextIsolation: true, webSecurity: true, spellcheck: false } });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (event, url) => { if (!url.startsWith('jingdu://app/')) event.preventDefault(); });
  win.on('close', event => {
    if (closing || smoke) return;
    event.preventDefault();
    if (job) { progress({ message: '请先完成或取消当前任务，再关闭窗口。' }); return; }
    win.webContents.send('jingdu:before-close');
  });
  ipcMain.on('jingdu:close-ready', async event => {
    if (event.sender !== win.webContents) return;
    try { await store.flush(); closing = true; win.close(); }
    catch { dialog.showErrorBox('内容尚未保存', '未关闭窗口。请导出项目备份或检查磁盘空间后重试。'); }
  });
  ipcMain.on('jingdu:close-failed', event => { if (event.sender === win.webContents) dialog.showErrorBox('内容尚未保存', '未关闭窗口。请导出项目备份或检查磁盘空间后重试。'); });
  register('load', async () => ({ projects: library, settings: await store.settings(), version: app.getVersion(), platform: process.platform, loadError }));
  register('save', async payload => { await saveLibrary(payload.projects); return { saved: true }; });
  register('importVideos', async () => {
    const selection = await dialog.showOpenDialog(win, { title: '导入视频', properties: ['openFile','multiSelections'], filters: [{ name: '视频', extensions: videoExtensions }] });
    if (selection.canceled) return [];
    if (selection.filePaths.length > 30) throw new Error('每次最多导入 30 段素材。');
    return runJob(null, 'import', async signal => {
      const result = [];
      for (const file of selection.filePaths) { const metadata = await media.probe(file, { signal }); result.push({ ...metadata, path: file, title: path.parse(file).name }); }
      return result;
    });
  });
  register('importBackup', async () => {
    const selection = await dialog.showOpenDialog(win, { title: '导入镜读项目备份', properties: ['openFile'], filters: [{ name: '镜读项目', extensions: ['json'] }] });
    if (selection.canceled) return null;
    const file = selection.filePaths[0];
    if ((await fs.stat(file)).size > 20 * 1024 * 1024) throw new Error('项目备份过大。');
    const imported = model.normalizeLibrary(JSON.parse(await fs.readFile(file, 'utf8')));
    for (const p of imported) if (library.some(x => x.id === p.id)) throw new Error('此项目已经在作品库中，请勿重复导入。');
    await saveLibrary([...imported, ...library]); return library;
  });
  register('exportBackup', async ({ projectId }) => {
    const p = project(projectId);
    if (p.subtitleTrack?.cues.some(c => c.language !== 'zh' && !c.chineseText?.trim())) throw new Error('此项目含尚未翻译的外语字幕。请先补全中文翻译再导出 Mac 兼容备份；原文可单独导出 SRT。');
    const dest = await dialog.showSaveDialog(win, { defaultPath: p.title.replace(/[<>:"/\\|?*]/g,'_') + '.jingdu.json', filters: [{ name: '镜读项目备份', extensions: ['json'] }] });
    if (!dest.canceled) await atomicJSON(dest.filePath, p); return !dest.canceled;
  });
  register('playback', async ({ projectId, clipId }) => {
    const p = project(projectId), clip = model.clipsOf(p).find(c => c.id === clipId);
    if (!clip) throw new Error('素材不存在。');
    try { await fs.access(clip.sourcePath); } catch { throw new Error('找不到原视频，请点击“重新关联素材”。'); }
    return fileURL(await media.playback(clip.sourcePath));
  });
  register('thumbnails', async ({ projectId }) => {
    const p = project(projectId), result = [];
    for (const shot of model.shots(p).slice(0,160)) {
      const loc = model.locateTime(p, (shot.start + shot.end) / 2);
      try { result.push({ index: shot.index, url: fileURL(await media.thumbnail(loc.clip.sourcePath, loc.sourceTime)) }); }
      catch { result.push({ index: shot.index, url: null }); }
    }
    return result;
  });
  register('waveform', async ({ projectId }) => {
    const p = project(projectId), result = [];
    for (const place of model.placements(p)) {
      try { result.push({ clipId: place.clip.id, samples: await media.waveform(place.clip.sourcePath, 2400), sourceDuration: place.clip.sourceDuration }); }
      catch { result.push({ clipId: place.clip.id, samples: [] }); }
    }
    return result;
  });
  register('detectCuts', ({ projectId, threshold }) => runJob(projectId, 'detectCuts', async signal => {
    const p = project(projectId), cuts = [];
    for (const place of model.placements(p)) {
      const values = await media.detectCuts(place.clip.sourcePath, { threshold: Number(threshold) || 0.32, signal });
      cuts.push(...values.filter(t => t > place.clip.sourceIn && t < place.clip.sourceOut).map(t => t - place.clip.sourceIn + place.start));
    }
    return cuts;
  }));
  register('relink', async ({ projectId, clipId }) => {
    const p = project(projectId), c = model.clipsOf(p).find(c => c.id === clipId); if (!c) throw new Error('素材不存在。');
    const selection = await dialog.showOpenDialog(win, { title: '重新关联：' + c.title, properties: ['openFile'], filters: [{ name: '视频', extensions: videoExtensions }] });
    if (selection.canceled) return null;
    const file = selection.filePaths[0], info = await media.probe(file);
    if (info.duration + 0.1 < c.sourceOut) throw new Error('所选素材短于项目片段，请选择原视频。');
    const copy = JSON.parse(JSON.stringify(p));
    const old = c.sourcePath;
    copy.clips = model.clipsOf(copy);
    const patch = clips => clips?.forEach(clip => { if (clip.sourcePath === old) clip.sourcePath = file; });
    patch(copy.clips); patch(copy.subtitleTrack?.sourceClips); copy.scriptAnalyses.forEach(a => patch(a.sourceClips));
    if (copy.sourcePath === old) copy.sourcePath = file;
    await saveLibrary(library.map(x => x.id === copy.id ? copy : x)); return copy;
  });
  register('settings', () => store.settings());
  register('saveSettings', async config => { await store.saveSettings(config); return store.settings(); });
  register('chooseModel', async () => {
    const selection = await dialog.showOpenDialog(win, { title: '选择 Whisper small 多语言模型', properties: ['openFile'], filters: [{ name: 'Whisper 模型', extensions: ['bin'] }] });
    if (selection.canceled) return null;
    const file = selection.filePaths[0];
    if ((await fs.stat(file)).size !== expectedModelSize) throw new Error('请选择完整的 ggml-small.bin 多语言模型（约 466 MiB）。');
    const hash = crypto.createHash('sha1');
    for await (const chunk of fsSync.createReadStream(file)) hash.update(chunk);
    if (hash.digest('hex') !== expectedModelHash) throw new Error('模型校验失败，请从官方来源重新下载。');
    return file;
  });
  register('models', () => runJob(null, 'models', async signal => { const config = await store.settings(); return analysisService(config).models(config, await store.key(config), { signal }); }));
  register('subtitles', ({ projectId, reuse }) => runJob(projectId, 'transcribe', async signal => {
    const snapshot = structuredClone(project(projectId)), config = await store.settings();
    if (!(reuse && model.subtitleCurrent(snapshot)) && !config.modelPath) throw new Error('请先在模型设置中选择本地 Whisper 模型。');
    const service = analysisService(config);
    let track = reuse && model.subtitleCurrent(snapshot) ? structuredClone(snapshot.subtitleTrack) : await service.transcribe(snapshot, { signal });
    const nonChinese = track.cues.some(c => c.language !== 'zh');
    if (nonChinese) {
      // Keep useful local recognition if the optional network translation fails.
      await applyGenerated(snapshot, { subtitleTrack: track });
      try { track = await service.translate(track, config, await store.key(config), { signal }); }
      catch (error) {
        if (signal.aborted || error.name === 'AbortError') throw error;
        return { project: project(projectId), warning: '原文字幕已保存；中文翻译未完成：' + error.message };
      }
    }
    return { project: await applyGenerated(snapshot, { subtitleTrack: track }) };
  }));
  register('script', ({ projectId, start, end, focus, mode }) => runJob(projectId, 'script', async signal => {
    const snapshot = structuredClone(project(projectId)), config = await store.settings();
    const result = await analysisService(config).generateScript(snapshot, config, await store.key(config), { start, end, focus, mode, signal });
    return applyGenerated(snapshot, { scriptAnalyses: [...project(projectId).scriptAnalyses, result].slice(-20) });
  }));
  register('exportSRT', async ({ projectId, mode }) => {
    const p = project(projectId); if (!p.subtitleTrack?.cues.length) throw new Error('还没有可导出的字幕。');
    const dest = await dialog.showSaveDialog(win, { defaultPath: p.title.replace(/[<>:"/\\|?*]/g,'_') + '.srt', filters: [{ name: 'SRT 字幕', extensions: ['srt'] }] });
    if (!dest.canceled) await fs.writeFile(dest.filePath, '\ufeff' + model.toSRT(p.subtitleTrack.cues, mode), 'utf8'); return !dest.canceled;
  });
  register('cancel', () => { job?.controller.abort(); return true; });
  register('openGuide', async ({ target }) => {
    const urls = { guide: 'https://github.com/lareeyoung/jingdu/tree/main/Windows', model: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin?download=true' };
    if (urls[target]) await shell.openExternal(urls[target]);
  });
  await win.loadURL('jingdu://app/renderer/index.html');
  if (smoke) {
    try {
      const state = await require('./smoke.cjs').runSmoke({ win, media, model, saveLibrary, probeFile: process.env.JINGDU_SMOKE_VIDEO });
      console.log('JINGDU_SMOKE_OK ' + JSON.stringify(state)); app.exit(0);
    } catch (error) { console.error('JINGDU_SMOKE_FAILED', error.message); app.exit(1); }
  }
}
app.whenReady().then(boot).catch(error => { console.error(error.message); if (!smoke) dialog.showErrorBox('镜读未能启动', error.message); app.exit(1); });
app.on('window-all-closed', () => { job?.controller.abort(); app.quit(); });
