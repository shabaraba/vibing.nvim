import { describe, it } from 'node:test';
import assert from 'node:assert';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const wrapperPath = join(__dirname, '../bin/agent-wrapper.mjs');

describe('Agent Wrapper', () => {
  it('should output session and done events', async () => {
    const events = [];
    const child = spawn('node', [wrapperPath, '--prompt', 'Say hello', '--cwd', process.cwd()]);

    let stdout = '';

    child.stdout.on('data', (data) => {
      stdout += data.toString();
      const lines = stdout.split('\n');
      stdout = lines.pop();

      for (const line of lines) {
        if (line.trim()) {
          try {
            events.push(JSON.parse(line));
          } catch {
            console.error('Failed to parse:', line);
          }
        }
      }
    });

    await new Promise((resolve) => {
      child.on('close', resolve);
    });

    const hasSession = events.some((e) => e.type === 'session');
    const hasDone = events.some((e) => e.type === 'done');

    assert.ok(hasSession, 'Should have session event');
    assert.ok(hasDone, 'Should have done event');
  });

  it('should handle basic prompts', async () => {
    const events = [];
    const child = spawn('node', [
      wrapperPath,
      '--prompt',
      'Return the number 42',
      '--cwd',
      process.cwd(),
    ]);

    let stdout = '';

    child.stdout.on('data', (data) => {
      stdout += data.toString();
      const lines = stdout.split('\n');
      stdout = lines.pop();

      for (const line of lines) {
        if (line.trim()) {
          try {
            events.push(JSON.parse(line));
          } catch {
            // Ignore parse errors for partial lines
          }
        }
      }
    });

    await new Promise((resolve) => {
      child.on('close', resolve);
    });

    const chunks = events.filter((e) => e.type === 'chunk');
    assert.ok(chunks.length > 0, 'Should have at least one chunk');
  });
});
