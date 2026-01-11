#!/usr/bin/env node
import * as esbuild from 'esbuild';
import { mkdirSync } from 'fs';

const watch = process.argv.includes('--watch');

mkdirSync('dist/bin', { recursive: true });

const buildOptions = {
  entryPoints: ['bin/agent-wrapper.ts', 'bin/register-mcp.ts'],
  bundle: true,
  platform: 'node',
  target: 'node18',
  format: 'esm',
  outdir: 'dist/bin',
  outExtension: { '.js': '.js' },
  minify: true,
  sourcemap: false,
  external: ['@anthropic-ai/claude-agent-sdk', 'neovim', 'zod'],
  banner: {
    js: '#!/usr/bin/env node',
  },
  logLevel: 'info',
};

try {
  if (watch) {
    console.log('[vibing.nvim] Building in watch mode...');
    const ctx = await esbuild.context(buildOptions);
    await ctx.watch();
    console.log('[vibing.nvim] Watching for changes...');
  } else {
    console.log('[vibing.nvim] Bundling and minifying...');
    await esbuild.build(buildOptions);
    console.log('[vibing.nvim] ✓ Build complete');
    console.log(`[vibing.nvim]   → dist/bin/agent-wrapper.js (minified)`);
    console.log(`[vibing.nvim]   → dist/bin/register-mcp.js (minified)`);
  }
} catch (error) {
  console.error('[vibing.nvim] Build failed:', error);
  process.exit(1);
}
