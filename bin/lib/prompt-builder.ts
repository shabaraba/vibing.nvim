import { readFileSync } from 'fs';

import type { AgentConfig } from '../types.js';
import { toError } from './utils.js';

/**
 * Escape special XML/HTML characters to prevent malformed tags
 * @param str - String to escape
 * @returns Escaped string safe for XML attributes
 */
function escapeXml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/**
 * Format a context file for inclusion in the prompt
 * @param filePath - Path to the context file
 * @returns Formatted context string or null if file cannot be read
 */
function formatContextFile(filePath: string): string | null {
  try {
    const content = readFileSync(filePath, 'utf-8');
    const escapedPath = escapeXml(filePath);
    return `<context file="${escapedPath}">\n${content}\n</context>`;
  } catch (error) {
    const err = toError(error);
    console.warn(`Warning: Failed to read context file "${filePath}": ${err.message}`);
    return null;
  }
}

/**
 * Build the final prompt with context files
 * @param config - Agent configuration including prompt and context files
 * @returns Final prompt string with context files appended
 */
export function buildPrompt(config: AgentConfig): string {
  const { prompt, contextFiles, sessionId } = config;

  if (contextFiles.length === 0 || sessionId) {
    return prompt;
  }

  const formattedContexts = contextFiles
    .map(formatContextFile)
    .filter((ctx): ctx is string => ctx !== null);

  if (formattedContexts.length === 0) {
    return prompt;
  }

  return (
    prompt +
    '\n\nThe following files are provided as context for reference:\n\n' +
    formattedContexts.join('\n\n')
  );
}
