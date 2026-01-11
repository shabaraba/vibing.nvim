/**
 * Common utility functions for agent-wrapper
 */

/**
 * Safe JSON stringify with error handling
 * @param {any} obj - Object to stringify
 * @returns {string} JSON string or error message
 */
export function safeJsonStringify(obj) {
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
