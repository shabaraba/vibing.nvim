#!/usr/bin/env node
/**
 * Fails when claude-plugin/mcp-server's source imports a package its own package.json does not
 * declare (#792).
 *
 * `zod` was exactly this: four files imported it as a value, nothing in
 * claude-plugin/mcp-server/package.json named it, and every path that ran the suite happened to
 * install the repository root first, which resolves it from there by Node's own directory walk.
 * `claude-plugin/` is distributed on its own, so a tree with no such upstream `node_modules` is
 * the case this script stands in for.
 *
 * This reads source text with a regular expression rather than the TypeScript compiler's module
 * resolution, on purpose: resolution would find the very same accidental hoist that made `zod`
 * look fine for as long as it did. A textual import list, checked against the declared
 * dependencies with no resolution step in between, cannot be fooled by what happens to already be
 * on disk.
 *
 * Usage:
 *   node scripts/audit-mcp-server-imports.mjs [mcp-server-dir]
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { builtinModules } from 'node:module';
import { extname, join, relative } from 'node:path';

const serverDir = process.argv[2] ?? join(process.cwd(), 'claude-plugin', 'mcp-server');

// Anchored to the start of a (trimmed) line so prose that happens to contain the word "from" --
// a code comment, a string literal -- is never mistaken for an import statement. The body between
// "import"/"export" and "from" excludes `;` and quotes (not `\n`): a multi-line named import
// (`import {\n  z,\n} from 'zod'`) has to match across lines, and stopping at the statement's own
// terminator keeps an unrelated later quote from ever closing the match instead.
const IMPORT_SPECIFIER_PATTERNS = [
  /^\s*import\s+[^;'"]*?\bfrom\s+['"]([^'"\n]+)['"]/gm,
  /^\s*export\s+[^;'"]*?\bfrom\s+['"]([^'"\n]+)['"]/gm,
  /^\s*import\s+['"]([^'"\n]+)['"]/gm,
  /\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)/g,
  /\brequire\(\s*['"]([^'"\n]+)['"]\s*\)/g,
];

/** Every `.ts`/`.mjs` file under `dir`, skipping `node_modules` and compiled `dist` output. */
function sourceFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === 'dist') continue;
    const full = join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      out.push(...sourceFiles(full));
    } else if (['.ts', '.tsx', '.mjs', '.js'].includes(extname(entry))) {
      out.push(full);
    }
  }
  return out;
}

function isTestFile(file) {
  return file.includes(`${'__tests__'}`) || /\.test\.[jt]sx?$/.test(file);
}

function isBuiltin(specifier) {
  const bare = specifier.replace(/^node:/, '');
  return specifier.startsWith('node:') || builtinModules.includes(bare);
}

/** `@scope/pkg/sub/path` -> `@scope/pkg`; `pkg/sub/path` -> `pkg`. */
function packageName(specifier) {
  const parts = specifier.split('/');
  return specifier.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
}

function importedPackages(text) {
  const found = new Set();
  for (const pattern of IMPORT_SPECIFIER_PATTERNS) {
    for (const match of text.matchAll(pattern)) {
      const specifier = match[1];
      if (specifier.startsWith('.') || specifier.startsWith('/') || isBuiltin(specifier)) continue;
      found.add(packageName(specifier));
    }
  }
  return found;
}

const pkg = JSON.parse(readFileSync(join(serverDir, 'package.json'), 'utf8'));
const dependencies = new Set(Object.keys(pkg.dependencies ?? {}));
const devDependencies = new Set(Object.keys(pkg.devDependencies ?? {}));

const violations = [];
for (const file of sourceFiles(join(serverDir, 'src'))) {
  const text = readFileSync(file, 'utf8');
  const testFile = isTestFile(file);
  for (const name of importedPackages(text)) {
    const declared = dependencies.has(name) || (testFile && devDependencies.has(name));
    if (!declared) {
      violations.push({ file: relative(serverDir, file), name, testFile });
    }
  }
}

if (violations.length > 0) {
  console.error('[audit] the following imports are not declared in package.json:');
  for (const { file, name, testFile } of violations) {
    const where = testFile ? 'dependencies or devDependencies' : 'dependencies';
    console.error(`  ${file}: imports "${name}", not listed under ${where}`);
  }
  process.exit(1);
}

console.log(`[audit] every import in ${relative(process.cwd(), serverDir)}/src is declared`);
