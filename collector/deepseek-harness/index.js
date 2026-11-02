// 本地导航桥：不读取消息，不执行任务，不接管审批，也不新增监听端口。
import { lstat, open, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

export const inject = ['connection'];
const path = '/api/pitwall-navigation';
const plainID = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value);
const validRequest = (r, now = Date.now()) => r?.v === 1 && plainID(r.id) && plainID(r.sessionID)
  && Number.isSafeInteger(r.createdAt) && Number.isSafeInteger(r.expiresAt)
  && r.createdAt <= now + 1000 && r.expiresAt > now && r.expiresAt - r.createdAt <= 8000;

async function readJSON(file) {
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > 4096 || stat.uid !== process.getuid()) return null;
    return JSON.parse(await handle.readFile('utf8'));
  } finally { await handle.close(); }
}

async function writeJSON(file, value) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    const handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
    try { await handle.writeFile(JSON.stringify(value)); }
    finally { await handle.close(); }
    await rename(temporary, file);
  }
  finally { await unlink(temporary).catch(() => {}); }
}

export function apply(ctx, config) {
  if (typeof ctx.connection?.fetch?.register !== 'function' || typeof ctx.effect !== 'function') return;
  const directory = config?.directory;
  if (typeof directory !== 'string' || !directory.startsWith('/')) throw new Error('Pitwall navigation requires an absolute directory');
  const requestFile = join(directory, 'request.json');
  let disposed = false;
  let heartbeatAt = 0;
  let lastCompatibility;
  // Serialize writes from overlapping polls; the desktop is the sole consumer.
  let operations = Promise.resolve();
  const respond = value => new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
  const route = async request => {
    const stat = await lstat(directory).catch(() => null);
    if (disposed || !stat?.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077)) return new Response(null, { status: 503 });
    if ((await readJSON(join(directory, 'installed.json')).catch(() => null))?.v !== 1) return new Response(null, { status: 503 });
    const current = await readJSON(requestFile).catch(() => null);
    if (request.method === 'GET') {
      const compatible = request.headers.get('x-pitwall-navigation-capable') !== 'false';
      if (Date.now() - heartbeatAt >= 2000 || compatible !== lastCompatibility) {
        heartbeatAt = Date.now();
        lastCompatibility = compatible;
        await writeJSON(join(directory, 'listening.json'), { v: 1, at: heartbeatAt, pid: process.pid, compatible });
      }
      return respond({ request: compatible && validRequest(current) ? current : null });
    }
    if (Number(request.headers.get('content-length') ?? 0) > 4096) return new Response(null, { status: 413 });
    const chunks = [];
    let size = 0;
    const reader = request.body?.getReader();
    if (reader) try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 4096) { await reader.cancel(); return new Response(null, { status: 413 }); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    const text = Buffer.concat(chunks).toString('utf8');
    let reply;
    try { reply = JSON.parse(text); } catch { return new Response(null, { status: 400 }); }
    if (!validRequest(current) || reply.id !== current.id || reply.sessionID !== current.sessionID
        || !['selected', 'missing', 'archived', 'failed', 'superseded', 'incompatible'].includes(reply.status)) return new Response(null, { status: 409 });
    await writeJSON(join(directory, 'response.json'), { v: 1, id: current.id, sessionID: current.sessionID, status: reply.status, at: Date.now() });
    return respond({ ok: true });
  };
  const fetch = request => {
    const result = operations.then(() => route(request)).catch(() => new Response(null, { status: 503 }));
    operations = result.then(() => {});
    return result;
  };
  // Harness 的 streaming bridge 会给 Request 附加 body，不能用于 GET。
  ctx.effect(() => ctx.connection.fetch.register({ path, methods: ['GET'], requestBody: 'buffered', fetch }), 'Pitwall: navigation requests');
  ctx.effect(() => ctx.connection.fetch.register({ path: `${path}/result`, methods: ['POST'], requestBody: 'streaming', fetch }), 'Pitwall: navigation results');
  ctx.effect(() => () => { disposed = true; }, 'Pitwall: stop session navigation');
}
