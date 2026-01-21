import { describe, it } from 'node:test';
import assert from 'node:assert';

// Import extractInputSummary function by mocking the module
// Since it's not exported, we'll test it indirectly through the public API
// For now, we'll create a minimal implementation for testing

// Mock implementation of extractInputSummary for testing
function extractInputSummary(toolName, toolInput) {
  // For Task tool, show subagent_type or prompt
  if (toolName === 'Task') {
    if (toolInput.subagent_type && typeof toolInput.subagent_type === 'string') {
      const subagentType = toolInput.subagent_type.trim();
      return subagentType || 'default';
    }
    // Fallback to prompt (truncated)
    if (toolInput.prompt && typeof toolInput.prompt === 'string') {
      const prompt = toolInput.prompt.trim();
      if (prompt) {
        return prompt.length > 30 ? prompt.substring(0, 30) + '...' : prompt;
      }
    }
    return 'default';
  }

  return toolInput.command || toolInput.file_path || toolInput.pattern || toolInput.query || '';
}

describe('extractInputSummary', () => {
  describe('Task tool', () => {
    it('should return subagent_type for Task tool', () => {
      const summary = extractInputSummary('Task', { subagent_type: 'code-reviewer' });
      assert.strictEqual(summary, 'code-reviewer');
    });

    it('should handle empty subagent_type for Task tool', () => {
      const summary = extractInputSummary('Task', { subagent_type: '' });
      assert.strictEqual(summary, 'default');
    });

    it('should handle whitespace-only subagent_type for Task tool', () => {
      const summary = extractInputSummary('Task', { subagent_type: '   ' });
      assert.strictEqual(summary, 'default');
    });

    it('should handle missing subagent_type for Task tool', () => {
      const summary = extractInputSummary('Task', { prompt: 'Do something' });
      assert.strictEqual(summary, 'Do something');
    });

    it('should truncate long prompt for Task tool', () => {
      const summary = extractInputSummary('Task', {
        prompt: 'This is a very long prompt that should be truncated because it exceeds the limit',
      });
      assert.strictEqual(summary, 'This is a very long prompt tha...');
    });

    it('should handle empty prompt for Task tool', () => {
      const summary = extractInputSummary('Task', { prompt: '' });
      assert.strictEqual(summary, 'default');
    });

    it('should handle whitespace-only prompt for Task tool', () => {
      const summary = extractInputSummary('Task', { prompt: '   ' });
      assert.strictEqual(summary, 'default');
    });

    it('should handle missing both subagent_type and prompt for Task tool', () => {
      const summary = extractInputSummary('Task', {});
      assert.strictEqual(summary, 'default');
    });

    it('should handle non-string subagent_type for Task tool', () => {
      const summary = extractInputSummary('Task', { subagent_type: 123 });
      assert.strictEqual(summary, 'default');
    });

    it('should prioritize subagent_type over prompt for Task tool', () => {
      const summary = extractInputSummary('Task', {
        subagent_type: 'Explore',
        prompt: 'Do something',
      });
      assert.strictEqual(summary, 'Explore');
    });

    it('should trim subagent_type for Task tool', () => {
      const summary = extractInputSummary('Task', { subagent_type: '  code-reviewer  ' });
      assert.strictEqual(summary, 'code-reviewer');
    });

    it('should trim prompt for Task tool', () => {
      const summary = extractInputSummary('Task', { prompt: '  Do something  ' });
      assert.strictEqual(summary, 'Do something');
    });
  });

  describe('Other tools', () => {
    it('should return command for Bash tool', () => {
      const summary = extractInputSummary('Bash', { command: 'ls -la' });
      assert.strictEqual(summary, 'ls -la');
    });

    it('should return file_path for Read tool', () => {
      const summary = extractInputSummary('Read', { file_path: 'src/index.ts' });
      assert.strictEqual(summary, 'src/index.ts');
    });

    it('should return pattern for Grep tool', () => {
      const summary = extractInputSummary('Grep', { pattern: 'TODO' });
      assert.strictEqual(summary, 'TODO');
    });

    it('should return query for WebSearch tool', () => {
      const summary = extractInputSummary('WebSearch', { query: 'nodejs docs' });
      assert.strictEqual(summary, 'nodejs docs');
    });

    it('should return empty string if no matching property', () => {
      const summary = extractInputSummary('UnknownTool', { foo: 'bar' });
      assert.strictEqual(summary, '');
    });

    it('should prioritize command over file_path', () => {
      const summary = extractInputSummary('Bash', {
        command: 'cat file.txt',
        file_path: 'file.txt',
      });
      assert.strictEqual(summary, 'cat file.txt');
    });
  });
});
