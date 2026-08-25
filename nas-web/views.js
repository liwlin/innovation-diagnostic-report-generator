(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedViews = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function element(tag, attributes, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes || {})) {
      if (key === 'className') node.className = value;
      else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2).toLowerCase(), value);
      else if (value !== undefined && value !== null) node.setAttribute(key, String(value));
    }
    for (const child of children.flat()) {
      if (child === undefined || child === null) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  function replace(rootNode, content) {
    rootNode.replaceChildren(content);
  }

  function navigationItems(role) {
    const items = [
      { view: 'records', label: '全部记录', icon: 'records' },
      { view: 'trash', label: '回收站', icon: 'trash' },
    ];
    if (role === 'admin') {
      items.push(
        { view: 'users', label: '账号管理', icon: 'users', admin: true },
        { view: 'audit', label: '操作审计', icon: 'audit', admin: true },
      );
    }
    return items;
  }

  function validatePermanentDelete(role, reason) {
    if (role !== 'admin') return { ok: false, message: '需要管理员权限' };
    const normalized = String(reason || '').trim();
    if (normalized.length < 4) return { ok: false, message: '请填写至少 4 个字符的删除原因' };
    return { ok: true, reason: normalized };
  }

  function nasLogoutStorageKeys() {
    return ['mkseed_diag_aicfg_v1', 'mkseed_nas_ui_v1'];
  }

  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    svg.classList.add('nav-icon');
    const paths = {
      records: ['M5 4h14v16H5z', 'M8 8h8M8 12h8M8 16h5'],
      trash: ['M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5'],
      users: ['M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20v-2a5 5 0 0 1 10 0v2M16 11a3 3 0 0 0 0-6M15 14a5 5 0 0 1 6 4v2'],
      audit: ['M12 3l8 4v5c0 5-3.4 8-8 9-4.6-1-8-4-8-9V7z', 'M9 12l2 2 4-5'],
    };
    for (const data of paths[name] || paths.records) {
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', data);
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');
      svg.append(path);
    }
    return svg;
  }

  function loginView({ onSubmit, error, busy }) {
    const username = element('input', { id: 'username', name: 'username', className: 'control', autocomplete: 'username', required: true });
    const password = element('input', { id: 'password', name: 'password', className: 'control', type: 'password', autocomplete: 'current-password', required: true });
    const form = element(
      'form',
      {
        onSubmit(event) {
          event.preventDefault();
          onSubmit(username.value, password.value);
        },
      },
      element('h1', { className: 'login-title' }, '科创诊断记录'),
      element('p', { className: 'login-subtitle' }, '工坊内部系统'),
      element('div', { className: 'field' }, element('label', { for: 'username' }, '账号'), username),
      element('div', { className: 'field' }, element('label', { for: 'password' }, '密码'), password),
      error ? element('p', { className: 'error-message', role: 'alert' }, error) : null,
      element('button', { className: 'primary-button', type: 'submit', disabled: busy ? 'disabled' : null }, busy ? '登录中…' : '登录'),
      element('p', { className: 'login-note' }, '仅限工坊内部授权老师使用'),
    );
    const page = element(
      'section',
      { className: 'login-page' },
      element(
        'div',
        { className: 'login-stack' },
        element('div', { className: 'login-brand' }, element('img', { src: '/assets/logo-lockup.png', alt: 'MakerSeed 种子创客工坊' })),
        element('div', { className: 'login-panel' }, form),
      ),
    );
    queueMicrotask(() => username.focus());
    return page;
  }

  function navButton(label, iconName, active, onClick) {
    return element('button', { className: 'nav-button', type: 'button', 'aria-current': active ? 'page' : null, onClick }, icon(iconName), label);
  }

  function shell({ session, version, activeView, onNavigate, onLogout, content }) {
    const navigation = navigationItems(session.user.role);
    const primaryLinks = navigation.filter((item) => !item.admin).map((item) => navButton(item.label, item.icon, activeView === item.view, () => onNavigate(item.view)));
    const adminItems = navigation.filter((item) => item.admin);
    const adminLinks = adminItems.length
      ? [element('div', { className: 'nav-label' }, '管理员'), ...adminItems.map((item) => navButton(item.label, item.icon, activeView === item.view, () => onNavigate(item.view)))]
      : [];
    return element(
      'div',
      { className: 'app-shell' },
      element(
        'aside',
        { className: 'sidebar', 'aria-label': '主导航' },
        element('img', { className: 'sidebar-logo', src: '/assets/logo-lockup.png', alt: 'MakerSeed 种子创客工坊' }),
        primaryLinks,
        adminLinks,
      ),
      element(
        'section',
        { className: 'workspace' },
        element(
          'header',
          { className: 'topbar' },
          element('div', { className: 'topbar-title' }, element('h1', {}, '科创诊断记录'), element('span', { className: 'version' }, version)),
          element('div', { className: 'user-actions' }, element('span', {}, session.user.display_name), element('button', { className: 'text-button', type: 'button', onClick: onLogout }, '退出登录')),
        ),
        element('div', { className: 'content' }, content),
      ),
    );
  }

  function recordWorkspace({ records, filters, trashed, isAdmin, loading, error, onFilter, onNew, onEdit, onTrash, onRestore, onPermanentDelete, onReports }) {
    const search = element('input', { className: 'control', value: filters.q || '', placeholder: '搜索学生姓名', 'aria-label': '搜索学生姓名' });
    search.addEventListener('input', () => onFilter({ ...filters, q: search.value }));
    const filterNames = [['date_from', '日期'], ['batch_id', '批次'], ['grade', '年级'], ['recommended_class', '推荐班级'], ['created_by', '创建者'], ['generation_status', '生成状态']];
    const filterControls = filterNames.map(([name, label]) => {
      const input = element('input', { className: 'control', value: filters[name] || '', placeholder: label, 'aria-label': label });
      input.addEventListener('change', () => onFilter({ ...filters, [name]: input.value }));
      return input;
    });
    const rows = records.map((record, index) => element(
      'tr',
      { className: index === 2 ? 'is-selected' : '' },
      element('td', {}, record.student_name),
      element('td', {}, record.event_date),
      element('td', {}, record.batch_name),
      element('td', {}, record.grade || '—'),
      element('td', {}, record.recommended_class || '—'),
      element('td', {}, `${record.updated_by.display_name} · ${String(record.updated_at).replace('T', ' ').slice(0, 16)}`),
      element('td', {}, record.generation_status || '未生成'),
      element(
        'td',
        { className: 'row-actions' },
        trashed ? element('button', { className: 'text-button', type: 'button', onClick: () => onRestore(record) }, '恢复') : element('button', { className: 'text-button', type: 'button', onClick: () => onEdit(record) }, '编辑'),
        element('button', { className: 'text-button', type: 'button', onClick: () => onReports(record) }, '查看报告'),
        trashed ? null : element('button', { className: 'text-button danger-link', type: 'button', onClick: () => onTrash(record) }, '移入回收站'),
        trashed && isAdmin ? element('button', { className: 'text-button danger-link', type: 'button', onClick: () => onPermanentDelete(record) }, '永久删除') : null,
      ),
    ));
    const table = element(
      'div',
      { className: 'table-frame' },
      element(
        'table',
        { className: 'record-table' },
        element('thead', {}, element('tr', {}, ...['学生', '体验日期', '批次', '年级', '推荐班级', '最后修改', '报告', '操作'].map((label) => element('th', { scope: 'col' }, label)))),
        element('tbody', {}, rows),
      ),
      loading || error || records.length === 0 ? element('div', { className: `status-line${error ? ' error-message' : ''}` }, error || (loading ? '正在加载记录…' : '没有符合条件的记录')) : null,
      element('div', { className: 'table-footer' }, element('span', {}, `共 ${records.length} 条`), element('span', {}, '每页最多 100 条')),
    );
    return element(
      'section',
      {},
      element('div', { className: 'toolbar' }, trashed ? element('div') : element('button', { className: 'new-button', type: 'button', onClick: onNew }, '新建记录'), search),
      element('div', { className: 'filters' }, filterControls),
      table,
    );
  }

  function newRecordDialog({ onCancel, onSubmit, busy, error }) {
    const fields = [
      ['display_name', '批次', '批次1'], ['event_date', '体验日期', '2026-08-26'], ['date_label', '报告日期文字', '8月26日'],
      ['teacher_label', '授课教师', '李老师'], ['student_name', '学生姓名', ''], ['grade', '年级', '三年级'], ['slot', '场次', '批次1 · 上午场'],
    ];
    const controls = {};
    const formFields = fields.map(([name, label, value]) => {
      controls[name] = element('input', { className: 'control', name, value, required: name === 'student_name' ? 'required' : null });
      return element('div', { className: 'field' }, element('label', {}, label), controls[name]);
    });
    return element(
      'div',
      { className: 'dialog-backdrop' },
      element(
        'form',
        { className: 'dialog', role: 'dialog', 'aria-modal': 'true', onSubmit(event) { event.preventDefault(); onSubmit(Object.fromEntries(Object.entries(controls).map(([key, input]) => [key, input.value]))); } },
        element('h2', {}, '新建记录'),
        element('div', { className: 'dialog-grid' }, formFields),
        error ? element('p', { className: 'error-message', role: 'alert' }, error) : null,
        element('div', { className: 'dialog-actions' }, element('button', { className: 'secondary-button', type: 'button', onClick: onCancel }, '取消'), element('button', { className: 'primary-button', type: 'submit', disabled: busy ? 'disabled' : null }, busy ? '创建中…' : '创建并编辑')),
      ),
    );
  }

  function permanentDeleteDialog({ record, onCancel, onConfirm, error }) {
    const reason = element('textarea', { className: 'control', rows: '4', placeholder: '请填写删除原因（至少 4 个字符）' });
    return element(
      'div',
      { className: 'dialog-backdrop' },
      element(
        'form',
        { className: 'dialog', role: 'dialog', 'aria-modal': 'true', onSubmit(event) { event.preventDefault(); onConfirm(reason.value); } },
        element('h2', {}, '永久删除记录'),
        element('p', {}, `即将删除“${record.student_name}”的在线记录和正式报告。`),
        element('p', { className: 'error-message' }, '历史加密备份在保留期内仍可能包含旧副本。'),
        element('div', { className: 'field' }, element('label', {}, '删除原因'), reason),
        error ? element('p', { className: 'error-message', role: 'alert' }, error) : null,
        element('div', { className: 'dialog-actions' }, element('button', { className: 'secondary-button', type: 'button', onClick: onCancel }, '取消'), element('button', { className: 'primary-button danger-button', type: 'submit' }, '确认永久删除')),
      ),
    );
  }

  function userWorkspace({ users, error, importPreview, importMessage, onCreate, onToggle, onReset, onPreviewImport, onConfirmImport }) {
    const username = element('input', { className: 'control', placeholder: '账号', required: 'required' });
    const displayName = element('input', { className: 'control', placeholder: '显示名', required: 'required' });
    const role = element('select', { className: 'control' }, element('option', { value: 'teacher' }, '老师'), element('option', { value: 'admin' }, '管理员'));
    const password = element('input', { className: 'control', type: 'password', placeholder: '初始密码（至少 12 位）', required: 'required' });
    const form = element(
      'form',
      { className: 'admin-create-form', onSubmit(event) { event.preventDefault(); onCreate({ username: username.value, display_name: displayName.value, role: role.value, password: password.value }); } },
      username, displayName, role, password,
      element('button', { className: 'new-button', type: 'submit' }, '创建账号'),
    );
    const rows = users.map((user) => element(
      'tr', {}, element('td', {}, user.username), element('td', {}, user.display_name), element('td', {}, user.role === 'admin' ? '管理员' : '老师'), element('td', {}, user.is_active ? '启用' : '停用'),
      element('td', { className: 'row-actions' }, element('button', { className: 'text-button', type: 'button', onClick: () => onToggle(user) }, user.is_active ? '停用' : '启用'), element('button', { className: 'text-button', type: 'button', onClick: () => onReset(user) }, '重置密码')),
    ));
    const importFile = element('input', { className: 'control', type: 'file', accept: 'application/json,.json', 'aria-label': '选择应急 JSON 文件' });
    const importSummary = importPreview
      ? `新增 ${importPreview.counts.new} · 重复 ${importPreview.counts.duplicate} · 冲突 ${importPreview.counts.conflict} · 无效 ${importPreview.counts.invalid}`
      : '先预览，再确认导入；不会自动覆盖 NAS 记录。';
    const importPanel = element(
      'section', { className: 'import-panel' }, element('h2', {}, '应急数据导入'),
      element('p', {}, importSummary), importMessage ? element('p', { className: 'error-message' }, importMessage) : null,
      element('div', { className: 'import-actions' }, importFile, element('button', { className: 'secondary-button', type: 'button', onClick: () => onPreviewImport(importFile.files[0]) }, '预览文件'), importPreview ? element('button', { className: 'primary-button', type: 'button', onClick: onConfirmImport }, '确认导入新增记录') : null),
    );
    return element('section', {}, form, error ? element('p', { className: 'error-message' }, error) : null, element('div', { className: 'table-frame' }, element('table', { className: 'record-table' }, element('thead', {}, element('tr', {}, ...['账号', '显示名', '角色', '状态', '操作'].map((label) => element('th', { scope: 'col' }, label)))), element('tbody', {}, rows))), importPanel);
  }

  function passwordResetDialog({ user, onCancel, onConfirm, error }) {
    const password = element('input', { className: 'control', type: 'password', autocomplete: 'new-password', placeholder: '新密码（至少 12 位）' });
    return element('div', { className: 'dialog-backdrop' }, element('form', { className: 'dialog', role: 'dialog', 'aria-modal': 'true', onSubmit(event) { event.preventDefault(); onConfirm(password.value); } }, element('h2', {}, `重置 ${user.display_name} 的密码`), element('div', { className: 'field' }, element('label', {}, '新密码'), password), error ? element('p', { className: 'error-message', role: 'alert' }, error) : null, element('div', { className: 'dialog-actions' }, element('button', { className: 'secondary-button', type: 'button', onClick: onCancel }, '取消'), element('button', { className: 'primary-button', type: 'submit' }, '确认重置'))));
  }

  function auditWorkspace({ items, action, loading, error, onActionFilter }) {
    const actionInput = element('input', { className: 'control', value: action || '', placeholder: '按动作筛选', 'aria-label': '按动作筛选' });
    actionInput.addEventListener('change', () => onActionFilter(actionInput.value));
    const rows = items.map((event) => element('tr', {}, element('td', {}, String(event.created_at).replace('T', ' ').slice(0, 19)), element('td', {}, event.actor_user_id || '系统'), element('td', {}, event.action), element('td', {}, event.target_type), element('td', {}, event.target_id || '—'), element('td', {}, event.target_label || '—')));
    return element('section', {}, element('div', { className: 'toolbar audit-toolbar' }, actionInput), error ? element('p', { className: 'error-message' }, error) : null, element('div', { className: 'table-frame' }, element('table', { className: 'record-table' }, element('thead', {}, element('tr', {}, ...['时间', '操作者', '动作', '目标类型', '目标 ID', '标签'].map((label) => element('th', { scope: 'col' }, label)))), element('tbody', {}, rows)), loading ? element('div', { className: 'status-line' }, '正在加载审计…') : null));
  }

  return Object.freeze({ auditWorkspace, element, loginView, nasLogoutStorageKeys, navigationItems, newRecordDialog, passwordResetDialog, permanentDeleteDialog, recordWorkspace, replace, shell, userWorkspace, validatePermanentDelete });
});
