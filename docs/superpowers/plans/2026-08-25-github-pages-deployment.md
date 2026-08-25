# GitHub Pages Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the existing static report-generator HTML as a public GitHub Pages site under the authenticated `liwlin` account.

**Architecture:** Keep the downloaded `.dc.html` source intact and add a small root `index.html` that redirects to it, so GitHub Pages has a conventional entry route without duplicating the large document. Track only runtime files plus deployment verification assets, excluding local OMX state, uploads, and preview metadata.

**Tech Stack:** Static HTML/JavaScript, PowerShell validation, Git, GitHub CLI, GitHub Pages.

**Spec:** User request in this task: deploy the current HTML webpage to their GitHub account.

## Global Constraints

- Use the authenticated GitHub account `liwlin`.
- Create the public repository `innovation-diagnostic-report-generator`.
- Do not publish `.omx/`, `uploads/`, or `.thumbnail`.
- Preserve the existing report-generator behavior and relative asset paths.
- Verify both local rendering and the final public GitHub Pages URL.

---

### Task 1: Static Pages entry and publish boundary

**Files:**
- Create: `.gitignore`
- Create: `tests/verify-static-site.ps1`
- Create: `index.html`
- Modify: `科创方向诊断报告生成器.dc.html`

**Interfaces:**
- Consumes: the existing `.dc.html`, `support.js`, `doc-page.js`, and `assets/` files.
- Produces: a root `/index.html` entry route and a repeatable static-site verifier.

- [x] **Step 1: Write the failing static-site test**

  The test asserts that `index.html` exists, links to the source page, all required runtime files exist, and excluded local-only paths are covered by `.gitignore`.

- [x] **Step 2: Run the test to verify it fails**

  Run: `pwsh -NoProfile -File tests/verify-static-site.ps1`

  Expected: FAIL because `index.html` and `.gitignore` do not exist yet.

- [x] **Step 3: Add the minimal entry and ignore rules**

  Create a standards-based redirect page and ignore only the three confirmed local-only paths. Add a browser title to the source page.

- [x] **Step 4: Run the test and local browser smoke test**

  Run: `pwsh -NoProfile -File tests/verify-static-site.ps1`

  Expected: PASS. Then load the root URL, confirm redirect, meaningful DOM, logo assets, settings interaction, and zero relevant console errors.

### Task 2: GitHub repository and Pages publication

**Files:**
- Track: `.gitignore`, `index.html`, source HTML/JS/assets, test, and this plan.

**Interfaces:**
- Consumes: the verified local static site.
- Produces: `https://liwlin.github.io/innovation-diagnostic-report-generator/`.

- [ ] **Step 1: Initialize Git and inspect the exact publish set**

  Run `git init -b main`, stage files, and verify `.omx/`, `uploads/`, and `.thumbnail` are absent from the index.

- [ ] **Step 2: Commit with Lore trailers**

  Commit the tested site with `Tested:` and `Not-tested:` trailers.

- [ ] **Step 3: Create and push the public GitHub repository**

  Use `gh repo create liwlin/innovation-diagnostic-report-generator --public --source . --remote origin --push`.

- [ ] **Step 4: Enable GitHub Pages from `main` root**

  Configure the repository Pages source as branch `main`, path `/` through the GitHub API.

- [ ] **Step 5: Verify deployment end to end**

  Confirm the Pages API reports `built`, fetch the public URL with an HTTP 200 response, and repeat the browser identity/DOM/console/interaction checks against production.

