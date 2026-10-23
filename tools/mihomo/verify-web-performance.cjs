const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_MODULE || 'typescript');
const { chromium } = require('playwright');
const mod = { exports: {} };
const source = fs.readFileSync('entry/src/main/ets/component/WebPerformanceScripts.ets', 'utf8');
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText,
  { module: mod, exports: mod.exports });
const script = mod.exports.MEASURED_RENDER_JS;

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 424, height: 900 }, isMobile: true, hasTouch: true });
    const paragraphs = '<p>Long conversation: selectable text, links and code remain available.</p>'.repeat(20);
    const messages = Array.from({ length: 160 }, (_, i) => i % 2 ?
      '<section data-chatgpt-search-unit-key="m' + i + '">' + paragraphs + '<button>Action</button></section>' :
      '<article><div data-message-id="m' + i + '">' + paragraphs + '<button>Action</button></div></article>').join('');
    const rows = Array.from({ length: 1000 }, (_, i) =>
      '<div class="sidebar-item" data-sidebar-cycle-item="' + i + '"><a href="#row' + i + '">Conversation ' + i + '</a><button>Menu</button></div>').join('');
    await page.setContent('<meta name="viewport" content="width=device-width,initial-scale=1"><style>*{box-sizing:border-box}body{margin:0}main,#history{height:440px;overflow:auto}' +
      'article,section{display:flex;flex-direction:column;padding:12px;border-bottom:1px solid #ddd}' +
      'p{margin:8px 0}.sidebar-item{height:36px;display:flex;gap:8px;align-items:center;padding:4px 12px}</style>' +
      '<main>' + messages + '</main><nav id="history">' + rows + '</nav>');
    const heights = () => page.evaluate(() => ['main', '#history'].map(s => document.querySelector(s).scrollHeight));
    const benchmark = () => page.evaluate(async () => {
      const main = document.querySelector('main'), history = document.querySelector('#history');
      main.scrollTop = 0; history.scrollTop = 0;
      const frames = [];
      let last = performance.now();
      for (let i = 0; i < 90; i++) {
        await new Promise(requestAnimationFrame);
        const now = performance.now(); frames.push(now - last); last = now;
        main.scrollTop += 130; history.scrollTop += 44;
      }
      frames.shift(); frames.sort((a, b) => a - b);
      return { median: +frames[Math.floor(frames.length / 2)].toFixed(1), p95: +frames[Math.floor(frames.length * .95)].toFixed(1) };
    });
    const beforeHeight = await heights();
    const layoutBenchmark = () => page.evaluate(() => {
      const start = performance.now();
      for (let i = 0; i < 30; i++) {
        document.body.style.width = (i % 2 ? 424 : 423) + 'px';
        void document.body.offsetHeight;
      }
      return +(performance.now() - start).toFixed(1);
    });
    const layoutBefore = await layoutBenchmark();
    const before = await benchmark();
    await page.evaluate(script);
    await page.waitForFunction(() => document.querySelectorAll('[data-ohos-render-skip=ready]').length === 1160);
    assert.deepEqual(await heights(), beforeHeight, 'measuring and skipping offscreen content must preserve scroll extents');
    assert.equal(await page.locator('[data-message-id][data-ohos-render-skip]').count(), 0, 'nested message wrappers must not be contained twice');
    const after = await benchmark();
    const layoutAfter = await layoutBenchmark();
    assert.deepEqual(await heights(), beforeHeight, 'scrolling must not change measured extents');
    await page.evaluate(script);
    assert.equal(await page.locator('#ohos-measured-render').count(), 1, 'reinjection must be idempotent');
    await page.evaluate(() => {
      const row = document.querySelector('.sidebar-item');
      window.detachedTestRow = row;
      row.remove();
    });
    await page.waitForFunction(() => !window.detachedTestRow.hasAttribute('data-ohos-render-skip'));
    await page.evaluate(() => document.querySelector('#history').prepend(window.detachedTestRow));
    await page.waitForFunction(() => window.detachedTestRow.getAttribute('data-ohos-render-skip') === 'ready');
    await page.evaluate(() => {
      document.querySelector('main').insertAdjacentHTML('beforeend', '<article><div data-message-id="new"><p>New reply</p></div></article>');
    });
    await page.waitForFunction(() => document.querySelector('main article:last-child').getAttribute('data-ohos-render-skip') === 'ready');
    const oldSize = await page.locator('main article:last-child').evaluate(e => e.style.getPropertyValue('--ohos-block-size'));
    await page.locator('main article:last-child').scrollIntoViewIfNeeded();
    await page.evaluate(() => document.querySelector('main article:last-child p').textContent = 'Streaming reply '.repeat(200));
    await page.waitForFunction(old => document.querySelector('main article:last-child').style.getPropertyValue('--ohos-block-size') !== old, oldSize);
    await page.evaluate(() => { document.querySelector('main article:last-child').innerHTML += '<button id="action">Action</button>'; });
    await page.locator('#action').evaluate(e => e.addEventListener('click', () => window.actionWorked = true));
    await page.locator('#action').tap();
    assert.equal(await page.evaluate(() => window.actionWorked), true, 'render skipping must preserve clicks');
    console.log(JSON.stringify({ fixture: { messages: 160, sidebarRows: 1000 }, before, after, layoutMs: { before: layoutBefore, after: layoutAfter } }));
    console.log('PASS: exact scroll extents, no nested containment, dynamic/streaming replies, detach/reinsert cleanup, manual clicks, idempotency');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
