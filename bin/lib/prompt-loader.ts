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

/**
 * Read a required prompt file and throw if not found
 * @param filePath - Path to the prompt file
 * @returns File content as string
 * @throws Error if file cannot be read
 */
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

/**
 * Build template variables for prompt rendering
 * @param config - System prompt configuration
 * @returns Template variables for rendering
 */
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

/**
 * Load and render a prompt file with template variables
 * @param promptsDir - Directory containing prompt files
 * @param filename - Name of the prompt file
 * @param vars - Template variables for rendering
 * @returns Rendered prompt string
 */
function loadAndRenderPrompt(promptsDir: string, filename: string, vars: TemplateVars): string {
  const filePath = path.join(promptsDir, filename);
  const content = readRequiredPromptFile(filePath);
  return renderTemplate(content, vars);
}

/**
 * Load project-specific prompt file if it exists
 * @param projectPromptPath - Path to project prompt file
 * @param cwd - Current working directory
 * @param vars - Template variables for rendering
 * @returns Rendered project prompt string or null if not found
 */
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

/**
 * Load system prompt by combining multiple prompt files
 * @param config - System prompt configuration
 * @returns Combined system prompt string
 */
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
