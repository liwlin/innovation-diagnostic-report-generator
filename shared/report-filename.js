(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedReportFilename = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const DEFAULT_PATTERN = '{name}_{date}_科创体验报告';

  function currentCompactDate() {
    const value = new Date();
    const pad = (part) => String(part).padStart(2, '0');
    return `${value.getFullYear()}${pad(value.getMonth() + 1)}${pad(value.getDate())}`;
  }

  function build(input) {
    const pattern = String(input.pattern || DEFAULT_PATTERN);
    const dateRaw = String(input.date || '').trim() || input.today_compact || currentCompactDate();
    const name = String(input.name || '学员').trim();
    let output = pattern.split('{name}').join(name).split('{date}').join(dateRaw);
    if (input.variant === 'with') output += '_含内联';
    else if (input.variant === 'without') output += '_无内联';
    output = output.replace(/[\\/:*?"<>|]/g, '').trim();
    return output || '科创体验报告';
  }

  return Object.freeze({ build });
});
