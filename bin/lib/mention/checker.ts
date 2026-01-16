/**
 * Mention checker for canUseTool interruption
 * Checks for unprocessed mentions and caches results to reduce RPC overhead
 */

import { callNeovimRpc } from '../rpc/client.js';
import type { MentionCheckResult, MentionCheckerConfig, MentionQueryResult } from './types.js';

const DEFAULT_CACHE_TTL_MS = 1000; // 1 second cache

interface CacheEntry {
  result: MentionCheckResult;
  timestamp: number;
  squadName: string;
}

let cache: CacheEntry | null = null;

/**
 * Check for unprocessed mentions with caching
 * Returns cached result if within TTL to reduce RPC calls
 */
export async function checkForUnprocessedMentions(
  config: MentionCheckerConfig
): Promise<MentionCheckResult> {
  const { rpcPort, squadName, cacheTtlMs = DEFAULT_CACHE_TTL_MS } = config;

  // No squad name means no mention checking possible
  if (!squadName) {
    return { shouldInterrupt: false, count: 0, squadName: '', mentions: [] };
  }

  // Check cache (must match squad name)
  const now = Date.now();
  if (cache && cache.squadName === squadName && now - cache.timestamp < cacheTtlMs) {
    return cache.result;
  }

  try {
    // Single RPC call to get mention info including details
    const queryResult = (await callNeovimRpc(
      'get_mention_info',
      { squad_name: squadName },
      { port: rpcPort, timeout: 1000 }
    )) as MentionQueryResult;

    const result: MentionCheckResult = {
      shouldInterrupt: queryResult.has_mentions,
      count: queryResult.count,
      squadName: queryResult.squad_name || squadName,
      mentions: queryResult.mentions || [],
    };

    cache = { result, timestamp: now, squadName };
    return result;
  } catch (error) {
    // On any error, don't interrupt - let work continue
    process.stderr.write(`[WARN] Mention check failed: ${error}\n`);
    return { shouldInterrupt: false, count: 0, squadName, mentions: [] };
  }
}

/**
 * Clear the mention cache
 * Useful after processing mentions to force fresh check
 */
export function clearMentionCache(): void {
  cache = null;
}

/**
 * Format mention summary for display in canUseTool deny message
 * Includes full mention content to provide context
 */
export function formatMentionSummary(result: MentionCheckResult): string {
  if (!result.shouldInterrupt || result.mentions.length === 0) {
    return '';
  }

  const lines = [`⚠️ You have ${result.count} unprocessed mention(s) from other Squad(s).`, ''];

  // Show full content of first mention (most recent/important)
  const firstMention = result.mentions[0];
  lines.push(`📩 Mention from @${firstMention.from_squad_name} (${firstMention.created_at}):`);
  lines.push('');
  lines.push(firstMention.content);
  lines.push('');

  // Show summary of remaining mentions if any
  if (result.mentions.length > 1) {
    lines.push(`📋 You also have ${result.mentions.length - 1} more mention(s):`);
    const remainingMentions = result.mentions.slice(1, 4); // Show up to 3 more
    for (const mention of remainingMentions) {
      lines.push(`  - ${mention.created_at} from @${mention.from_squad_name}`);
    }
    if (result.mentions.length > 4) {
      lines.push(`  ... and ${result.mentions.length - 4} more`);
    }
    lines.push('');
    lines.push('Use /check-mentions to view all mentions.');
  }

  lines.push('');
  lines.push('Please respond to the mention(s) before continuing your current task.');

  return lines.join('\n');
}
