import { bufferTools } from './buffer.js';
import { cursorTools } from './cursor.js';
import { windowTools } from './window.js';
import { lspTools } from './lsp.js';
import { executeTools } from './execute.js';

export const allTools = [
  ...bufferTools,
  ...cursorTools,
  ...windowTools,
  ...lspTools,
  ...executeTools,
];
