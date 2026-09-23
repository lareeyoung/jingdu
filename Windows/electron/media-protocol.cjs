'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');

const CHUNK_SIZE = 64 * 1024;
const MIME = {
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mov': 'video/quicktime',
  '.webm': 'video/webm', '.mkv': 'video/x-matroska', '.avi': 'video/x-msvideo',
  '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.aac': 'audio/aac',
  '.wav': 'audio/wav', '.flac': 'audio/flac', '.ogg': 'audio/ogg',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp'
};

// Chromium requests a single interval when seeking. Multipart ranges are not
// supported; a 416 response reports the actual length instead of guessing.
function parseRange(value, size) {
  if (value == null) return null;
  const match = /^bytes=(\d*)-(\d*)$/i.exec(value.trim());
  if (!match || (!match[1] && !match[2]) || size === 0) return false;
  const first = match[1] ? Number(match[1]) : null;
  const last = match[2] ? Number(match[2]) : null;
  if ((first !== null && !Number.isSafeInteger(first)) || (last !== null && !Number.isSafeInteger(last))) return false;
  if (first === null) {
    if (last <= 0) return false;
    return { start: Math.max(0, size - last), end: size - 1 };
  }
  if (first >= size || (last !== null && last < first)) return false;
  return { start: first, end: Math.min(last ?? size - 1, size - 1) };
}

// file is resolved exclusively from the main process's unguessable token map.
// Do not call net.fetch(file://) here: Electron 44 returns a sliced body for a
// Range request with status 200 and no Content-Range, which breaks video seeks.
async function serveMediaFile(request, file) {
  const method = (request.method || 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  request.signal?.throwIfAborted();
  let handle;
  try { handle = await fs.open(file, 'r'); }
  catch (error) {
    return new Response(null, { status: error.code === 'ENOENT' || error.code === 'ENOTDIR' ? 404 : error.code === 'EACCES' || error.code === 'EPERM' ? 403 : 500 });
  }
  try {
    const stat = await handle.stat();
    if (!stat.isFile()) { await handle.close(); return new Response(null, { status: 404 }); }
    if (!Number.isSafeInteger(stat.size)) { await handle.close(); return new Response(null, { status: 500 }); }
    request.signal?.throwIfAborted();
    const headers = new Headers({
      'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'Accept-Ranges': 'bytes', 'Content-Length': String(stat.size),
      'Last-Modified': stat.mtime.toUTCString(), 'Cache-Control': 'no-store'
    });
    // A stale If-Range must get the complete representation. We publish only a
    // Last-Modified validator, so entity-tag If-Range values cannot match.
    const ifRange = request.headers.get('if-range');
    const rangeAllowed = !ifRange || (!/^W\//.test(ifRange) && !ifRange.startsWith('"') &&
      Number.isFinite(Date.parse(ifRange)) && Math.floor(stat.mtimeMs / 1000) <= Math.floor(Date.parse(ifRange) / 1000));
    const range = parseRange(method === 'GET' && rangeAllowed ? request.headers.get('range') : null, stat.size);
    if (range === false) {
      await handle.close(); headers.set('Content-Range', `bytes */${stat.size}`); headers.set('Content-Length', '0');
      return new Response(null, { status: 416, headers });
    }
    const status = range ? 206 : 200, start = range?.start ?? 0, end = range?.end ?? stat.size - 1;
    if (range) { headers.set('Content-Range', `bytes ${start}-${end}/${stat.size}`); headers.set('Content-Length', String(end - start + 1)); }
    if (method === 'HEAD' || stat.size === 0) { await handle.close(); return new Response(null, { status, headers }); }

    let position = start, finished = false, streamController;
    const close = async () => {
      request.signal?.removeEventListener('abort', abort);
      await handle.close();
    };
    const abort = () => {
      if (finished) return;
      finished = true;
      streamController.error(request.signal.reason || new DOMException('Aborted', 'AbortError'));
      void close().catch(() => {});
    };
    const body = new ReadableStream({
      start(controller) {
        streamController = controller;
        request.signal?.addEventListener('abort', abort, { once: true });
        if (request.signal?.aborted) abort();
      },
      async pull(controller) {
        if (finished) return;
        try {
          const buffer = Buffer.allocUnsafe(Math.min(CHUNK_SIZE, end - position + 1));
          const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
          if (finished) return;
          if (!bytesRead) throw new Error('The media file changed while it was being read.');
          position += bytesRead;
          controller.enqueue(buffer.subarray(0, bytesRead));
          if (position > end) { finished = true; controller.close(); await close(); }
        } catch (error) {
          if (finished) return;
          finished = true; controller.error(error); await close().catch(() => {});
        }
      },
      async cancel() { if (!finished) { finished = true; await close(); } }
    });
    return new Response(body, { status, headers });
  } catch (error) { await handle.close().catch(() => {}); throw error; }
}

module.exports = { serveMediaFile, parseRange, CHUNK_SIZE };
