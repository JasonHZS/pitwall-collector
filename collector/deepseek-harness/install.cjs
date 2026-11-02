// 用 Harness 自带的 Electron Node 与 YAML 解析器离线安装，无需包管理器。
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createRequire } = require('node:module');
const crypto = require('node:crypto');
const name = '@pitwall/deepseek-harness-navigation';
const id = 'pitwall-navigation';
const files = ['package.json', 'index.js', 'client.js'];

// 与 Harness 的加载器使用同一份 engines 声明和 prerelease 规则；不逐个锁定 rc。
function supportsRuntime(runtime, source = __dirname) {
  const fromRuntime = createRequire(runtime);
  const manifest = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
  return fromRuntime('semver').satisfies(fromRuntime('@deepseek-ai/dsh/package.json').version,
    manifest.engines.dsh, { includePrerelease: true });
}

function removeOwnEntries(document, yaml, strict = false) {
  let changed = false;
  for (let index = document.contents.items.length - 1; index >= 0; index--) {
    const row = document.contents.items[index];
    if (!yaml.isMap(row)) continue;
    const inserted = row.get('insert', true);
    if (!yaml.isSeq(inserted)) continue;
    let removed = false;
    for (let child = inserted.items.length - 1; child >= 0; child--) {
      const entry = inserted.items[child];
      if (!yaml.isMap(entry) || entry.get('id') !== id) continue;
      if (entry.get('name') !== name) {
        if (strict) throw new Error('plugin id belongs to another package; left unchanged');
        continue;
      }
      inserted.delete(child);
      removed = changed = true;
    }
    // 用户原有的空 insert 及其注释不属于我们。
    if (removed && inserted.items.length === 0) document.delete(index);
  }
  return changed;
}

