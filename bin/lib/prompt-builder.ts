import { readFileSync } from 'fs';

import type { AgentConfig } from '../types.js';
import { toError } from './utils.js';

function formatContextFile(filePath: string): string | null {
  try {
    const content = readFileSync(filePath, 'utf-8');
    return `<context file="${filePath}">\n${content}\n</context>`;
  } catch (error) {
    const err = toError(error);
    console.warn(`Warning: Failed to read context file "${filePath}": ${err.message}`);
    return null;
  }
}

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
