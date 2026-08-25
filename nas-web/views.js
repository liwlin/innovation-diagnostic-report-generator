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
    const adminLinks = session.user.role === 'admin'
      ? [element('div', { className: 'nav-label' }, '管理员'), navButton('账号管理', 'users', activeView === 'users', () => onNavigate('users')), navButton('操作审计', 'audit', activeView === 'audit', () => onNavigate('audit'))]
      : [];
    return element(
      'div',
      { className: 'app-shell' },
      element(
        'aside',
        { className: 'sidebar', 'aria-label': '主导航' },
        element('img', { className: 'sidebar-logo', src: '/assets/logo-lockup.png', alt: 'MakerSeed 种子创客工坊' }),
        navButton('全部记录', 'records', activeView === 'records', () => onNavigate('records')),
        navButton('回收站', 'trash', activeView === 'trash', () => onNavigate('trash')),
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

  function recordWorkspace({ records, filters, trashed, loading, error, onFilter, onNew, onEdit, onTrash, onRestore, onReports }) {
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

  return Object.freeze({ element, loginView, newRecordDialog, recordWorkspace, replace, shell });
});
