/**
 * `web_fetch` — Pi has no web tool of any kind, so vibing.nvim brings one.
 *
 * The contract is claude's `WebFetch` on purpose: same two parameters, same http→https upgrade,
 * same "a cross-host redirect is reported, not followed", same short self-cleaning cache. Copying
 * it is not deference — it is what lets a user's existing `WebFetch(domain:...)` rules and their
 * habits carry over unchanged, and it is why `pi_tool_vocabulary` can map this to the canonical
 * `WebFetch` rather than inventing a fifth spelling.
 *
 * **The one deliberate divergence.** Claude Code runs the fetched page through a small fast model
 * with `prompt` and returns that model's answer. Pi's whole purpose here is running *local* models
 * through an arbitrary OpenAI-compatible endpoint, where there is no second cheap model to reach
 * for and a nested call would spend the user's one loaded model. So the page comes back as text
 * with `prompt` restated at the top as the extraction task, and the calling model does the
 * extraction itself. The parameter is kept rather than dropped because models trained on the
 * claude tool send it regardless, and because it is genuinely useful as an instruction.
 */

import { htmlToText, htmlTitle } from './html_to_text.js';

/** Pi's own `DEFAULT_MAX_BYTES` for tool output (`dist/core/tools/truncate.js`). */
const DEFAULT_MAX_CHARS = 50 * 1024;
const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_REDIRECTS = 5;
/** Claude Code's WebFetch cache window, which is the point of copying it: a model re-reads a URL. */
const CACHE_TTL_MS = 15 * 60 * 1000;

const USER_AGENT = 'vibing.nvim-pi-extension/1.0 (+https://github.com/shabaraba/vibing.nvim)';

interface CacheEntry {
  at: number;
  text: string;
}

const cache = new Map<string, CacheEntry>();

function numberFromEnv(name: string, fallback: number): number {
  const raw = Number(process.env[name]);
  return Number.isFinite(raw) && raw > 0 ? raw : fallback;
}

function maxChars(): number {
  return numberFromEnv('VIBING_PI_WEB_FETCH_MAX_CHARS', DEFAULT_MAX_CHARS);
}

/** Dropped on read rather than on a timer, so the extension adds no handle keeping Pi alive. */
function cached(url: string): string | undefined {
  const now = Date.now();
  for (const [key, entry] of cache) {
    if (now - entry.at > CACHE_TTL_MS) cache.delete(key);
  }
  return cache.get(url)?.text;
}

/**
 * Follow same-host redirects; report a cross-host one instead of following it.
 *
 * Silently following would let a shortener or an open redirect turn an approved
 * `WebFetch(domain:docs.example.com)` into a fetch of somewhere else entirely — the approval the
 * user gave named a host, and the host is exactly what changed.
 */
async function fetchFollowingSameHost(
  url: URL,
  signal: AbortSignal | undefined
): Promise<{ response: Response; finalUrl: URL } | { redirectedTo: string }> {
  let current = url;
  const deadline = AbortSignal.timeout(
    numberFromEnv('VIBING_PI_WEB_FETCH_TIMEOUT_MS', DEFAULT_TIMEOUT_MS)
  );
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const response = await fetch(current, {
      redirect: 'manual',
      headers: { 'User-Agent': USER_AGENT, Accept: 'text/html,text/plain,application/json,*/*' },
      signal: signal ? AbortSignal.any([signal, deadline]) : deadline,
    });
    const location =
      response.status >= 300 && response.status < 400 && response.headers.get('location');
    if (!location) return { response, finalUrl: current };

    const next = new URL(location, current);
    if (next.host !== current.host) return { redirectedTo: next.toString() };
    current = next;
  }
  throw new Error(`Too many redirects (more than ${MAX_REDIRECTS}) starting at ${url.toString()}`);
}

/**
 * Loopback, where there is no network hop to protect and so nothing to upgrade.
 *
 * Claude Code upgrades every `http:` URL to `https:`. Doing that here unconditionally would make
 * `web_fetch` unable to read a local docs server or a locally served API reference — which is
 * squarely the situation this backend exists for, since the model is local too. The reason for the
 * upgrade is a plaintext hop across a network, and to `localhost` there is not one.
 */
function isLoopback(host: string): boolean {
  return host === 'localhost' || host === '[::1]' || /^127(\.\d{1,3}){3}$/.test(host);
}

async function fetchAsText(rawUrl: string, signal: AbortSignal | undefined): Promise<string> {
  const url = new URL(rawUrl);
  if (url.protocol === 'http:' && !isLoopback(url.hostname)) url.protocol = 'https:';
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new Error(`Unsupported URL scheme "${url.protocol}" — web_fetch handles http and https.`);
  }

  const outcome = await fetchFollowingSameHost(url, signal);
  if ('redirectedTo' in outcome) {
    return `${url.toString()} redirects to a different host: ${outcome.redirectedTo}\n\nCall web_fetch again with that URL if you want its contents.`;
  }

  const { response, finalUrl } = outcome;
  if (!response.ok) {
    throw new Error(
      `${finalUrl.toString()} returned HTTP ${response.status} ${response.statusText}`
    );
  }

  const body = await response.text();
  const isHtml =
    (response.headers.get('content-type') ?? '').includes('html') ||
    /^\s*<(!doctype|html)/i.test(body);
  const text = isHtml ? htmlToText(body) : body;
  const title = isHtml ? htmlTitle(body) : undefined;

  const header = [`# ${title ?? finalUrl.toString()}`, `Source: ${finalUrl.toString()}`].join('\n');
  const limit = maxChars();
  const truncated =
    text.length > limit
      ? `${text.slice(0, limit)}\n\n[truncated: ${text.length - limit} more characters]`
      : text;
  return `${header}\n\n${truncated}`;
}

export const webFetchTool = {
  name: 'web_fetch',
  label: 'web_fetch',
  description:
    'Fetch a URL and return its contents as text. HTML is converted to readable text; other ' +
    'content types are returned as-is. Use it to read documentation, an issue, a changelog or an ' +
    'API reference. The `prompt` is what you want out of the page — it is restated at the top of ' +
    'the result and you extract the answer yourself; this tool runs no model of its own. http ' +
    'URLs are upgraded to https except on localhost, and a redirect to a different host is ' +
    'reported rather than followed, so call the tool again with the reported URL to read it. ' +
    'Results are cached for 15 minutes.',
  promptSnippet: 'Fetch a URL and read its contents as text',
  parameters: {
    type: 'object',
    properties: {
      url: { type: 'string', description: 'The absolute URL to fetch' },
      prompt: { type: 'string', description: 'What to extract from the page' },
    },
    required: ['url', 'prompt'],
  },
  async execute(
    _toolCallId: string,
    params: { url: string; prompt: string },
    signal?: AbortSignal
  ): Promise<{
    content: { type: 'text'; text: string }[];
    details: { url: string; cached: boolean };
  }> {
    const hit = cached(params.url);
    const text = hit ?? (await fetchAsText(params.url, signal));
    if (!hit) cache.set(params.url, { at: Date.now(), text });

    return {
      content: [
        { type: 'text', text: `Extract from this page: ${params.prompt}\n\n---\n\n${text}` },
      ],
      details: { url: params.url, cached: hit !== undefined },
    };
  },
};

/** Test seam: the cache is process-wide and a spec that asserts a second fetch needs it empty. */
export function _clearCache(): void {
  cache.clear();
}
