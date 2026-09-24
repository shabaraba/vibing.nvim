// `web_fetch` and `web_search` (`pi-extension/`), the two tools Pi does not have.
//
// Pi's built-in set is `bash, read, write, edit, ls, grep, find` and nothing else, so a Pi chat
// could not read a linked issue or look anything up until vibing.nvim registered these. They are
// exercised here against local HTTP servers: no network, no API key, no `pi` binary.
//
// The `web_fetch` cases all use loopback URLs deliberately -- that is also what pins the one
// divergence from claude's WebFetch, which upgrades every http URL to https and so could not read
// a local docs server at all.
import assert from 'node:assert/strict';
import test, { before, after, beforeEach } from 'node:test';
import { createServer } from 'node:http';
import { URL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIST = join(REPO_ROOT, 'pi-extension', 'dist');

const PAGE = `<!doctype html><html><head><title>Example &amp; Co</title>
<style>body{color:red}</style><script>var leak = "SHOULD NOT APPEAR";</script></head>
<body><h1>Heading</h1><p>First&nbsp;paragraph.</p><p>Second paragraph &mdash; done.</p></body></html>`;

let server;
let origin;
/** Where the server sends a request for /redirect-away: deliberately a different host. */
const redirectTarget = 'https://elsewhere.example/page';
let webFetch;
let webSearch;

function buildBundle() {
  execFileSync(join(REPO_ROOT, 'node_modules', '.bin', 'tsc'), ['-p', 'pi-extension'], {
    cwd: REPO_ROOT,
    stdio: 'pipe',
  });
}

before(async () => {
  buildBundle();
  webFetch = await import(join(DIST, 'web_fetch.js'));
  webSearch = await import(join(DIST, 'web_search.js'));

  server = createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (url.pathname === '/page') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(PAGE);
    } else if (url.pathname === '/plain') {
      res.writeHead(200, { 'content-type': 'text/plain' }).end('just text');
    } else if (url.pathname === '/long') {
      res.writeHead(200, { 'content-type': 'text/plain' }).end('x'.repeat(5000));
    } else if (url.pathname === '/gone') {
      res.writeHead(404, { 'content-type': 'text/plain' }).end('nope');
    } else if (url.pathname === '/redirect-same') {
      res.writeHead(302, { location: '/page' }).end();
    } else if (url.pathname === '/redirect-away') {
      res.writeHead(302, { location: redirectTarget }).end();
    } else if (url.pathname === '/search') {
      // A searxng-shaped answer. `format=json` is off by default on a real instance, which is why
      // this is the provider a test can stand in for without a credential of any kind.
      res.writeHead(200, { 'content-type': 'application/json' }).end(
        JSON.stringify({
          results: [
            { title: 'Neovim', url: 'https://neovim.io/doc', content: 'docs' },
            { title: 'Spam', url: 'https://spam.example/x', content: 'spam' },
            { title: 'Sub', url: 'https://www.docs.neovim.io/api', content: 'api' },
          ],
        })
      );
    } else {
      res.writeHead(500).end();
    }
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});

after(() => server?.close());

beforeEach(() => webFetch._clearCache());

function fetchPage(path, prompt = 'what is this') {
  return webFetch.webFetchTool.execute('tc-1', { url: `${origin}${path}`, prompt });
}

test('web_fetch returns the page as readable text', async () => {
  const result = await fetchPage('/page');
  const text = result.content[0].text;
  assert.match(text, /Heading/);
  assert.match(text, /First paragraph\./);
  assert.match(text, /Second paragraph — done\./);
});

test('web_fetch drops script and style bodies before stripping tags', async () => {
  // The one part of a dependency-free HTML conversion that is not cosmetic: strip tags first and a
  // page of minified JavaScript arrives as the article.
  const text = (await fetchPage('/page')).content[0].text;
  assert.doesNotMatch(text, /SHOULD NOT APPEAR/);
  assert.doesNotMatch(text, /color:red/);
});

