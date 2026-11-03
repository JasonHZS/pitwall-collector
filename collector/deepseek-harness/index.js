// 本地导航桥：不读取消息，不执行任务，不接管审批，也不新增监听端口。
// 提问：把自己排到 user-questions/request 应答方链头，Pitwall 监听时先答，超时或出错让位回原生卡片。
import { lstat, mkdir, open, readFile, rename, rm, stat as statFile, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, join } from 'node:path';
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

// ---- 提问：在 Pitwall 里回答 ask_user_question ----
//
// 提问与审批共用同一套 Agent 作用域 waterfall（user-questions/request）：监听者按注册顺序排成
// 应答方链，返回回答即结案，调用 next() 才把请求让给后面的原生卡片。这里用 prepend 排到链头，
// Pitwall 监听时先答；Pitwall 没在监听、超时、请求取消或内部出错都 next() 让位，绝不在链上抛错。
// 定时提问（wait.timed，超时后仍可经 userQuestions.answer 补答）直接让位——原生卡片靠 attachWait
// 认领剩余时间，我们的等待会吃掉它的窗口；带 intent 的提问（计划评审之类要展示 detail）同样让位。
const QUESTION_LIMIT_MS = 60_000;
const safeName = value => typeof value === 'string' ? value.replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 128) : '';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// Pitwall 的表单只接能完整显示的题：id 与题干都非空且不重复，选项标签非空不重复。
// Harness 的每道题都允许自定义文本（回答里的 custom 字段），allowOther 恒为 true。
function questionForm(list) {
  if (!Array.isArray(list) || list.length === 0) return null;
  const ids = new Set(), texts = new Set(), out = [];
  for (const question of list) {
    if (question?.intent !== undefined) return null;
    if (typeof question?.id !== 'string' || question.id === '' || ids.has(question.id)) return null;
    if (typeof question.question !== 'string' || question.question === '' || texts.has(question.question)) return null;
    if (question.options !== undefined && !Array.isArray(question.options)) return null;
    const labels = new Set(), options = [];
    for (const option of question.options ?? []) {
      if (typeof option?.label !== 'string' || option.label === '' || labels.has(option.label)) return null;
      labels.add(option.label);
      options.push(typeof option.description === 'string' && option.description !== ''
        ? { label: option.label, description: option.description } : { label: option.label });
    }
    ids.add(question.id);
    texts.add(question.question);
    out.push({
      id: question.id, question: question.question,
      header: typeof question.header === 'string' ? question.header : '',
      multiSelect: question.multiSelect === true, allowOther: true, options,
    });
  }
  return out;
}

