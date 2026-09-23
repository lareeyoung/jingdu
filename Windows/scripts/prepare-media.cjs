#!/usr/bin/env node
'use strict';

// Build-time preparation only; the packaged app never downloads executable code.
// The SHA-256 values below were checked against the pinned GitHub release assets:
// https://api.github.com/repos/eugeneware/ffmpeg-static/releases/tags/b6.1.1
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createHash, randomUUID } = require('node:crypto');
const { Readable, Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { createGunzip } = require('node:zlib');

const RELEASE = 'b6.1.1';
const VERSION = '6.1.1-essentials_build-www.gyan.dev';
const SOURCE_COMMIT = 'e38092ef9395d7049f871ef4d5411eb410e283e0';
const BASE = `https://github.com/eugeneware/ffmpeg-static/releases/download/${RELEASE}/`;
const resources = path.resolve(__dirname, '../resources');
const files = Object.freeze([
  { asset: 'ffmpeg-win32-x64.gz', size: 29581307,
    sha256: '8883a3dffbd0a16cf4ef95206ea05283f78908dbfb118f73c83f4951dcc06d77',
    target: 'ffmpeg.exe', expandedSize: 82797568,
    expandedSHA256: '04e1307997530f9cf2fe35cba2ca7e8875ca91da02f89d6c7243df819c94ad00' },
  { asset: 'ffprobe-win32-x64.gz', size: 29521644,
    sha256: 'f309e6223ad89d2fe54bccd420a7709b66fd27540674e92309578ed491a43c8d',
    target: 'ffprobe.exe', expandedSize: 82668032,
    expandedSHA256: '3a7e2dc003dc2cd1472827e4c7c4f056ae1ae0ae7c5bbc580c99b49827351ba4' },
  { asset: 'win32-x64.LICENSE', size: 35147,
    sha256: '8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903',
    target: 'media-licenses/LICENSE-FFmpeg-GPLv3.txt' },
  { asset: 'win32-x64.README', size: 39494,
    sha256: 'a636a7183c58006351acbaf35303c0ed85c6e1320fd4e80de453ba6157de6311',
    target: 'media-licenses/README-FFmpeg-build.txt' }
]);

const sources = Object.freeze({
  component: 'FFmpeg and ffprobe', version: VERSION, platform: 'windows-x64',
  binaryProducer: 'Gyan Doshi (gyan.dev)', binaryProducerURL: 'https://www.gyan.dev/ffmpeg/builds/',
  distributionRepository: 'https://github.com/eugeneware/ffmpeg-static',
  release: RELEASE, releaseURL: `https://github.com/eugeneware/ffmpeg-static/releases/tag/${RELEASE}`,
  digestSource: `https://api.github.com/repos/eugeneware/ffmpeg-static/releases/tags/${RELEASE}`,
  license: 'GPLv3', licenseFile: 'LICENSE-FFmpeg-GPLv3.txt',
  sourceRepository: 'https://github.com/FFmpeg/FFmpeg', sourceCommit: SOURCE_COMMIT,
  sourceTree: `https://github.com/FFmpeg/FFmpeg/tree/${SOURCE_COMMIT}`,
  sourceArchive: `https://github.com/FFmpeg/FFmpeg/archive/${SOURCE_COMMIT}.tar.gz`,
  sourceArchiveScope: 'FFmpeg source tree. Third-party library versions and enabled components are recorded in the original build README; this is not a bundled complete third-party source archive.',
  buildConfigurationAndDependencyVersions: 'README-FFmpeg-build.txt',
  libx264: { included: true, version: 'v0.164.3172', upstream: 'https://code.videolan.org/videolan/x264' },
  files: files.map(f => ({ file: f.target, download: BASE + f.asset, downloadBytes: f.size,
    downloadSHA256: f.sha256, installedBytes: f.expandedSize || f.size, installedSHA256: f.expandedSHA256 || f.sha256 }))
});
const sourcesJSON = JSON.stringify(sources, null, 2) + '\n';
const sourceNotice = `FFmpeg / ffprobe Windows x64 distribution\n\n` +
  `Version: ${VERSION}\nLicense: GPLv3 (see LICENSE-FFmpeg-GPLv3.txt)\n` +
  `Binary producer: Gyan Doshi, https://www.gyan.dev/ffmpeg/builds/\n` +
  `Pinned distribution: https://github.com/eugeneware/ffmpeg-static/releases/tag/${RELEASE}\n\n` +
  `The original, unmodified build README is included as README-FFmpeg-build.txt.\n` +
  `It identifies FFmpeg commit e38092ef93 and lists enabled components and third-party library versions, including libx264 v0.164.3172.\n\n` +
  `Exact FFmpeg source tree:\n${sources.sourceTree}\n` +
  `Download of that source tree:\n${sources.sourceArchive}\n` +
  `x264 upstream source repository:\n${sources.libx264.upstream}\n\n` +
  `SOURCES.json records the fixed release, source revision and SHA-256 checksums.\n` +
  `These source links identify provenance; the package does not contain a complete archive of all statically linked third-party sources.\n`;

function verifier(expectedSize, expectedHash, label) {
  let length = 0;
  const hash = createHash('sha256');
  return new Transform({
    transform(chunk, encoding, callback) {
      length += chunk.length;
      if (length > expectedSize) { callback(new Error(`${label} 超过固定版本的文件大小，已停止。`)); return; }
      hash.update(chunk); callback(null, chunk);
    },
    flush(callback) {
      if (length !== expectedSize || hash.digest('hex') !== expectedHash) callback(new Error(`${label} SHA-256 或大小不匹配，未安装。`));
      else callback();
    }
  });
}

async function verifyFile(file, size, sha256) {
  const stat = await fsp.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== size) throw new Error(`资源大小或类型不匹配：${path.basename(file)}`);
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  if (hash.digest('hex') !== sha256) throw new Error(`资源 SHA-256 不匹配：${path.basename(file)}`);
}

