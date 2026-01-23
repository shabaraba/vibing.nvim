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
 * Uses strict mode: throws error for undefined variables to catch bugs early
 * @param template - Template string with {{VAR}} placeholders
 * @param vars - Variables to substitute into template
 * @returns Rendered template string
 * @throws Error if template contains undefined variable
 */
export function renderTemplate(template: string, vars: TemplateVars): string {
  return template.replace(/\{\{(\w+)\}\}/g, (match, key: string) => {
    if (!(key in vars)) {
      throw new Error(
        `Template error: Unknown variable '${key}' in template.\n` +
          `Available variables: ${Object.keys(vars).join(', ')}`
      );
    }
    const value = vars[key as keyof TemplateVars];
    if (value === null) {
      console.warn(`[vibing.nvim] Template variable '${key}' is null, using empty string`);
      return '';
    }
    return value;
  });
}
