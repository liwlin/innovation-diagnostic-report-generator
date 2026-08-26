'use strict';

// Executed through the Codex in-app Browser workflow documented in
// docs/verification/dual-mode-frontend.md. This file is the stable flow
// contract; it intentionally does not introduce a second Playwright runtime.
module.exports = Object.freeze({
  nas: [
    'wrong login shows 账号或密码错误',
    'admin login renders six shared records and admin navigation',
    'partial Chinese name filter narrows to one record',
    'API editor loads all fields and persists an observation after reload',
    'server generation reaches completed history with four artifact links',
    'second independent teacher save makes stale browser save show HTTP 409 conflict copy',
    'record moves to recycle bin and restores through code-native confirmation',
    'teacher login sees all records but no account or audit navigation',
    'admin account, emergency import, and audit surfaces render without console errors',
  ],
  pages: [
    'root redirects to the existing editor in local mode',
    'local student name survives reload at a separate origin',
    'local server access log contains no /api/ request',
    'emergency export control remains visible',
  ],
  viewports: ['default 1366x768', 'mobile 390x844'],
});

