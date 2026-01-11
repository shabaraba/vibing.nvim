import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { promises as fs } from 'fs';
import * as path from 'path';
import * as os from 'os';
import { handleListInstances } from '../handlers/instances.js';

// Mock fs and os modules
vi.mock('fs', () => ({
  promises: {
    access: vi.fn(),
    readdir: vi.fn(),
    readFile: vi.fn(),
    unlink: vi.fn(),
  },
}));

vi.mock('os', () => ({
  platform: vi.fn(),
  homedir: vi.fn(),
}));

describe('handleListInstances', () => {
  const mockHomedir = '/home/testuser';
  const mockLocalAppData = 'C:\\Users\\testuser\\AppData\\Local';

  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(os.homedir).mockReturnValue(mockHomedir);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('Platform-specific registry paths', () => {
    it('should use XDG_DATA_HOME on Linux when set', async () => {
      vi.mocked(os.platform).mockReturnValue('linux');
      const originalXdgDataHome = process.env.XDG_DATA_HOME;
      process.env.XDG_DATA_HOME = '/custom/data';

      vi.mocked(fs.access).mockRejectedValue(new Error('Directory not found'));

      const result = await handleListInstances({});

      expect(result.content[0].text).toContain('[]');

      process.env.XDG_DATA_HOME = originalXdgDataHome;
    });

    it('should use ~/.local/share on Linux when XDG_DATA_HOME not set', async () => {
      vi.mocked(os.platform).mockReturnValue('linux');
      const originalXdgDataHome = process.env.XDG_DATA_HOME;
      delete process.env.XDG_DATA_HOME;

      vi.mocked(fs.access).mockRejectedValue(new Error('Directory not found'));

      const result = await handleListInstances({});

      expect(result.content[0].text).toContain('[]');

      if (originalXdgDataHome) {
        process.env.XDG_DATA_HOME = originalXdgDataHome;
      }
    });

    it('should use %LOCALAPPDATA% on Windows', async () => {
      vi.mocked(os.platform).mockReturnValue('win32');
      const originalLocalAppData = process.env.LOCALAPPDATA;
      process.env.LOCALAPPDATA = mockLocalAppData;

      vi.mocked(fs.access).mockRejectedValue(new Error('Directory not found'));

      const result = await handleListInstances({});

      expect(result.content[0].text).toContain('[]');

      if (originalLocalAppData) {
        process.env.LOCALAPPDATA = originalLocalAppData;
      }
    });

    it('should fallback to homedir/AppData/Local on Windows when LOCALAPPDATA not set', async () => {
      vi.mocked(os.platform).mockReturnValue('win32');
      const originalLocalAppData = process.env.LOCALAPPDATA;
      delete process.env.LOCALAPPDATA;

      vi.mocked(fs.access).mockRejectedValue(new Error('Directory not found'));

      const result = await handleListInstances({});

      expect(result.content[0].text).toContain('[]');

      if (originalLocalAppData) {
        process.env.LOCALAPPDATA = originalLocalAppData;
      }
    });
  });

  describe('Instance listing', () => {
    beforeEach(() => {
      vi.mocked(os.platform).mockReturnValue('linux');
      delete process.env.XDG_DATA_HOME;
    });

    it('should return empty array when registry directory does not exist', async () => {
      vi.mocked(fs.access).mockRejectedValue(new Error('Directory not found'));

      const result = await handleListInstances({});

      expect(JSON.parse(result.content[0].text)).toEqual({ instances: [] });
    });

    it('should return running instances from registry', async () => {
      const mockInstances = [
        {
          pid: 12345,
          port: 9876,
          cwd: '/home/testuser/project',
          started_at: 1704067200,
        },
        {
          pid: 12346,
          port: 9877,
          cwd: '/home/testuser/project2',
          started_at: 1704067300,
        },
      ];

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue([
        '12345.json',
        '12346.json',
        'not-a-json.txt',
      ] as any);
      vi.mocked(fs.readFile)
        .mockResolvedValueOnce(JSON.stringify(mockInstances[0]))
        .mockResolvedValueOnce(JSON.stringify(mockInstances[1]));

      // Mock process.kill to indicate both processes are alive
      const originalKill = process.kill;
      process.kill = vi.fn(() => true) as any;

      const result = await handleListInstances({});

      const parsed = JSON.parse(result.content[0].text);
      expect(parsed.instances).toHaveLength(2);
      expect(parsed.instances[0].port).toBe(9877); // Sorted by started_at desc
      expect(parsed.instances[1].port).toBe(9876);

      process.kill = originalKill;
    });

    it('should clean up stale instances (dead processes)', async () => {
      const deadInstance = {
        pid: 99999,
        port: 9876,
        cwd: '/home/testuser/project',
        started_at: 1704067200,
      };

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(['99999.json'] as any);
      vi.mocked(fs.readFile).mockResolvedValue(JSON.stringify(deadInstance));

      // Mock process.kill to throw error (process doesn't exist)
      const originalKill = process.kill;
      process.kill = vi.fn(() => {
        throw new Error('ESRCH: No such process');
      }) as any;

      const result = await handleListInstances({});

      expect(vi.mocked(fs.unlink)).toHaveBeenCalled();
      const parsed = JSON.parse(result.content[0].text);
      expect(parsed.instances).toHaveLength(0);

      process.kill = originalKill;
    });

    it('should ignore invalid JSON files', async () => {
      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(['invalid.json', 'valid.json'] as any);
      vi.mocked(fs.readFile)
        .mockRejectedValueOnce(new Error('Invalid JSON'))
        .mockResolvedValueOnce(
          JSON.stringify({
            pid: 12345,
            port: 9876,
            cwd: '/home/testuser/project',
            started_at: 1704067200,
          })
        );

      const originalKill = process.kill;
      process.kill = vi.fn(() => true) as any;

      const result = await handleListInstances({});

      const parsed = JSON.parse(result.content[0].text);
      expect(parsed.instances).toHaveLength(1);
      expect(parsed.instances[0].pid).toBe(12345);

      process.kill = originalKill;
    });

    it('should ignore files without .json extension', async () => {
      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(['12345.txt', '12346.log'] as any);

      const result = await handleListInstances({});

      expect(vi.mocked(fs.readFile)).not.toHaveBeenCalled();
      const parsed = JSON.parse(result.content[0].text);
      expect(parsed.instances).toHaveLength(0);
    });
  });

  describe('Error handling', () => {
    beforeEach(() => {
      vi.mocked(os.platform).mockReturnValue('linux');
      delete process.env.XDG_DATA_HOME;
    });

    it('should handle file deletion errors gracefully', async () => {
      const deadInstance = {
        pid: 99999,
        port: 9876,
        cwd: '/home/testuser/project',
        started_at: 1704067200,
      };

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(['99999.json'] as any);
      vi.mocked(fs.readFile).mockResolvedValue(JSON.stringify(deadInstance));
      vi.mocked(fs.unlink).mockRejectedValue(new Error('Permission denied'));

      const originalKill = process.kill;
      process.kill = vi.fn(() => {
        throw new Error('ESRCH: No such process');
      }) as any;

      // Should not throw
      await expect(handleListInstances({})).resolves.toBeDefined();

      process.kill = originalKill;
    });
  });
});
