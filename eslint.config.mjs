import js from '@eslint/js';

export default [
  {
    ignores: ['node_modules/**', '**/dist/**', '**/build/**', '.vibing/**'],
  },
  js.configs.recommended,
  {
    files: ['**/*.{js,mjs}'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        console: 'readonly',
        process: 'readonly',
        Buffer: 'readonly',
        __dirname: 'readonly',
        __filename: 'readonly',
      },
    },
    rules: {
      'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      'no-console': 'off',
      'prefer-const': 'error',
      'no-var': 'error',
    },
  },
  {
    files: ['tree-sitter-vibing/grammar.js'],
    languageOptions: {
      sourceType: 'commonjs',
      globals: {
        module: 'readonly',
        grammar: 'readonly',
        choice: 'readonly',
        optional: 'readonly',
        prec: 'readonly',
        repeat: 'readonly',
        repeat1: 'readonly',
        seq: 'readonly',
        token: 'readonly',
      },
    },
    rules: {
      'no-control-regex': 'off',
      'no-regex-spaces': 'off',
    },
  },
];