async function validatePE(file) {
  const handle = await fsp.open(file, 'r');
  try {
    const dos = Buffer.alloc(64); const header = Buffer.alloc(6);
    if ((await handle.read(dos, 0, 64, 0)).bytesRead !== 64 || dos.toString('ascii', 0, 2) !== 'MZ') throw new Error('下载内容不是 Windows 程序。');
    const position = dos.readUInt32LE(60);
    if (position < 64 || position > 16 * 1024 * 1024 || (await handle.read(header, 0, 6, position)).bytesRead !== 6 ||
        header.readUInt32LE(0) !== 0x00004550 || header.readUInt16LE(4) !== 0x8664) throw new Error('下载的程序不是 Windows x64 PE 文件。');
  } finally { await handle.close(); }
}

async function download(url, destination, spec) {
  const allowed = new Set(['github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com']);
  const signal = AbortSignal.timeout(180_000);
  let current = new URL(url);
  for (let redirects = 0; redirects <= 5; redirects++) {
    if (current.protocol !== 'https:' || !allowed.has(current.hostname) || current.username || current.password) {
      throw new Error('下载地址跳转到非预期来源，已停止。');
    }
    const response = await fetch(current, { redirect: 'manual', signal });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); await response.body?.cancel();
      if (!location) throw new Error('下载服务返回了无效跳转。');
      current = new URL(location, current); continue;
    }
    if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error(`固定版本下载失败：HTTP ${response.status}`); }
    const length = response.headers.get('content-length');
    if (length && Number(length) !== spec.size) { await response.body.cancel(); throw new Error('下载大小与固定版本不符。'); }
    await pipeline(Readable.fromWeb(response.body), verifier(spec.size, spec.sha256, spec.asset),
      fs.createWriteStream(destination, { flags: 'wx', mode: 0o600 }), { signal });
    return;
  }
  throw new Error('下载跳转次数过多。');
}

