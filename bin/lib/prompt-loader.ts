import { existsSync, readFileSync } from 'fs';
import path from 'path';

import type { TemplateVars } from './template-engine.js';
import { renderTemplate } from './template-engine.js';
import { toError } from './utils.js';

const LANGUAGE_NAMES: Record<string, string> = {
  ja: 'Japanese',
  en: 'English',
  zh: 'Chinese',
  ko: 'Korean',
  fr: 'French',
  de: 'German',
  es: 'Spanish',
  it: 'Italian',
  pt: 'Portuguese',
  ru: 'Russian',
  ar: 'Arabic',
  hi: 'Hindi',
  nl: 'Dutch',
  sv: 'Swedish',
  no: 'Norwegian',
  da: 'Danish',
  fi: 'Finnish',
  pl: 'Polish',
  tr: 'Turkish',
  vi: 'Vietnamese',
  th: 'Thai',
};

export interface SystemPromptConfig {
  promptsDir: string;
  projectPromptPath: string;
  sessionId: string | null;
  language: string | null;
  rpcPort: number | null;
  cwd: string;
  prioritizeVibingLsp: boolean;
}

function readRequiredPromptFile(filePath: string): string {
  try {
    return readFileSync(filePath, 'utf-8');
  } catch {
    throw new Error(
      `Required system prompt not found: ${filePath}\n` +
        `This should never happen. Please reinstall vibing.nvim.`
    );
  }
}

function buildTemplateVars(config: SystemPromptConfig): TemplateVars {
  const languageName = config.language ? LANGUAGE_NAMES[config.language] : null;
  if (config.language && !languageName) {
    console.warn(`[vibing.nvim] Unknown language code: ${config.language}`);
  }

  return {
    RPC_PORT: config.rpcPort?.toString() ?? null,
    SESSION_ID: config.sessionId,
    LANGUAGE: config.language,
    LANGUAGE_NAME: languageName ?? null,
    CWD: config.cwd,
  };
}

function loadAndRenderPrompt(
  promptsDir: string,
  filename: string,
  vars: TemplateVars
): string {
  const filePath = path.join(promptsDir, filename);
  const content = readRequiredPromptFile(filePath);
  return renderTemplate(content, vars);
}

function loadProjectPrompt(
  projectPromptPath: string,
  cwd: string,
  vars: TemplateVars
): string | null {
  const normalizedPath = path.resolve(projectPromptPath);
  const normalizedCwd = path.resolve(cwd);

  if (!normalizedPath.startsWith(normalizedCwd) || !existsSync(normalizedPath)) {
    return null;
  }

  try {
    const content = readFileSync(normalizedPath, 'utf-8');
    return renderTemplate(content, vars);
  } catch (error) {
    const err = toError(error);
    console.warn(
      `[vibing.nvim] Failed to read project prompt: ${normalizedPath}\n` +
        `Reason: ${err.message}\n` +
        `Continuing with default prompts only.`
    );
    return null;
  }
}

export function loadSystemPrompt(config: SystemPromptConfig): string {
  if (!config.prioritizeVibingLsp) {
    return '';
  }

  const parts: string[] = [];
  const vars = buildTemplateVars(config);

  if (!config.sessionId) {
    parts.push(loadAndRenderPrompt(config.promptsDir, 'session-info.md', vars));
  }

  parts.push(loadAndRenderPrompt(config.promptsDir, 'vibing-system.md', vars));

  if (config.rpcPort) {
    parts.push(loadAndRenderPrompt(config.promptsDir, 'rpc-info.md', vars));
  }

  if (config.language && vars.LANGUAGE_NAME) {
    parts.push(loadAndRenderPrompt(config.promptsDir, 'language-instruction.md', vars));
  }

  const projectPrompt = loadProjectPrompt(config.projectPromptPath, config.cwd, vars);
  if (projectPrompt) {
    parts.push(projectPrompt);
  }

  return parts.join('\n\n');
}
