# Browser and Pages Summary

Published Pages URL: <https://liwlin.github.io/innovation-diagnostic-report-generator/>

Runtime config fetched from Pages:

```js
window.__MKSEED_RUNTIME__=Object.freeze({"commitSha":"ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0","storageMode":"local","appVersion":"v0.1.0","apiBaseUrl":""});
```

Pages browser evidence:

- In-app Browser title: `科创体验报告 · 生成器`.
- Final editor URL and visible DOM were meaningful.
- AI settings opened then closed.
- Desktop `1366x768` and mobile `390x844` controls remained accessible.
- Console warn/error output was empty.
- No NAS API address was present in runtime config.
- Screenshot capture failed with `Unable to capture screenshot`; screenshot check is unavailable, not passed.

Fresh browser API E2E:

- Endpoint: isolated local `127.0.0.1:18903`.
- Storage: temporary SQLite database and temporary report root.
- Cleanup: port released after run.
- Admin login showed all records.
- Teacher login showed all 6 shared records and no admin navigation.
- Chinese search `张子涵` narrowed to 1 record.
- Editor autosave changed observation, showed `已保存`, and persisted after reload.
- Independent teacher-B HTTP session updated version `3->4`; stale browser edit showed `记录已被其他老师修改，请重新加载`.
- Generation completed with without/with PDF/PNG links.
- Report files used exact legacy names; sizes were 73,197 / 224,736 / 81,127 / 288,101 bytes; partial count 0.
- Soft trash via isolated API was visible in Browser recycle with restore/report/permanent-delete controls.
- Browser restore removed the record from recycle.
- Admin accounts and audit were visible; audit included generation/update/trash/restore.
- Console warn/error output was empty.
- Server stderr was clean.

Boundary: this is local browser/API proof only. It is not PostgreSQL or NAS hardware proof.