// 决定文件是 {"answers": [{"id", "selected", "custom"?}]}：每道题恰好一条，selected 只含该题选项。
// 无效内容不猜、不重试——按没答处理，让位给原生卡片。
function acceptBatch(questions, text) {
  let reply;
  try { reply = JSON.parse(text); } catch { return undefined; }
  const answers = reply?.answers;
  if (!Array.isArray(answers) || answers.length !== questions.length) return undefined;
  const byId = new Map(questions.map(q => [q.id, q]));
  const seen = new Set(), items = [];
  for (const item of answers) {
    const question = typeof item?.id === 'string' ? byId.get(item.id) : undefined;
    if (!question || seen.has(item.id)) return undefined;
    seen.add(item.id);
    const selected = item.selected === undefined ? [] : item.selected;
    if (!Array.isArray(selected) || !selected.every(label =>
      typeof label === 'string' && question.options.some(option => option.label === label))) return undefined;
    const entry = { id: item.id, selected };
    if (item.custom !== undefined) {
      if (typeof item.custom !== 'string' || item.custom.trim() === '') return undefined;
      entry.custom = item.custom;
    }
    items.push(entry);
  }
  return { answers: items };
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
  // 卸载标记一消失（目录、权限或 installed.json 任一项不符），路由与提问应答都让位——
  // 用户移除安装后 Harness 里已加载的插件还可能在内存里活一会儿，不能继续接管。
  const installed = async () => {
    const stat = await lstat(directory).catch(() => null);
    return !!stat?.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid()
      && !(stat.mode & 0o077)
      && (await readJSON(join(directory, 'installed.json')).catch(() => null))?.v === 1;
  };
  const route = async request => {
    if (disposed || !(await installed())) return new Response(null, { status: 503 });
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

  // ---- 提问应答方（~/.pitwall/approvals/，与 hook 协议同一目录） ----
  const approvals = join(dirname(directory), 'approvals');
  const questionPending = new Set();
  let questionSequence = 0;
  const questionLimitMs = config?.questionWaitMs ?? QUESTION_LIMIT_MS;

  const listening = async () => {
    try { return Date.now() - (await statFile(join(approvals, 'listening'))).mtimeMs <= 6_000; }
    catch { return false; }
  };

  // 写请求文件并轮询决定文件；拿到合法回答、超时、停监听或被取消时结束。
  const waitForAnswers = async (questions, sessionID, cwd, signal) => {
    const id = `${Math.floor(Date.now() / 1000)}-${process.pid}-${++questionSequence}`;
    const requestFile = join(approvals, 'requests', `deepseek-harness.${safeName(sessionID)}.ask_user_question.${id}.json`);
    const decisionFile = join(approvals, 'decisions', id);
    const record = {
      v: 1, id, agent: 'deepseek-harness', created_at: Date.now() / 1000, pid: process.pid,
      session_id: sessionID, tool_name: 'ask_user_question', answer_format: 'answers-batch-v1',
      tool_input: { questions },
      ...(typeof cwd === 'string' && cwd !== '' ? { cwd } : {}),
    };
    if (signal?.aborted) return undefined;
    try {
      await mkdir(join(approvals, 'requests'), { recursive: true, mode: 0o700 });
      await mkdir(join(approvals, 'decisions'), { recursive: true, mode: 0o700 });
      await writeJSON(requestFile, record);
    } catch { await rm(`${requestFile}`).catch(() => {}); return undefined; }
    const control = new AbortController();
    questionPending.add(control);
    const onAbort = () => control.abort();
    // abort 事件只发一次：注册监听前先补查，初始化期间错过的取消不会重放。
    if (signal?.aborted) control.abort();
    else signal?.addEventListener?.('abort', onAbort, { once: true });
    const deadline = Date.now() + questionLimitMs;
    try {
      while (!disposed && !control.signal.aborted && !signal?.aborted) {
        const text = await readFile(decisionFile, 'utf8').catch(() => null);
        if (text !== null) return signal?.aborted ? undefined : acceptBatch(questions, text);
        if (Date.now() >= deadline || !(await listening()) || !(await installed())) return undefined;
        await sleep(200);
      }
      return undefined;
    } finally {
      signal?.removeEventListener?.('abort', onAbort);
      questionPending.delete(control);
      await rm(requestFile, { force: true }).catch(() => {});
      await rm(decisionFile, { force: true }).catch(() => {});
    }
  };

  const onQuestion = async function (request, next) {
    try {
      const session = request?.agent?.session;
      const sessionID = plainID(session?.id) ? session.id : '';
      if (disposed || !sessionID || request.wait !== undefined || request.signal?.aborted
          || !(await installed()) || !(await listening())) return next();
      const questions = questionForm(request.questions);
      if (!questions) return next();
      const batch = await waitForAnswers(questions, sessionID, session?.cwd, request.signal);
      return batch ?? next();
    } catch { return next(); }
  };

  ctx.effect(() => {
    if (typeof ctx.on !== 'function') return () => {};
    const dispose = ctx.on('user-questions/request', onQuestion, { prepend: true });
    return () => { dispose?.(); for (const control of [...questionPending]) control.abort(); };
  }, 'Pitwall: answer questions');
}
