import { defineConfig } from 'vitest/config';

// `include` is pinned to src/ because vitest's default glob also matches the compiled copies
// `tsc` writes to dist/__tests__/. With a build present the whole suite ran twice (14 files /
// 193 tests became 28 / 386), and -- the part that matters -- a stale dist/ meant the old
// tests passed green while the sources they were compiled from had already moved underneath.
// dist/ is gitignored, so a clean checkout never saw it and CI never would have.
//
// The pair below mirrors tsconfig.json's `rootDir: src` / `outDir: dist`: everything vitest
// runs is a source file, and nothing it runs is a build artefact.
export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
    exclude: ['**/node_modules/**', 'dist/**'],
  },
});
