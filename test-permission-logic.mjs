#!/usr/bin/env node
/**
 * Test permission matching logic in isolation
 */

// Copy the exact functions from agent-wrapper.mjs
function parseToolPattern(toolStr) {
  // Match granular pattern: Tool(ruleContent)
  const granularMatch = toolStr.match(/^([a-z]+)\((.+)\)$/i);
  if (granularMatch) {
    const toolName = granularMatch[1].toLowerCase();
    const ruleContent = granularMatch[2];

    // Determine pattern type based on tool name
    if (toolName === 'bash') {
      // Bash: wildcard (npm:*) or exact (npm install)
      const isWildcard = ruleContent.match(/^([^:]+):\*$/);
      return {
        toolName: 'bash',
        ruleContent: ruleContent.toLowerCase(),
        type: isWildcard ? 'bash_wildcard' : 'bash_exact',
      };
    } else if (['read', 'write', 'edit'].includes(toolName)) {
      // File tools: glob patterns (src/**/*.ts)
      return {
        toolName: toolName,
        ruleContent: ruleContent,
        type: 'file_glob',
      };
    } else if (['webfetch', 'websearch'].includes(toolName)) {
      // Web tools: domain patterns (github.com, *.npmjs.com)
      return {
        toolName: toolName,
        ruleContent: ruleContent.toLowerCase(),
        type: 'domain_pattern',
      };
    } else if (['glob', 'grep'].includes(toolName)) {
      // Search tools: patterns
      return {
        toolName: toolName,
        ruleContent: ruleContent,
        type: 'search_pattern',
      };
    }

    // Unknown tool with pattern
    return {
      toolName: toolName,
      ruleContent: ruleContent,
      type: 'unknown_pattern',
    };
  }

  // Simple tool name without pattern
  return { toolName: toolStr.toLowerCase(), ruleContent: null, type: 'tool_name' };
}

function matchesBashPattern(command, ruleContent, type) {
  const cmd = command.trim().toLowerCase();
  const rule = ruleContent.toLowerCase();

  if (type === 'bash_wildcard') {
    // Extract base command from pattern: "npm:*" -> "npm"
    const basePattern = rule.split(':')[0];
    const cmdParts = cmd.split(/\s+/);
    return cmdParts[0] === basePattern;
  } else {
    // Exact match: "npm install" matches "npm install" or "npm install --save"
    return cmd === rule || cmd.startsWith(rule + ' ');
  }
}

function matchesPermission(toolName, input, permissionStr) {
  try {
    const parsed = parseToolPattern(permissionStr);

    // Simple tool name match (no pattern)
    if (parsed.type === 'tool_name') {
      return toolName.toLowerCase() === parsed.toolName;
    }

    // Tool name must match
    if (toolName.toLowerCase() !== parsed.toolName) {
      return false;
    }

    // Pattern-based matching
    switch (parsed.type) {
      case 'bash_wildcard':
      case 'bash_exact':
        return input.command
          ? matchesBashPattern(input.command, parsed.ruleContent, parsed.type)
          : false;

      case 'file_glob':
        return input.file_path ? matchesFileGlob(input.file_path, parsed.ruleContent) : false;

      case 'domain_pattern':
        return input.url ? matchesDomainPattern(input.url, parsed.ruleContent) : false;

      case 'search_pattern':
        // For Glob/Grep, pattern in ruleContent should match tool's pattern parameter
        // This is a simple equality check for now
        return input.pattern ? input.pattern === parsed.ruleContent : false;

      default:
        // Unknown pattern type - deny for safety
        return false;
    }
  } catch (error) {
    console.error(
      '[ERROR] matchesPermission failed:',
      error.message,
      'toolName:',
      toolName,
      'permissionStr:',
      permissionStr
    );
    // On error, deny for safety
    return false;
  }
}

// Test cases
console.log('\n=== Test 1: Simple tool name match ===');
const test1 = matchesPermission('Bash', { command: 'git status' }, 'Bash');
console.log(`matchesPermission("Bash", {command: "git status"}, "Bash") = ${test1}`);
console.log(`Expected: true, Got: ${test1}, ${test1 === true ? '✓' : '✗'}`);

console.log('\n=== Test 2: Bash wildcard pattern (should NOT match) ===');
const test2 = matchesPermission('Bash', { command: 'git status' }, 'Bash(npm:*)');
console.log(`matchesPermission("Bash", {command: "git status"}, "Bash(npm:*)") = ${test2}`);
console.log(`Expected: false, Got: ${test2}, ${test2 === false ? '✓' : '✗'}`);

console.log('\n=== Test 3: Bash wildcard pattern (should match) ===');
const test3 = matchesPermission('Bash', { command: 'npm install' }, 'Bash(npm:*)');
console.log(`matchesPermission("Bash", {command: "npm install"}, "Bash(npm:*)") = ${test3}`);
console.log(`Expected: true, Got: ${test3}, ${test3 === true ? '✓' : '✗'}`);

console.log('\n=== Test 4: Bash wildcard pattern with args (should match) ===');
const test4 = matchesPermission('Bash', { command: 'npm install --save' }, 'Bash(npm:*)');
console.log(`matchesPermission("Bash", {command: "npm install --save"}, "Bash(npm:*)") = ${test4}`);
console.log(`Expected: true, Got: ${test4}, ${test4 === true ? '✓' : '✗'}`);

console.log('\n=== Parsing Debug ===');
console.log('parseToolPattern("Bash"):', JSON.stringify(parseToolPattern('Bash'), null, 2));
console.log(
  'parseToolPattern("Bash(npm:*)"):',
  JSON.stringify(parseToolPattern('Bash(npm:*)'), null, 2)
);