test('web_fetch keeps the title, so a truncated page still says what it was', async () => {
  const text = (await fetchPage('/page')).content[0].text;
  assert.match(text, /# Example & Co/);
});

test('web_fetch puts the title in the header and not also in the body', async () => {
  // Measured in a real pi run before it was fixed: the body began "Stub Page Hello from the page",
  // so the page's own first sentence was preceded by its title read as prose.
  const body = (await fetchPage('/page')).content[0].text.split(/^Source: .*$/m)[1];
  assert.doesNotMatch(body, /Example & Co/);
  assert.match(body, /Heading/);
});

test('web_fetch restates the prompt as the extraction task', async () => {
  // The deliberate divergence from claude's WebFetch, which answers the prompt with a second
  // model. There is no cheap second model behind a local endpoint, so the caller extracts.
  const text = (await fetchPage('/page', 'find the heading')).content[0].text;
  assert.match(text, /^Extract from this page: find the heading/);
});

test('web_fetch does not upgrade a loopback URL to https', async () => {
  // Asserted by the fact that every case above reached the server at all; stated once explicitly
  // because the upgrade is claude's behaviour and reintroducing it breaks local docs silently.
  assert.equal((await fetchPage('/plain')).content[0].text.endsWith('just text'), true);
});

test('web_fetch follows a same-host redirect', async () => {
  const text = (await fetchPage('/redirect-same')).content[0].text;
  assert.match(text, /Heading/);
});

test('web_fetch reports a cross-host redirect instead of following it', async () => {
  // A shortener or an open redirect must not turn an approved WebFetch(domain:...) into a fetch of
  // somewhere else: the approval named a host, and the host is what changed.
  const text = (await fetchPage('/redirect-away')).content[0].text;
  assert.match(text, /redirects to a different host/);
  assert.match(text, /elsewhere\.example/);
});

test('web_fetch truncates a long page and says it did', async () => {
  process.env.VIBING_PI_WEB_FETCH_MAX_CHARS = '100';
  try {
    const text = (await fetchPage('/long')).content[0].text;
    assert.match(text, /\[truncated: \d+ more characters\]/);
  } finally {
    delete process.env.VIBING_PI_WEB_FETCH_MAX_CHARS;
  }
});

test('web_fetch surfaces an HTTP error as a failed tool result', async () => {
  // Throwing is how Pi produces a failed result; returning the error as content would have the
  // model treat a 404 body as the page.
  await assert.rejects(() => fetchPage('/gone'), /HTTP 404/);
});

test('web_fetch serves a repeated URL from its cache', async () => {
  assert.equal((await fetchPage('/page')).details.cached, false);
  assert.equal((await fetchPage('/page')).details.cached, true);
});

test('web_search is not registered when no provider is configured', () => {
  // An absent tool is a fact the model can plan around; one that errors on every call is retried.
  const original = { ...process.env };
  delete process.env.BRAVE_SEARCH_API_KEY;
  delete process.env.TAVILY_API_KEY;
  delete process.env.SEARXNG_URL;
  process.env.VIBING_PI_WEB_SEARCH = 'auto';
  try {
    assert.equal(webSearch.resolveProvider(), undefined);
  } finally {
    Object.assign(process.env, original);
  }
});

test('web_search picks up whichever credential is present', () => {
  process.env.VIBING_PI_WEB_SEARCH = 'auto';
  process.env.SEARXNG_URL = origin;
  try {
    assert.equal(webSearch.resolveProvider(), 'searxng');
  } finally {
    delete process.env.SEARXNG_URL;
  }
});

test('web_search stays unregistered when the named provider has no credential', () => {
  // Registering it would mean every call fails with a message the model cannot act on.
  process.env.VIBING_PI_WEB_SEARCH = 'brave';
  const original = process.env.BRAVE_SEARCH_API_KEY;
  delete process.env.BRAVE_SEARCH_API_KEY;
  try {
    assert.equal(webSearch.resolveProvider(), undefined);
  } finally {
    if (original !== undefined) process.env.BRAVE_SEARCH_API_KEY = original;
    process.env.VIBING_PI_WEB_SEARCH = 'auto';
  }
});

test('web_search honours off even with a credential set', () => {
  process.env.VIBING_PI_WEB_SEARCH = 'off';
  process.env.SEARXNG_URL = origin;
  try {
    assert.equal(webSearch.resolveProvider(), undefined);
  } finally {
    delete process.env.SEARXNG_URL;
    process.env.VIBING_PI_WEB_SEARCH = 'auto';
  }
});

test('web_search returns ranked results with title, URL and snippet', async () => {
  process.env.SEARXNG_URL = origin;
  try {
    const tool = webSearch.createWebSearchTool('searxng');
    const result = await tool.execute('tc-1', { query: 'neovim' });
    assert.equal(result.details.count, 3);
    assert.match(result.content[0].text, /1\. Neovim\n {3}https:\/\/neovim\.io\/doc\n {3}docs/);
  } finally {
    delete process.env.SEARXNG_URL;
  }
});

test('web_search applies allowed_domains to subdomains and ignores a www prefix', async () => {
  // Applied here rather than passed to the provider: only one of the three takes these, and a rule
  // the user wrote has to mean the same thing whichever backend is configured.
  process.env.SEARXNG_URL = origin;
  try {
    const tool = webSearch.createWebSearchTool('searxng');
    const result = await tool.execute('tc-1', { query: 'neovim', allowed_domains: ['neovim.io'] });
    assert.equal(result.details.count, 2);
    assert.doesNotMatch(result.content[0].text, /spam\.example/);
  } finally {
    delete process.env.SEARXNG_URL;
  }
});

test('web_search applies blocked_domains', async () => {
  process.env.SEARXNG_URL = origin;
  try {
    const tool = webSearch.createWebSearchTool('searxng');
    const result = await tool.execute('tc-1', {
      query: 'neovim',
      blocked_domains: ['spam.example'],
    });
    assert.equal(result.details.count, 2);
    assert.doesNotMatch(result.content[0].text, /spam\.example/);
  } finally {
    delete process.env.SEARXNG_URL;
  }
});

test('web_search says so rather than returning nothing when everything is filtered out', async () => {
  process.env.SEARXNG_URL = origin;
  try {
    const tool = webSearch.createWebSearchTool('searxng');
    const result = await tool.execute('tc-1', {
      query: 'neovim',
      allowed_domains: ['nowhere.test'],
    });
    assert.match(result.content[0].text, /No results for "neovim"/);
  } finally {
    delete process.env.SEARXNG_URL;
  }
});

test('the extension ships the gate and the tools together', async () => {
  // Pi installs the `tool_call` hook once per Agent, so it covers extension-registered tools as
  // well as built-ins. That only protects `web_fetch`/`web_search` while both live in the same
  // extension: split into two, and loading the tools without the gate becomes possible.
  process.env.SEARXNG_URL = origin;
  try {
    const registered = { handlers: {}, tools: [] };
    const factory = (await import(join(DIST, 'index.js'))).default;
    factory({
      on: (event, fn) => (registered.handlers[event] = fn),
      registerTool: (tool) => registered.tools.push(tool.name),
    });

    assert.equal(typeof registered.handlers.tool_call, 'function');
    assert.deepEqual(registered.tools, ['web_fetch', 'web_search']);
  } finally {
    delete process.env.SEARXNG_URL;
  }
});
