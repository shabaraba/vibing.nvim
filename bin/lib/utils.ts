/**
 * Common utility functions for agent-wrapper
 */

/**
 * Safely convert unknown error to Error instance
 */
export function toError(error: unknown): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(String(error));
}

/**
 * Safe JSON stringify with error handling
 */
export function safeJsonStringify(obj: unknown): string {
  try {
    return JSON.stringify(obj);
  } catch (error) {
    try {
      return JSON.stringify({
        type: 'error',
        message: 'Failed to serialize output: ' + String(error),
      });
    } catch {
      return '{"type":"error","message":"Critical serialization failure"}';
    }
  }
}
