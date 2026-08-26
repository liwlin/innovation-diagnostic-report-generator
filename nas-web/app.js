(function () {
  'use strict';

  const root = document.getElementById('app');
  const runtime = MakerSeedRuntime.getConfig(window.location, window.__MKSEED_RUNTIME__);
  const views = MakerSeedViews;
  const state = { session: null, activeView: 'records', records: [], users: [], audit: [], filters: {}, loading: false, error: '', loginBusy: false, loginError: '', importFile: null, importPreview: null, importMessage: '' };
  const api = MakerSeedApiClient.createApiClient({ onUnauthorized: showLogin });

  function renderLogin() {
    views.replace(root, views.loginView({
      busy: state.loginBusy,
      error: state.loginError,
      async onSubmit(username, password) {
        state.loginBusy = true; state.loginError = ''; renderLogin();
        try { state.session = await api.login(username, password); state.loginBusy = false; await showRecords(false); }
        catch (error) { state.loginBusy = false; state.loginError = error.code === 'invalid_credentials' ? '账号或密码错误' : error.message; renderLogin(); }
      },
    }));
  }

  function showLogin() {
    state.session = null;
    state.loginBusy = false;
    renderLogin();
  }

  function renderShell(content) {
    views.replace(root, views.shell({
      session: state.session,
      version: runtime.appVersion + (runtime.commitSha ? ` · ${runtime.commitSha.slice(0, 7)}` : ''),
      activeView: state.activeView,
      content,
      onNavigate(view) {
        if (view === 'records') showRecords(false);
        else if (view === 'trash') showRecords(true);
        else if (view === 'users') showUsers();
        else if (view === 'audit') showAudit('');
      },
      async onLogout() {
        try { await api.logout(); }
        finally {
          for (const key of views.nasLogoutStorageKeys()) localStorage.removeItem(key);
          showLogin();
        }
      },
    }));
  }

  function renderRecords(trashed) {
    const workspace = views.recordWorkspace({
      records: state.records, filters: state.filters, trashed, isAdmin: state.session.user.role === 'admin', loading: state.loading, error: state.error,
      onFilter(filters) { state.filters = filters; clearTimeout(state.filterTimer); state.filterTimer = setTimeout(() => loadRecords(trashed), 250); },
      onNew: showNewRecord,
      onEdit(record) { window.location.assign(`/editor?evaluation_id=${encodeURIComponent(record.evaluation_id)}`); },
      onTrash: showTrashConfirm,
      async onRestore(record) { await api.restoreEvaluation(record.evaluation_id); await loadRecords(true); },
      onPermanentDelete: showPermanentDelete,
      async onReports(record) { const items = await api.listGenerations(record.evaluation_id); window.alert(items.length ? `共有 ${items.length} 次生成记录，请进入编辑页下载。` : '尚未生成报告。'); },
    });
    renderShell(workspace);
  }

  async function loadRecords(trashed) {
    state.loading = true; state.error = ''; renderRecords(trashed);
    try {
      const page = await api.listEvaluations({ ...state.filters, trashed, limit: 100 });
      state.records = page.items;
    } catch (error) { state.error = error.message; }
    state.loading = false; renderRecords(trashed);
  }

  async function showRecords(trashed) {
    state.activeView = trashed ? 'trash' : 'records'; state.filters = {}; state.records = [];
    await loadRecords(trashed);
  }

  function showNewRecord() {
    let dialog;
    async function submit(values) {
      const dateValue = values.event_date || new Date().toISOString().slice(0, 10);
      try {
        const batch = await api.createBatch({ display_name: values.display_name, event_date: dateValue, date_label: values.date_label, teacher_label: values.teacher_label, fill_date: dateValue });
        const editor = await api.createEvaluation(batch.id, {
          student: { name: values.student_name, grade: values.grade, slot: values.slot },
          payload: { schema_version: 1, mods: [], customMods: [], chart: 'radar', rates: [0,0,0,0,0], skills: [{m:'',p:'',r:0},{m:'',p:'',r:0},{m:'',p:'',r:0}], obs1:'', obs2:'', dir:-1, reason:'', classIndex:'', recommended_class:'', dirCustom:{name:'',desc:''}, attendp:'是', talk:'已完成', intent:'高', why:'', ref:'', follow:'', note:'', generated:false },
        });
        window.location.assign(`/editor?evaluation_id=${encodeURIComponent(editor.evaluation_id)}`);
      } catch (error) {
        const panel = dialog.querySelector('.dialog');
        let message = dialog.querySelector('.error-message');
        if (!message) {
          message = views.element('p', { className: 'error-message', role: 'alert' });
          panel.insertBefore(message, panel.querySelector('.dialog-actions'));
        }
        message.textContent = error.message;
      }
    }
    dialog = views.newRecordDialog({ busy: false, error: '', onCancel: () => dialog.remove(), onSubmit: submit });
    document.body.append(dialog);
  }

  function showPermanentDelete(record) {
    let dialog;
    async function confirmDelete(reason) {
      const validation = views.validatePermanentDelete(state.session.user.role, reason);
      if (!validation.ok) {
        const replacement = views.permanentDeleteDialog({ record, error: validation.message, onCancel: () => dialog.remove(), onConfirm: confirmDelete });
        dialog.replaceWith(replacement); dialog = replacement; return;
      }
      try {
        await api.permanentlyDeleteEvaluation(record.evaluation_id, validation.reason);
        dialog.remove();
        await loadRecords(true);
      } catch (error) {
        const replacement = views.permanentDeleteDialog({ record, error: error.message, onCancel: () => dialog.remove(), onConfirm: confirmDelete });
        dialog.replaceWith(replacement); dialog = replacement;
      }
    }
    dialog = views.permanentDeleteDialog({ record, error: '', onCancel: () => dialog.remove(), onConfirm: confirmDelete });
    document.body.append(dialog);
  }

  function showTrashConfirm(record) {
    let dialog;
    async function confirmTrash() {
      try { await api.trashEvaluation(record.evaluation_id); dialog.remove(); await loadRecords(false); }
      catch (error) { dialog.remove(); state.error = error.message; renderRecords(false); }
    }
    dialog = views.confirmationDialog({ title: '移入回收站', message: `将“${record.student_name}”移入回收站？老师和管理员之后仍可恢复。`, confirmLabel: '移入回收站', danger: true, onCancel: () => dialog.remove(), onConfirm: confirmTrash });
    document.body.append(dialog);
  }

  async function showUsers(errorMessage) {
    state.activeView = 'users'; state.error = errorMessage || '';
    try { state.users = await api.listUsers(); }
    catch (error) { state.error = error.message; }
    const content = views.userWorkspace({
      users: state.users, error: state.error, importPreview: state.importPreview, importMessage: state.importMessage,
      async onCreate(input) { try { await api.createUser(input); await showUsers(); } catch (error) { await showUsers(error.message); } },
      async onToggle(user) { try { await api.updateUser(user.id, { is_active: !user.is_active }); await showUsers(); } catch (error) { await showUsers(error.message); } },
      onReset: showPasswordReset,
      async onPreviewImport(file) {
        if (!file) { state.importMessage = '请选择应急 JSON 文件'; await showUsers(); return; }
        try { state.importFile = file; state.importPreview = await api.previewEmergencyImport(file); state.importMessage = ''; await showUsers(); }
        catch (error) { state.importPreview = null; state.importMessage = error.message; await showUsers(); }
      },
      async onConfirmImport() {
        if (!state.importFile || !state.importPreview) return;
        try {
          const result = await api.confirmEmergencyImport(state.importFile, state.importPreview.sha256);
          state.importMessage = `导入完成：新增 ${result.counts.imported} 条，冲突 ${result.counts.conflict} 条未覆盖。`;
          state.importFile = null; state.importPreview = null; await showUsers();
        } catch (error) { state.importMessage = error.message; await showUsers(); }
      },
    });
    renderShell(content);
  }

  function showPasswordReset(user) {
    let dialog;
    async function confirmReset(password) {
      if (String(password).length < 12) {
        const replacement = views.passwordResetDialog({ user, error: '密码至少需要 12 个字符', onCancel: () => dialog.remove(), onConfirm: confirmReset });
        dialog.replaceWith(replacement); dialog = replacement; return;
      }
      try { await api.updateUser(user.id, { password }); dialog.remove(); await showUsers(); }
      catch (error) { const replacement = views.passwordResetDialog({ user, error: error.message, onCancel: () => dialog.remove(), onConfirm: confirmReset }); dialog.replaceWith(replacement); dialog = replacement; }
    }
    dialog = views.passwordResetDialog({ user, error: '', onCancel: () => dialog.remove(), onConfirm: confirmReset });
    document.body.append(dialog);
  }

  async function showAudit(action) {
    state.activeView = 'audit'; state.loading = true; state.error = '';
    renderShell(views.auditWorkspace({ items: state.audit, action, loading: true, error: '', onActionFilter: showAudit }));
    try { const page = await api.listAudit({ action, limit: 100 }); state.audit = page.items; }
    catch (error) { state.error = error.message; }
    state.loading = false;
    renderShell(views.auditWorkspace({ items: state.audit, action, loading: false, error: state.error, onActionFilter: showAudit }));
  }

  async function boot() {
    try { state.session = await api.getSession(); await showRecords(false); }
    catch (error) { if (error.status !== 401) state.loginError = error.message; showLogin(); }
  }

  boot();
})();
