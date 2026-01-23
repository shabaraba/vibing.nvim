/**
 * Template variables for prompt rendering
 */
export interface TemplateVars {
  RPC_PORT: string | null;
  SESSION_ID: string | null;
  LANGUAGE: string | null;
  LANGUAGE_NAME: string | null;
  CWD: string;
}

/**
 * Render template string with variable substitution
 * @param template - Template string with {{VAR}} placeholders
 * @param vars - Variables to substitute into template
 * @returns Rendered template string
 */
export function renderTemplate(template: string, vars: TemplateVars): string {
  return template.replace(/\{\{(\w+)\}\}/g, (match, key: string) => {
    if (!(key in vars)) {
      console.warn(`[vibing.nvim] Unknown template variable: ${match}`);
      return match;
    }
    const value = vars[key as keyof TemplateVars];
    return value ?? '';
  });
}
