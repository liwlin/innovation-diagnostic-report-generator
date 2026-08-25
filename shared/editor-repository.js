(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedEditorRepository = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const WORKSPACE_KEY = 'mkseed_diag_v3';

  function clone(value) {
    return value == null ? value : JSON.parse(JSON.stringify(value));
  }

  function readCookie(cookieText, name) {
    const prefix = `${encodeURIComponent(name)}=`;
    for (const part of String(cookieText || '').split(';')) {
      const trimmed = part.trim();
      if (trimmed.startsWith(prefix)) return decodeURIComponent(trimmed.slice(prefix.length));
    }
    return '';
  }

  class LocalRepository {
    constructor(options) {
      this.storage = options.storage;
      this.onStatus = options.onStatus || function () {};
      this.pending = null;
      this.document = null;
      this.disposed = false;
    }

    async load() {
      const raw = this.storage.getItem(WORKSPACE_KEY);
      this.document = raw ? JSON.parse(raw) : null;
      return clone(this.document);
    }

    scheduleSave(documentValue) {
      if (this.disposed) return;
      this.pending = clone(documentValue);
      this.onStatus({ state: 'saving' });
    }

    async flush() {
      if (this.disposed || this.pending == null) return clone(this.document);
      this.storage.setItem(WORKSPACE_KEY, JSON.stringify(this.pending));
      this.document = this.pending;
      this.pending = null;
      this.onStatus({ state: 'saved' });
      return clone(this.document);
    }

    current() {
      return clone(this.document);
    }

    isConflicted() {
      return false;
    }

    hasUnsaved() {
      return this.pending != null;
    }

    dispose() {
      this.disposed = true;
      this.pending = null;
    }
  }

  class ApiRepository {
    constructor(options) {
      this.config = options.config;
      this.fetchImpl = options.fetchImpl || globalThis.fetch.bind(globalThis);
      this.storage = options.storage;
      this.cookieReader = options.cookieReader || (() => (typeof document === 'undefined' ? '' : document.cookie));
      this.setTimeoutImpl = options.setTimeoutImpl || globalThis.setTimeout.bind(globalThis);
      this.clearTimeoutImpl = options.clearTimeoutImpl || globalThis.clearTimeout.bind(globalThis);
      this.onStatus = options.onStatus || function () {};
      this.timer = null;
      this.pending = null;
      this.inflight = null;
      this.document = null;
      this.conflicted = false;
      this.disposed = false;
    }

    _url(path) {
      return `${String(this.config.apiBaseUrl || '').replace(/\/$/, '')}${path}`;
    }

    async load({ evaluationId }) {
      if (!evaluationId) throw new Error('evaluationId is required in api mode');
      this.onStatus({ state: 'loading' });
      const result = await this.fetchImpl(
        this._url(`/api/evaluations/${encodeURIComponent(evaluationId)}/editor`),
        { credentials: 'same-origin', headers: { Accept: 'application/json' } },
      );
      if (result.status === 401) {
        this.onStatus({ state: 'signed_out' });
        return null;
      }
      if (!result.ok) {
        this.onStatus({ state: 'failed', error: await result.json() });
        return null;
      }
      this.document = await result.json();
      this.conflicted = false;
      this.onStatus({ state: 'saved' });
      return clone(this.document);
    }

    scheduleSave(documentValue) {
      if (this.disposed || this.conflicted) return;
      this.pending = clone(documentValue);
      this.onStatus({ state: 'saving' });
      if (this.timer != null) this.clearTimeoutImpl(this.timer);
      this.timer = this.setTimeoutImpl(async () => {
        this.timer = null;
        await this._sendPending();
      }, 700);
    }

    async _sendPending() {
      if (this.disposed || this.conflicted) return clone(this.document);
      if (this.inflight) return this.inflight;
      if (this.pending == null) return clone(this.document);
      const pendingDocument = this.pending;
      this.pending = null;
      const currentVersion = this.document ? this.document.version : pendingDocument.version;
      const requestBody = {
        version: currentVersion,
        student: pendingDocument.student,
        payload: pendingDocument.payload,
      };
      const csrf = readCookie(this.cookieReader(), 'mkseed_csrf');
      const request = this.fetchImpl(
        this._url(`/api/evaluations/${encodeURIComponent(pendingDocument.evaluation_id)}`),
        {
          method: 'PUT',
          credentials: 'same-origin',
          headers: {
            Accept: 'application/json',
            'Content-Type': 'application/json',
            'X-CSRF-Token': csrf,
          },
          body: JSON.stringify(requestBody),
        },
      ).then(async (result) => {
        if (result.ok) {
          this.document = await result.json();
          this.onStatus({ state: 'saved' });
          return clone(this.document);
        }
        const error = await result.json();
        if (result.status === 409) {
          this.conflicted = true;
          this.pending = null;
          this.onStatus({ state: 'conflict', error });
          return clone(this.document);
        }
        if (result.status === 401) {
          this.pending = null;
          this.onStatus({ state: 'signed_out', error });
          return clone(this.document);
        }
        this.pending = pendingDocument;
        this.onStatus({ state: 'failed', error });
        return clone(this.document);
      });
      this.inflight = request;
      try {
        return await request;
      } finally {
        this.inflight = null;
        if (this.pending != null && !this.conflicted && !this.disposed) {
          await this._sendPending();
        }
      }
    }

    async flush() {
      if (this.timer != null) {
        this.clearTimeoutImpl(this.timer);
        this.timer = null;
      }
      if (this.inflight) await this.inflight;
      if (this.pending != null) await this._sendPending();
      return clone(this.document);
    }

    current() {
      return clone(this.document);
    }

    isConflicted() {
      return this.conflicted;
    }

    hasUnsaved() {
      return this.pending != null || this.inflight != null || this.conflicted;
    }

    dispose() {
      this.disposed = true;
      this.pending = null;
      if (this.timer != null) {
        this.clearTimeoutImpl(this.timer);
        this.timer = null;
      }
    }
  }

  function create(options) {
    if (!options || !options.config) throw new Error('repository config is required');
    if (!options.storage) throw new Error('repository storage is required');
    return options.config.storageMode === 'api'
      ? new ApiRepository(options)
      : new LocalRepository(options);
  }

  return Object.freeze({ create, readCookie });
});
