#!/usr/bin/env node
'use strict';
// Build-time download only. The application never downloads code at runtime.
// Official v1.8.3 x64 asset digest is published by GitHub's release API:
// https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/v1.8.3
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const version = '1.8.3';
const url = `https://github.com/ggml-org/whisper.cpp/releases/download/v${version}/whisper-bin-x64.zip`;
const sha256 = 'd824b1e37599f882b396e73f1ee0bfd5d0529f700314c48311dcbd00b803321d';
const archiveSize = 3968674;
const resources = path.resolve(__dirname, '../resources');

async function main() {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'jingdu-whisper-build-'));
  try {
    const archive = path.join(folder, 'whisper.zip'), stage = path.join(folder, 'expanded');
    const index = process.argv.indexOf('--archive');
    let buffer;
    if (index >= 0) {
      if (!process.argv[index + 1]) throw new Error('--archive 需要指定官方归档路径。');
      const local = path.resolve(process.argv[index + 1]);
      if ((await fs.stat(local)).size !== archiveSize) throw new Error('本地归档大小不匹配。');
      buffer = await fs.readFile(local);
    } else {
      const response = await fetch(url, { signal: AbortSignal.timeout(120000) });
      if (!response.ok) throw new Error(`官方下载失败：HTTP ${response.status}`);
      if (!response.url.startsWith('https://')) throw new Error('下载跳转到非 HTTPS 地址，已停止。');
      const parts = []; let size = 0;
      for await (const part of response.body) {
        size += part.byteLength;
        if (size > archiveSize) throw new Error('下载文件大小超过官方归档，已停止。');
        parts.push(Buffer.from(part));
      }
      buffer = Buffer.concat(parts);
    }
    if (buffer.length !== archiveSize || createHash('sha256').update(buffer).digest('hex') !== sha256)
      throw new Error('字幕引擎 SHA256 校验失败，未安装。');
    await fs.writeFile(archive, buffer); await fs.mkdir(stage);
    // Only the pinned, verified official archive reaches extraction.
    const extraction = process.platform === 'win32'
      ? spawnSync('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
          'Expand-Archive -LiteralPath $env:JINGDU_WHISPER_ARCHIVE -DestinationPath $env:JINGDU_WHISPER_STAGE -Force'],
          { env: { ...process.env, JINGDU_WHISPER_ARCHIVE: archive, JINGDU_WHISPER_STAGE: stage }, windowsHide: true, encoding: 'utf8' })
      : spawnSync('/usr/bin/unzip', ['-q', archive, '-d', stage], { encoding: 'utf8' });
    if (extraction.error || extraction.status !== 0) throw new Error('无法解压官方字幕引擎归档。');
    const files = ['whisper-cli.exe', 'whisper.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll'];
    for (const name of files) {
      const source = path.join(stage, 'Release', name), file = await fs.readFile(source);
      if (file.toString('ascii', 0, 2) !== 'MZ') throw new Error(`官方归档缺少有效 Windows 程序：${name}`);
    }
    // The repository contains the license from the same pinned engine release.
    const license = await fs.readFile(path.resolve(__dirname, '../../Resources/SubtitleEngine/LICENSE-whisper.cpp'));
    if (createHash('sha256').update(license).digest('hex') !== 'e562a2ddfaf8280537795ac5ecd34e3012b6582a147ef69ba6a6a5c08c84757d')
      throw new Error('字幕引擎许可文件不匹配。');
    await fs.mkdir(resources, { recursive: true });
    for (const name of files) {
      const temporary = path.join(resources, name + '.new');
      await fs.copyFile(path.join(stage, 'Release', name), temporary);
      await fs.rename(temporary, path.join(resources, name));
    }
    await fs.writeFile(path.join(resources, 'LICENSE-whisper.cpp.txt'), license);
    await fs.writeFile(path.join(resources, 'whisper-build.json'), JSON.stringify({ version, platform: 'windows-x64', source: url, archiveSHA256: sha256, files }, null, 2) + '\n');
    console.log(`已准备官方 whisper.cpp v${version} Windows x64 引擎（SHA256 已校验）。模型由用户在设置中选择，未自动下载。`);
  } finally { await fs.rm(folder, { recursive: true, force: true }); }
}
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { version, url, sha256, archiveSize };
