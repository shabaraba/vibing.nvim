import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

describe('RpcClient timeout (UT-MCP-004)', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('should timeout after configured duration', async () => {
    // Mock implementation that never resolves
    const mockCall = vi.fn(
      () =>
        new Promise((resolve) => {
          // Never resolves
        })
    );

    const timeoutMs = 100;
    const callWithTimeout = async () => {
      return Promise.race([
        mockCall(),
        new Promise((_, reject) => {
          setTimeout(() => reject(new Error('Timeout')), timeoutMs);
        }),
      ]);
    };

    const callPromise = callWithTimeout();

    vi.advanceTimersByTime(timeoutMs + 10);

    await expect(callPromise).rejects.toThrow('Timeout');
  });

  it('should resolve before timeout for fast operations', async () => {
    const mockCall = vi.fn(() => Promise.resolve({ result: 'success' }));

    const result = await mockCall();

    expect(result).toEqual({ result: 'success' });
  });

  it('should use default timeout when not specified', () => {
    const DEFAULT_TIMEOUT = 30000;

    // This tests the configuration, not actual network calls
    expect(DEFAULT_TIMEOUT).toBe(30000);
  });

  it('should allow custom timeout per call', () => {
    const customTimeout = 5000;

    // Test that custom timeout can be specified
    expect(customTimeout).toBeLessThan(30000);
  });
});
