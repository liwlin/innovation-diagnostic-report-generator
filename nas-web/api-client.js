(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedApiClient = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  class ApiClientError extends Error {
    constructor(status, error) {
      super((error && error.message) || `HTTP ${status}`);
      this.name = 'ApiClientError';
      this.status = status;
      this.code = (error && error.code) || 'request_failed';
      this.details = (error && error.details) || {};
    }
  }

  function readCookie(cookieText, name) {
    const prefix = `${encodeURIComponent(name)}=`;
    for (const part of String(cookieText || '').split(';')) {
      const value = part.trim();
      if (value.startsWith(prefix)) return decodeURIComponent(value.slice(prefix.length));
    }
    return '';
  }

  function createApiClient(options) {
    const settings = options || {};
    const fetchImpl = settings.fetchImpl || globalThis.fetch.bind(globalThis);
    const cookieReader = settings.cookieReader || (() => (typeof document === 'undefined' ? '' : document.cookie));
    const onUnauthorized = settings.onUnauthorized || function () {};

    async function request(path, requestOptions) {
      const config = requestOptions || {};
      const method = config.method || 'GET';
      const headers = { Accept: 'application/json', ...(config.headers || {}) };
      if (config.body !== undefined) headers['Content-Type'] = 'application/json';
      if (config.csrf !== false && !['GET', 'HEAD', 'OPTIONS'].includes(method)) {
        headers['X-CSRF-Token'] = readCookie(cookieReader(), 'mkseed_csrf');
      }
      const response = await fetchImpl(path, {
        method,
        credentials: 'same-origin',
        headers,
        body: config.body === undefined ? undefined : JSON.stringify(config.body),
      });
      if (response.status === 204) return null;
      const payload = await response.json();
      if (!response.ok) {
        const error = new ApiClientError(response.status, payload.error);
        if (response.status === 401) onUnauthorized(error);
        throw error;
      }
      return payload;
    }

    function queryPath(path, filters) {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(filters || {})) {
        if (value === undefined || value === null || value === '') continue;
        params.set(key, String(value));
      }
      const query = params.toString();
      return query ? `${path}?${query}` : path;
    }

    return Object.freeze({
      getSession: () => request('/api/session', { csrf: false }),
      login: (username, password) =>
        request('/api/auth/login', {
          method: 'POST',
          csrf: false,
          body: { username, password },
        }),
      logout: () => request('/api/auth/logout', { method: 'POST' }),
      listEvaluations: (filters) => request(queryPath('/api/evaluations', filters), { csrf: false }),
      createBatch: (input) => request('/api/batches', { method: 'POST', body: input }),
      createEvaluation: (batchId, input) =>
        request(`/api/batches/${encodeURIComponent(batchId)}/evaluations`, {
          method: 'POST',
          body: input,
        }),
      trashEvaluation: (id) =>
        request(`/api/evaluations/${encodeURIComponent(id)}/trash`, { method: 'POST' }),
      restoreEvaluation: (id) =>
        request(`/api/evaluations/${encodeURIComponent(id)}/restore`, { method: 'POST' }),
      permanentlyDeleteEvaluation: (id, reason) =>
        request(`/api/evaluations/${encodeURIComponent(id)}`, {
          method: 'DELETE',
          body: { reason },
        }),
      listGenerations: (evaluationId) =>
        request(`/api/evaluations/${encodeURIComponent(evaluationId)}/generations`, { csrf: false }),
      listUsers: () => request('/api/admin/users', { csrf: false }),
      createUser: (input) => request('/api/admin/users', { method: 'POST', body: input }),
      updateUser: (id, input) =>
        request(`/api/admin/users/${encodeURIComponent(id)}`, { method: 'PATCH', body: input }),
      listAudit: (filters) => request(queryPath('/api/admin/audit', filters), { csrf: false }),
      queryPath,
    });
  }

  return Object.freeze({ ApiClientError, createApiClient, readCookie });
});