function install(action, { home = os.homedir(), runtime, source = __dirname } = {}) {
  const pw = path.join(home, '.pitwall');
  const directory = path.join(pw, 'deepseek-harness');
  const target = path.join(pw, 'plugins', 'deepseek-harness-navigation');
  const profile = path.join(home, '.dsh/profiles/desktop');
  const patchFile = path.join(profile, 'cordis.patch.yml');
  const manifestFile = path.join(profile, 'package.json');
  const link = path.join(profile, 'node_modules', ...name.split('/'));
  const marker = path.join(directory, 'installed.json');
  const exists = p => { try { return fs.lstatSync(p); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } };
  const safeDirectory = (p, create = true) => {
    for (let current = p; current !== home && current !== path.dirname(current); current = path.dirname(current)) {
      const stat = exists(current);
      if (stat && (!stat.isDirectory() || stat.isSymbolicLink())) throw new Error('unsafe installation directory');
    }
    if (create) fs.mkdirSync(p, { recursive: true, mode: 0o700 });
  };
  const atomic = (p, text) => {
    const tmp = `${p}.${crypto.randomUUID()}.tmp`;
    try {
      fs.writeFileSync(tmp, text, { mode: exists(p)?.mode & 0o777 || 0o600, flag: 'wx' });
      fs.renameSync(tmp, p);
    } finally { fs.rmSync(tmp, { force: true }); }
  };
  const backup = changes => {
    if (!changes.length) return;
    const folder = path.join(pw, 'backups', `deepseek-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`);
    safeDirectory(folder);
    for (const [file] of changes) if (exists(file)) fs.copyFileSync(file, path.join(folder, path.basename(file)));
    const backups = fs.readdirSync(path.dirname(folder)).filter(n => /^deepseek-[0-9]{13}-[a-f0-9]{6}$/.test(n)).sort().reverse();
    for (const old of backups.slice(10)) fs.rmSync(path.join(path.dirname(folder), old), { recursive: true, force: true });
  };
  if (action === 'uninstall') {
    // 清理不依赖 Harness、完整 profile 或可解析的 YAML；能安全修改的配置独立处理。
    for (const folder of [directory, target]) safeDirectory(folder, false);
    const changes = [];
    for (const file of [manifestFile, patchFile]) {
      try {
        if (!exists(file)) continue;
        safeDirectory(profile, false);
        if (!exists(file).isFile() || exists(file).size > 1024 * 1024) continue;
        const before = fs.readFileSync(file, 'utf8');
        let after;
        if (file === manifestFile) {
          const manifest = JSON.parse(before);
          if (!manifest?.dependencies || !Object.hasOwn(manifest.dependencies, name)) continue;
          delete manifest.dependencies[name];
          after = JSON.stringify(manifest, null, 2) + '\n';
        } else {
          const yaml = createRequire(runtime)('yaml');
          const document = yaml.parseDocument(before, { customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: value => value }] });
          if (document.errors.length || !yaml.isSeq(document.contents) || !removeOwnEntries(document, yaml)) continue;
          after = String(document);
        }
        changes.push([file, before, after]);
      } catch { /* 损坏或不可读的用户配置保持原样，仍然停用并移除本地插件。 */ }
    }
    try {
      backup(changes);
      for (const [file, , after] of changes) atomic(file, after);
    } catch { /* 备份或写入失败时保留残留提示；不阻挡移除自己的文件。 */ }
    // 先撤销精准导航资格和未完成请求。
    for (const file of ['installed.json', 'request.json', 'response.json', 'listening.json']) fs.rmSync(path.join(directory, file), { force: true });
    let linkPending = false;
    try {
      safeDirectory(path.dirname(link), false);
      if (exists(link)?.isSymbolicLink() && fs.readlinkSync(link) === target) fs.unlinkSync(link);
    } catch { linkPending = true; }
    for (const file of files) fs.rmSync(path.join(target, file), { force: true });
    const pending = linkPending || [manifestFile, patchFile].some(file => {
      try {
        if (!exists(file)) return false;
        safeDirectory(profile, false);
        if (!exists(file).isFile() || exists(file).size > 1024 * 1024) return true;
        const before = fs.readFileSync(file, 'utf8');
        if (file === manifestFile) {
          try {
            const manifest = JSON.parse(before);
            return Boolean(manifest?.dependencies && Object.hasOwn(manifest.dependencies, name));
          } catch { return before.includes(name); }
        }
        try {
          const yaml = createRequire(runtime)('yaml');
          const document = yaml.parseDocument(before, { customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: value => value }] });
          if (document.errors.length || !yaml.isSeq(document.contents)) return before.includes(name);
          return removeOwnEntries(document, yaml);
        } catch { return before.includes(name); }
      } catch { return true; }
    });
    if (pending) {
      safeDirectory(directory);
      atomic(path.join(directory, 'cleanup-pending.json'), '{"v":1}\n');
    } else fs.rmSync(path.join(directory, 'cleanup-pending.json'), { force: true });
    return;
  }
  if (!['install', 'uninstall', 'refresh'].includes(action)) throw new Error('unknown action');
  if (action === 'refresh') {
    if (!exists(marker)) return;
    safeDirectory(target);
    for (const file of files) {
      const next = fs.readFileSync(path.join(source, file));
      if (!exists(path.join(target, file)) || !next.equals(fs.readFileSync(path.join(target, file)))) atomic(path.join(target, file), next);
    }
    return;
  }
  if (!exists(profile) || !exists(manifestFile)) throw new Error('DeepSeek Harness desktop profile not found; open Harness once first');
  if (!supportsRuntime(runtime, source)) throw new Error('unsupported Harness version');
  safeDirectory(profile);
  safeDirectory(pw);
  for (const p of [patchFile, manifestFile]) if (exists(p)?.isSymbolicLink()) throw new Error('profile configuration is a symlink; left unchanged');
  const yaml = createRequire(runtime)('yaml');
  const beforePatch = exists(patchFile) ? fs.readFileSync(patchFile, 'utf8') : '[]\n';
  const beforeManifest = fs.readFileSync(manifestFile, 'utf8');
  const document = yaml.parseDocument(beforePatch, { customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: value => value }] });
  if (document.errors.length || !yaml.isSeq(document.contents)) throw new Error('profile patch is not a valid YAML sequence; left unchanged');
  const manifest = JSON.parse(beforeManifest);
  if (!manifest || Array.isArray(manifest) || typeof manifest !== 'object'
      || (manifest.dependencies !== undefined && (!manifest.dependencies || Array.isArray(manifest.dependencies) || typeof manifest.dependencies !== 'object'))) throw new Error('invalid profile manifest');
  removeOwnEntries(document, yaml, true);
  if (action === 'install') {
    document.add({ insert: [{ id, name, config: { directory } }] });
    manifest.dependencies = { ...manifest.dependencies, [name]: `file:${target}` };
  } else if (manifest.dependencies) delete manifest.dependencies[name];
  document.contents.flow = false;
  const nextPatch = String(document);
  const nextManifest = JSON.stringify(manifest, null, 2) + '\n';
  const existingLink = exists(link);
  if (existingLink && (!existingLink.isSymbolicLink() || fs.readlinkSync(link) !== target)) throw new Error('plugin package path is occupied; left unchanged');
  const changes = [[manifestFile, beforeManifest, nextManifest], [patchFile, beforePatch, nextPatch]].filter(([, before, after]) => before !== after);
  backup(changes);
  if (action === 'install') {
    safeDirectory(target);
    safeDirectory(directory);
    fs.chmodSync(directory, 0o700);
    for (const file of files) atomic(path.join(target, file), fs.readFileSync(path.join(source, file)));
    safeDirectory(path.dirname(link));
    if (!existingLink) fs.symlinkSync(target, link);
  }
  const written = [];
  try {
    // patch 最后写入，触发 Harness 热重载时依赖和包已经可用。
    for (const [file, before, after] of changes) { atomic(file, after); written.push([file, before]); }
    fs.rmSync(path.join(directory, 'cleanup-pending.json'), { force: true });
    if (action === 'install') atomic(marker, JSON.stringify({ v: 1, version: JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8')).version }) + '\n');
  } catch (error) {
    for (const [file, before] of written.reverse()) atomic(file, before);
    if (action === 'install' && !existingLink) fs.rmSync(link, { force: true });
    throw error;
  }
}

module.exports = { install, supportsRuntime };
if (require.main === module) {
  try { install(process.argv[2], { runtime: process.argv[3] }); }
  catch { console.error('Could not update the DeepSeek Harness navigation plugin. The profile may be unavailable, invalid, or not writable.'); process.exitCode = 1; }
}
