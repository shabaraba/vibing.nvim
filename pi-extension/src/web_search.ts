/**
 * `web_search` — the same tool claude and codex expose, over a backend Pi can actually reach.
 *
 * Claude Code's `WebSearch` and codex's `web_search` are both **server-side**: the search happens
 * inside Anthropic's and OpenAI's own inference APIs, and the CLI only declares that it wants it.
 * Pi exists here to run *local* models through an arbitrary OpenAI-compatible endpoint, which has
 * no such facility, so the search has to be performed by this extension against a real search API.
 *
 * That means it needs one, and there is no keyless option worth shipping: DuckDuckGo's HTML
 * endpoints answer `202` with an anomaly page to a non-browser client (measured 2026-09-24) and
 * Mojeek answers `403`, so a scraper would be a feature that is already broken. The three
 * providers below all have a free tier or are self-hosted. With none of them configured the tool
 * is **not registered at all** rather than registered and always failing — an absent tool is a
 * fact the model can plan around, while one that errors on every call gets retried.
 *
 * The parameter contract is claude's `WebSearch`, including `allowed_domains` / `blocked_domains`.
 * Those are applied here, to the results, rather than passed through: only one of the three
 * providers takes them, and a rule the user wrote has to mean the same thing whichever backend is
 * configured.
 */

/** Which provider to use. `auto` takes whichever credential is present, in this order. */
const MODE_VAR = 'VIBING_PI_WEB_SEARCH';
const DEFAULT_RESULTS = 10;
const TIMEOUT_MS = 20_000;

export type ProviderId = 'brave' | 'tavily' | 'searxng';

interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

const CREDENTIAL: Record<ProviderId, string> = {
  brave: 'BRAVE_SEARCH_API_KEY',
  tavily: 'TAVILY_API_KEY',
  searxng: 'SEARXNG_URL',
};

/** `auto`'s order. Brave first because it is a plain web index; tavily is summarisation-oriented. */
const AUTO_ORDER: ProviderId[] = ['brave', 'tavily', 'searxng'];

function credentialFor(provider: ProviderId): string | undefined {
  const value = process.env[CREDENTIAL[provider]];
  return value && value !== '' ? value : undefined;
}

/**
 * @returns the provider to register the tool for, or nothing when it must not be registered.
 *
 * One decision, not a chain of them: `off`, an empty value and a typo all reduce to "no candidate"
 * and need no branch of their own. Written as separate early returns, the `off` one was dead — the
 * named lookup already answered nothing for it — and a mutation that deleted it changed no
 * behaviour at all, which is exactly what a guard that looks load-bearing and is not looks like.
 *
 * A named provider whose credential is missing also resolves to nothing: registering it would mean
 * every call fails with a message the model cannot act on.
 */
export function resolveProvider(): ProviderId | undefined {
  const mode = process.env[MODE_VAR] ?? 'auto';
  const candidates = mode === 'auto' ? AUTO_ORDER : AUTO_ORDER.filter((id) => id === mode);
  return candidates.find((id) => credentialFor(id) !== undefined);
}

async function getJson(url: string, init: RequestInit, signal?: AbortSignal): Promise<any> {
  const timeout = AbortSignal.timeout(TIMEOUT_MS);
  const response = await fetch(url, {
    ...init,
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
  });
  if (!response.ok) {
    throw new Error(`Search provider returned HTTP ${response.status} ${response.statusText}`);
  }
  return response.json();
}

const PROVIDERS: Record<
  ProviderId,
  (query: string, key: string, signal?: AbortSignal) => Promise<SearchResult[]>
> = {
  async brave(query, key, signal) {
    const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${DEFAULT_RESULTS}`;
    const body = await getJson(
      url,
      { headers: { Accept: 'application/json', 'X-Subscription-Token': key } },
      signal
    );
    return (body?.web?.results ?? []).map((r: any) => ({
      title: String(r.title ?? ''),
      url: String(r.url ?? ''),
      snippet: String(r.description ?? ''),
    }));
  },

  async tavily(query, key, signal) {
    const body = await getJson(
      'https://api.tavily.com/search',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
        body: JSON.stringify({ query, max_results: DEFAULT_RESULTS }),
      },
      signal
    );
    return (body?.results ?? []).map((r: any) => ({
      title: String(r.title ?? ''),
      url: String(r.url ?? ''),
      snippet: String(r.content ?? ''),
    }));
  },

  // A self-hosted instance. `format=json` is disabled by default in searxng's own settings, so a
  // failure here is usually that switch rather than the URL.
  async searxng(query, base, signal) {
    const url = new URL('/search', base.endsWith('/') ? base : `${base}/`);
    url.searchParams.set('q', query);
    url.searchParams.set('format', 'json');
    const body = await getJson(url.toString(), { headers: { Accept: 'application/json' } }, signal);
    return (body?.results ?? []).slice(0, DEFAULT_RESULTS).map((r: any) => ({
      title: String(r.title ?? ''),
      url: String(r.url ?? ''),
      snippet: String(r.content ?? ''),
    }));
  },
};

function hostOf(url: string): string {
  try {
    return new URL(url).host.replace(/^www\./, '');
  } catch {
    return '';
  }
}

function matchesDomain(host: string, domain: string): boolean {
  const wanted = domain.replace(/^www\./, '').toLowerCase();
  return host === wanted || host.endsWith(`.${wanted}`);
}

function applyDomainFilters(
  results: SearchResult[],
  allowed?: string[],
  blocked?: string[]
): SearchResult[] {
  return results.filter((result) => {
    const host = hostOf(result.url);
    if (allowed?.length && !allowed.some((d) => matchesDomain(host, d))) return false;
    if (blocked?.length && blocked.some((d) => matchesDomain(host, d))) return false;
    return true;
  });
}

export function createWebSearchTool(provider: ProviderId) {
  return {
    name: 'web_search',
    label: 'web_search',
    description:
      `Search the web (via ${provider}) and return ranked results with titles, URLs and snippets. ` +
      'Use it to find current information, then call web_fetch on a result to read it. Restrict ' +
      'the results with allowed_domains or blocked_domains when you already know where the answer ' +
      'should come from.',
    promptSnippet: 'Search the web for current information',
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'The search query', minLength: 2 },
        allowed_domains: {
          type: 'array',
          items: { type: 'string' },
          description: 'Only return results from these domains',
        },
        blocked_domains: {
          type: 'array',
          items: { type: 'string' },
          description: 'Never return results from these domains',
        },
      },
      required: ['query'],
    },
    async execute(
      _toolCallId: string,
      params: { query: string; allowed_domains?: string[]; blocked_domains?: string[] },
      signal?: AbortSignal
    ): Promise<{
      content: { type: 'text'; text: string }[];
      details: { provider: ProviderId; count: number };
    }> {
      const key = credentialFor(provider);
      if (!key) {
        throw new Error(`${CREDENTIAL[provider]} is no longer set, so web_search cannot run.`);
      }

      const found = await PROVIDERS[provider](params.query, key, signal);
      const results = applyDomainFilters(found, params.allowed_domains, params.blocked_domains);

      const text = results.length
        ? results.map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}\n   ${r.snippet}`).join('\n\n')
        : `No results for "${params.query}".`;

      return {
        content: [{ type: 'text', text }],
        details: { provider, count: results.length },
      };
    },
  };
}
