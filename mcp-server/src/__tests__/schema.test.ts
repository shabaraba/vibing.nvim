import { describe, it, expect } from 'vitest';
import {
  validateBufferParams,
  validateWindowParams,
  validateFilePath,
  validateCommand,
} from '../validation/schema';

describe('schema validation', () => {
  describe('validateBufferParams (UT-MCP-001)', () => {
    it('should accept valid buffer number', () => {
      expect(() => validateBufferParams({ bufnr: 1 })).not.toThrow();
      expect(() => validateBufferParams({ bufnr: 0 })).not.toThrow();
      expect(() => validateBufferParams({ bufnr: 100 })).not.toThrow();
    });

    it('should reject negative buffer number', () => {
      expect(() => validateBufferParams({ bufnr: -1 })).toThrow();
    });

    it('should reject string buffer number', () => {
      expect(() => validateBufferParams({ bufnr: '1' as any })).toThrow();
    });

    it('should accept undefined buffer number (optional)', () => {
      expect(() => validateBufferParams({})).not.toThrow();
    });
  });

  describe('validateWindowParams', () => {
    it('should accept valid window number', () => {
      expect(() => validateWindowParams({ winnr: 1000 })).not.toThrow();
      expect(() => validateWindowParams({ winnr: 0 })).not.toThrow();
    });

    it('should reject negative window number', () => {
      expect(() => validateWindowParams({ winnr: -1 })).toThrow();
    });
  });

  describe('validateFilePath (UT-MCP-002)', () => {
    it('should accept valid relative path', () => {
      expect(() => validateFilePath({ filepath: 'src/init.lua' })).not.toThrow();
      expect(() => validateFilePath({ filepath: './test.lua' })).not.toThrow();
    });

    it('should accept valid absolute path', () => {
      expect(() => validateFilePath({ filepath: '/absolute/path.lua' })).not.toThrow();
    });

    it('should reject path traversal attempts', () => {
      expect(() => validateFilePath({ filepath: '../../../etc/passwd' })).toThrow();
      expect(() => validateFilePath({ filepath: 'src/../../etc/passwd' })).toThrow();
    });

    it('should reject empty path', () => {
      expect(() => validateFilePath({ filepath: '' })).toThrow();
    });
  });

  describe('validateCommand', () => {
    it('should accept safe commands', () => {
      expect(() => validateCommand({ command: 'write' })).not.toThrow();
      expect(() => validateCommand({ command: 'edit test.lua' })).not.toThrow();
    });

    it('should reject shell commands', () => {
      expect(() => validateCommand({ command: '!rm -rf /' })).toThrow();
      expect(() => validateCommand({ command: ':!echo test' })).toThrow();
    });

    it('should reject empty command', () => {
      expect(() => validateCommand({ command: '' })).toThrow();
    });
  });
});
