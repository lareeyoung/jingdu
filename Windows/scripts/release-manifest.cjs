#!/usr/bin/env node
'use strict';
// Only successful, actual Windows runs produce a release manifest. No flags can
// substitute for the developer/packaged renderer and media smoke evidence.
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { createReadStream } = require('node:fs');
const { pipeline } = require('node:stream/promises');

async function json(file) { return JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, '')); }
async function digest(file) {
  const stat = await fs.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) throw new Error(`Missing or invalid release input: ${file}`);
  const hash = createHash('sha256');
  await pipeline(createReadStream(file), hash);
  return { name: path.basename(file), size: stat.size, sha256: hash.digest('hex') };
}
async function evidence(validation, name) {
  const result = await json(path.join(validation, name + '.json'));
  if (result.exitCode !== 0) throw new Error(`${name} did not exit successfully.`);
  const stdout = await fs.readFile(path.join(validation, name + '.stdout.log'), 'utf8');
  const stderr = await fs.readFile(path.join(validation, name + '.stderr.log'), 'utf8');
  return { result, stdout, stderr };
}
function parseSmoke(text, name) {
  if (text.includes('JINGDU_SMOKE_FAILED')) throw new Error(`${name}: smoke reported failure.`);
  const matches = [...text.matchAll(/^JINGDU_SMOKE_OK (.+)\r?$/gm)];
  if (matches.length !== 1) throw new Error(`${name}: exactly one smoke result is required.`);
  const smoke = JSON.parse(matches[0][1]);
  if (smoke.app !== true || smoke.api !== true || smoke.node !== 'undefined' ||
      ['probe', 'transcode', 'rendererPlayback', 'seek'].some(key => smoke.media?.[key] !== true)) {
    throw new Error(`${name}: app isolation, renderer playback/seek, probe and transcode must all pass.`);
  }
  return smoke;
}
function parseTests(text) {
  const count = key => {
    const match = text.match(new RegExp(`^(?:#|ℹ) ${key} (\\d+)\\s*$`, 'm'));
    if (!match) throw new Error(`Test summary is missing ${key}.`);
    return Number(match[1]);
  };
  const result = Object.fromEntries(['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo'].map(key => [key, count(key)]));
  if (result.tests < 1 || result.pass !== result.tests || result.fail || result.cancelled || result.skipped || result.todo)
    throw new Error('All tests, including real media tests, must pass without skips.');
  return result;
}
async function createManifest({ root, gitSHA, host = { platform: process.platform, arch: process.arch, release: os.release() } }) {
  if (host.platform !== 'win32' || host.arch !== 'x64') throw new Error('Release evidence must be collected on Windows x64.');
  if (!/^[a-f0-9]{40}$/i.test(gitSHA || '')) throw new Error('A full Git commit SHA is required.');
  const pkg = await json(path.join(root, 'package.json'));
  if (pkg.version !== '1.6.0-beta.1' || pkg.devDependencies.electron !== '44.4.4' || pkg.devDependencies['electron-builder'] !== '26.15.3')
    throw new Error('Release package/tool versions do not match this Windows preview.');
  const validation = path.join(root, 'validation'), dist = path.join(root, 'dist');
  const engineChecks = {};
  for (const engine of ['ffmpeg', 'ffprobe', 'whisper']) {
    const run = await evidence(validation, engine), text = run.stdout + '\n' + run.stderr;
    const expected = engine === 'whisper' ? /usage:[\s\S]*whisper/i : new RegExp(`${engine} version`, 'i');
    if (!expected.test(text)) throw new Error(`${engine}: startup output was not recognized.`);
    engineChecks[engine] = { exitCode: run.result.exitCode, command: engine === 'whisper' ? 'whisper-cli.exe --help' : `${engine}.exe -version` };
  }
  const testRun = await evidence(validation, 'tests');
  const tests = parseTests(testRun.stdout + '\n' + testRun.stderr);
  const development = await evidence(validation, 'development-smoke');
  const packaged = await evidence(validation, 'packaged-smoke');
  const smokes = {
    development: parseSmoke(development.stdout + '\n' + development.stderr, 'Development'),
    packaged: parseSmoke(packaged.stdout + '\n' + packaged.stderr, 'Packaged')
  };
  // Check the DLLs really made it into the packaged app, not just the build tree.
  const resources = path.join(root, 'resources'), bundled = path.join(dist, 'win-unpacked', 'resources', 'tools');
  const runtime = await json(path.join(resources, 'runtime-build.json'));
  if (runtime.vendor !== 'Microsoft Corporation' || runtime.architecture !== 'x64' || runtime.signatureVerified !== true || !Array.isArray(runtime.files))
    throw new Error('Verified Microsoft runtime provenance is missing.');
  const names = runtime.files.map(file => file.name);
  if (new Set(names).size !== names.length || ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll'].some(name => !names.includes(name)))
    throw new Error('Required Microsoft CRT/OpenMP DLLs are missing.');
  for (const file of runtime.files) {
    if (!/^[a-z0-9_.-]+\.dll$/i.test(file.name)) throw new Error('Invalid runtime filename.');
    const actual = await digest(path.join(bundled, file.name));
    if (actual.size !== file.size || actual.sha256 !== file.sha256) throw new Error(`Packaged runtime differs: ${file.name}`);
  }
  const tools = [];
  for (const name of ['ffmpeg.exe', 'ffprobe.exe', 'whisper-cli.exe', 'whisper.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll']) {
    const prepared = await digest(path.join(resources, name)), actual = await digest(path.join(bundled, name));
    if (prepared.sha256 !== actual.sha256) throw new Error(`Packaged media tool differs: ${name}`);
    tools.push(actual);
  }
  const files = await Promise.all(['exe', 'zip'].map(ext => digest(path.join(dist, `Jingdu-${pkg.version}-Windows-x64.${ext}`))));
  const manifest = {
    schemaVersion: 1, product: '镜读', version: pkg.version, tag: `v${pkg.version}-win`, gitSHA,
    generatedAt: new Date().toISOString(), platform: 'windows-x64', files,
    build: { node: process.version, electron: pkg.devDependencies.electron, electronBuilder: pkg.devDependencies['electron-builder'], runner: 'windows-2022', osRelease: host.release },
    signing: { signed: false, note: 'Unsigned colleague preview; Windows SmartScreen may display an unknown-publisher warning.' },
    validation: {
      engines: engineChecks, tests, smoke: smokes,
      scope: ['Actual bundled engine startup', 'Offline Node tests with media tests enabled', 'Development and packaged app startup',
        'Renderer API bridge and disabled Node integration', 'Synthetic video probe/transcode', 'Renderer video playback and seek'],
      notTested: ['NSIS installation/uninstallation', 'Real Whisper model inference', 'Seed relay/API requests', 'Windows 10/11 desktop manual testing'],
      syntheticMediaOnly: true
    },
    components: { tools, runtime, whisper: await json(path.join(resources, 'whisper-build.json')),
      media: await json(path.join(resources, 'media-licenses', 'SOURCES.json')) }
  };
  await fs.writeFile(path.join(dist, 'RELEASE.json'), JSON.stringify(manifest, null, 2) + '\n');
  const checksums = [...files, await digest(path.join(dist, 'RELEASE.json'))];
  await fs.writeFile(path.join(dist, 'SHA256SUMS'), checksums.map(file => `${file.sha256}  ${file.name}`).join('\n') + '\n');
  return manifest;
}
if (require.main === module) {
  if (process.argv.length !== 2) { console.error('Usage: node scripts/release-manifest.cjs (requires GITHUB_SHA)'); process.exitCode = 1; }
  else createManifest({ root: path.resolve(__dirname, '..'), gitSHA: process.env.GITHUB_SHA })
    .then(result => console.log(`Verified ${result.files.length} Windows release files for ${result.gitSHA}; wrote RELEASE.json and SHA256SUMS.`))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
module.exports = { createManifest, parseSmoke, parseTests, digest };
