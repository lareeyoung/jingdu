const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');

async function atomicJSON(filename, data) {
  await fs.mkdir(path.dirname(filename), { recursive: true });
  const temp = filename + '.' + crypto.randomUUID() + '.tmp';
  try {
    await fs.writeFile(temp, JSON.stringify(data, null, 2), { mode: 0o600 });
    // Windows readers and virus scanners can briefly hold a rename lock.
    // A short, bounded retry cadence can catch the gaps between readers;
    // ten increasingly sparse attempts can miss every gap under load.
    // Never unlink the last good file to work around a locked destination.
    const retryUntil = performance.now() + 5000;
    for (let attempt = 0; ; attempt++) {
      try { await fs.rename(temp, filename); break; }
      catch (error) {
        const remaining = retryUntil - performance.now();
        if (!['EPERM', 'EACCES', 'EBUSY'].includes(error.code) || remaining <= 0) throw error;
        if (attempt === 0 && (await fs.lstat(filename).catch(() => null))?.isDirectory()) throw error;
        const delay = Math.min(remaining, Math.min(50, 10 * (attempt + 1)) * (0.75 + Math.random() * 0.5));
        await new Promise(resolve => setTimeout(resolve, delay));
      }
    }
  } finally { await fs.rm(temp, { force: true }).catch(() => {}); }
}
async function readJSON(filename, fallback) {
  try { return JSON.parse(await fs.readFile(filename, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw new Error('本地数据无法读取，已保留原文件。请先备份后再检查。'); }
}
function createStorage(directory, safeStorage) {
  let queue = Promise.resolve();
  let loadFailure = null;
  const libraryPath = path.join(directory, 'library.json');
  return {
    directory,
    flush: () => queue,
    async load() {
      try { return await readJSON(libraryPath, []); }
      catch (error) { loadFailure = error; throw error; }
    },
    save(projects) {
      const copy = JSON.parse(JSON.stringify(projects));
      const work = queue.catch(() => {}).then(async () => {
        if (loadFailure) throw loadFailure;
        // Preserve a corrupt file even if it was changed after startup.
        await readJSON(libraryPath, []);
        await fs.copyFile(libraryPath, libraryPath + '.backup').catch(e => { if (e.code !== 'ENOENT') throw e; });
        await atomicJSON(libraryPath, copy);
      });
      queue = work;
      return work;
    },
    async settings() {
      const config = await readJSON(path.join(directory, 'settings.json'), {});
      return { baseURL: '', appID: '', modelID: 'doubao-seed-2-1-pro-260628', providerModel: '', route: 'passthrough', timeout: 300, thinkingMode: 'standard', autoScript: false, ...config,
        hasKey: !!(await readJSON(path.join(directory, 'credential.json'), null)), key: undefined };
    },
    async saveSettings(input) {
      const { key, hasKey, clearKey, ...config } = input;
      if (key) {
        if (!safeStorage.isEncryptionAvailable()) throw new Error('系统安全存储不可用，未保存 Key。');
        const encrypted = safeStorage.encryptString(key).toString('base64');
        await atomicJSON(path.join(directory, 'credential.json'), { account: config.baseURL + '|' + config.appID, encrypted });
      } else if (clearKey) await fs.rm(path.join(directory, 'credential.json'), { force: true });
      await atomicJSON(path.join(directory, 'settings.json'), config);
    },
    async key(config) {
      const saved = await readJSON(path.join(directory, 'credential.json'), null);
      if (!saved || saved.account !== config.baseURL + '|' + config.appID) throw new Error('请先在模型设置中保存此服务的 Key。');
      if (!safeStorage.isEncryptionAvailable()) throw new Error('系统安全存储不可用。');
      try { return safeStorage.decryptString(Buffer.from(saved.encrypted, 'base64')); }
      catch { throw new Error('当前 Windows 账户无法读取此 Key，请在模型设置中重新填写。'); }
    }
  };
}
module.exports = { atomicJSON, readJSON, createStorage };