async function verifyInstalled() {
  for (const spec of files) {
    const file = path.join(resources, spec.target);
    await verifyFile(file, spec.expandedSize || spec.size, spec.expandedSHA256 || spec.sha256);
    if (spec.expandedSize) await validatePE(file);
  }
  if (await fsp.readFile(path.join(resources, 'media-licenses/SOURCES.json'), 'utf8') !== sourcesJSON ||
      await fsp.readFile(path.join(resources, 'media-licenses/SOURCES.txt'), 'utf8') !== sourceNotice) {
    throw new Error('媒体来源说明与固定版本不匹配。');
  }
}

async function installFile(source, destination) {
  await fsp.mkdir(path.dirname(destination), { recursive: true });
  const temp = destination + `.media-${randomUUID()}.new`;
  try { await fsp.copyFile(source, temp); await fsp.rename(temp, destination); }
  finally { await fsp.rm(temp, { force: true }); }
}

async function main(args = process.argv.slice(2)) {
  let assets;
  if (args.length === 1 && args[0] === '--verify') {
    await verifyInstalled(); console.log(`已验证 FFmpeg ${VERSION}：x64、SHA-256、许可与来源说明均匹配。`); return;
  }
  if (args.length) {
    if (args.length !== 2 || args[0] !== '--assets') throw new Error('用法：node scripts/prepare-media.cjs [--verify | --assets 固定发行资产目录]');
    assets = path.resolve(args[1]);
  }
  try { await verifyInstalled(); console.log(`FFmpeg ${VERSION} 资源已就绪，校验通过，无需重新下载。`); return; } catch { /* Prepare all pinned files before replacing any installed file. */ }
  const folder = await fsp.mkdtemp(path.join(os.tmpdir(), 'jingdu-media-build-'));
  try {
    const staged = [];
    for (const spec of files) {
      const archive = path.join(folder, spec.asset);
      if (assets) {
        const local = path.join(assets, spec.asset);
        await verifyFile(local, spec.size, spec.sha256); await fsp.copyFile(local, archive);
        await verifyFile(archive, spec.size, spec.sha256);
      } else {
        console.log(`正在准备固定资源：${spec.asset}`); await download(BASE + spec.asset, archive, spec);
      }
      let source = archive;
      if (spec.expandedSize) {
        source = path.join(folder, spec.target);
        await pipeline(fs.createReadStream(archive), createGunzip(),
          verifier(spec.expandedSize, spec.expandedSHA256, spec.target), fs.createWriteStream(source, { flags: 'wx', mode: 0o600 }));
        await validatePE(source);
      }
      staged.push({ source, destination: path.join(resources, spec.target) });
    }
    const readme = await fsp.readFile(path.join(folder, 'win32-x64.README'), 'utf8');
    if (!readme.includes(`Version: ${VERSION}`) || !readme.includes('License: GPL v3') ||
        !readme.includes('Source Code: https://github.com/FFmpeg/FFmpeg/commit/e38092ef93') || !readme.includes('libx264')) {
      throw new Error('发行说明与预期版本、许可、源码或编码器不符。');
    }
    await fsp.writeFile(path.join(folder, 'SOURCES.json'), sourcesJSON);
    await fsp.writeFile(path.join(folder, 'SOURCES.txt'), sourceNotice);
    staged.push({ source: path.join(folder, 'SOURCES.json'), destination: path.join(resources, 'media-licenses/SOURCES.json') },
      { source: path.join(folder, 'SOURCES.txt'), destination: path.join(resources, 'media-licenses/SOURCES.txt') });
    for (const item of staged) await installFile(item.source, item.destination);
    await verifyInstalled();
    console.log(`已准备 FFmpeg / ffprobe ${VERSION} Windows x64，压缩包与程序 SHA-256 均已核对。许可及源码来源位于 resources/media-licenses。`);
  } finally { await fsp.rm(folder, { recursive: true, force: true }); }
}

if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { RELEASE, VERSION, SOURCE_COMMIT, files, sources, main, verifyInstalled };
