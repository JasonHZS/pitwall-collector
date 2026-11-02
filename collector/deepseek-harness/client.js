// Harness 的客户端模块格式；只在桌面主窗口加载，不让浏览器窗口跟着切换。
window.__ModuleLoader__.load({
  id: '@pitwall/deepseek-harness-navigation',
  factory: () => ({
    inject: ['uiWorkspace', 'sessions', 'workspaces', 'layout'],
    apply(ctx) {
      if (window.location.protocol !== 'dsh-app:' || window.location.hostname !== 'app' || window !== window.top) return;
      if (typeof ctx.effect !== 'function') return;
      const endpoint = '/api/pitwall-navigation';
      const lifetime = new AbortController();
      let lastID;
      let timer;
      let active;
      const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
      // 版本号不决定能力；先检查实际服务和快照，再允许切换主视图。
      const state = () => {
        try {
          if (typeof ctx.uiWorkspace?.openSession !== 'function' || typeof ctx.sessions?.retain !== 'function'
              || typeof ctx.sessions?.list?.getSnapshot !== 'function' || typeof ctx.workspaces?.list?.getSnapshot !== 'function'
              || typeof ctx.layout?.panelInfo?.getSnapshot !== 'function') return null;
          const catalog = ctx.sessions.list.getSnapshot();
          const workspaces = ctx.workspaces.list.getSnapshot();
          if (!object(catalog) || !object(workspaces) || typeof catalog.phase !== 'string' || typeof workspaces.phase !== 'string') return null;
          if (catalog.phase !== 'ready' || workspaces.phase !== 'ready') return { ready: false };
          const panel = ctx.layout.panelInfo.getSnapshot();
          if (!object(catalog.byId) || !Array.isArray(workspaces.archivedSessionIds) || !object(panel)
              || (panel.activePanelId !== null && typeof panel.activePanelId !== 'string')) return null;
          return { ready: true, catalog, workspaces, panel };
        } catch { return null; }
      };
      const selectionReadable = row => object(row?.retainedBy)
        && (row.retainedBy.mainView === undefined || (Number.isFinite(row.retainedBy.mainView) && row.retainedBy.mainView >= 0));
      const call = async (body, signal = lifetime.signal, compatible = true) => {
        const response = await fetch(body ? `${endpoint}/result` : endpoint, {
          method: body ? 'POST' : 'GET', cache: 'no-store',
          ...(body ? { headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }
            : { headers: { 'x-pitwall-navigation-capable': String(compatible) } }),
          signal: AbortSignal.any([signal, AbortSignal.timeout(2000)]),
        });
        if (!response.ok) throw new Error('Pitwall navigation unavailable');
        return response.json();
      };
      const navigate = async (request, signal) => {
        const { id, sessionID, expiresAt } = request;
        if (!/^[a-zA-Z0-9_-]{1,128}$/.test(sessionID) || Date.now() >= expiresAt) return 'failed';
        const initial = state();
        if (!initial) return 'incompatible';
        if (!initial.ready) return 'failed';
        const { catalog, workspaces } = initial;
        if (!catalog.byId[sessionID]) return 'missing';
        if (workspaces.archivedSessionIds.includes(sessionID)) return 'archived';
        if (!selectionReadable(catalog.byId[sessionID])) return 'incompatible';
        // 先加载目标历史；失败时不把当前对话切到一个错误页面。
        const reference = ctx.sessions.retain(sessionID, { source: 'workspaceOperation' });
        try {
          if (typeof reference?.ready?.then !== 'function' || typeof reference?.release !== 'function') return 'incompatible';
          await Promise.race([
            reference.ready,
            new Promise((_, reject) => {
              const deadline = AbortSignal.any([signal, AbortSignal.timeout(Math.max(1, expiresAt - Date.now()))]);
              if (deadline.aborted) reject(deadline.reason);
              else deadline.addEventListener('abort', () => reject(deadline.reason), { once: true });
            }),
          ]);
          const current = (await call(undefined, signal)).request;
          if (signal.aborted || current?.id !== id || Date.now() >= expiresAt) return 'superseded';
          // Fetch 等待期间也可能发生 Host 重连或插件热重载。
          const beforeOpen = state();
          if (!beforeOpen) return 'incompatible';
          if (!beforeOpen.ready) return 'failed';
          if (!beforeOpen.catalog.byId[sessionID]) return 'missing';
          if (!selectionReadable(beforeOpen.catalog.byId[sessionID])) return 'incompatible';
          if (beforeOpen.workspaces.archivedSessionIds.includes(sessionID)) return 'archived';
          ctx.uiWorkspace.openSession(sessionID);
          let afterOpen = state();
          if (!afterOpen || (afterOpen.ready && afterOpen.catalog.byId[sessionID] && !selectionReadable(afterOpen.catalog.byId[sessionID]))) return 'incompatible';
          // 主面板打开时中间区域不是对话。openSession 的 reveal 通常已关掉它；快照仍盖住目标时再请求一次。
          const selected = snapshot => snapshot.ready && (snapshot.catalog.byId[sessionID]?.retainedBy.mainView ?? 0) > 0;
          if (selected(afterOpen) && afterOpen.panel.activePanelId !== null && typeof ctx.layout.selectPanel === 'function') {
            try { ctx.layout.selectPanel(null); } catch { /* 仍以随后的快照判断，不把调用当成成功。 */ }
            afterOpen = state();
            if (!afterOpen || (afterOpen.ready && afterOpen.catalog.byId[sessionID] && !selectionReadable(afterOpen.catalog.byId[sessionID]))) return 'incompatible';
          }
          return selected(afterOpen) && afterOpen.panel.activePanelId === null ? 'selected' : 'failed';
        } finally { if (typeof reference?.release === 'function') reference.release(); }
      };
      const start = request => {
        active?.abort();
        const controller = new AbortController();
        active = controller;
        const signal = AbortSignal.any([lifetime.signal, controller.signal]);
        void (async () => {
          let status;
          try { status = await navigate(request, signal); } catch { status = 'failed'; }
          if (!signal.aborted && active === controller) {
            try { await call({ id: request.id, sessionID: request.sessionID, status }, signal); } catch { /* 等下一轮请求。 */ }
          }
        })();
      };
      const poll = async () => {
        try {
          // 列表就绪才发布心跳，冷启动中的窗口不能被误认作能导航。
          const current = state();
          if (current && !current.ready) return;
          const request = (await call(undefined, lifetime.signal, current !== null)).request;
          if (!current) { active?.abort(); return; }
          if (request && request.id !== lastID) {
            lastID = request.id;
            start(request);
          }
        } catch { /* Host 重载或插件卸载时安静等待；不发模型请求。 */ }
        finally { if (!lifetime.signal.aborted) timer = setTimeout(poll, 500); }
      };
      ctx.effect(() => {
        poll();
        return () => { lifetime.abort(); clearTimeout(timer); };
      }, 'Pitwall: desktop session navigation');
    },
  }),
});
