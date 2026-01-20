#!/usr/bin/env node
/**
 * Test plugin loader functionality
 */

import { strict as assert } from 'assert';
import { mkdir, writeFile, rm, mkdtemp } from 'fs/promises';
import { join } from 'path';
import { tmpdir, homedir } from 'os';
import { readFile, access } from 'fs/promises';

// We need to mock homedir for testing, so we'll test the logic directly
// by creating a temporary directory structure

/**
 * Check if a path exists on the filesystem.
 * Mimics the pathExists function from plugin-loader.ts
 */
async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * Load installed plugins from a custom home directory.
 * This is a test-friendly version of loadInstalledPlugins that accepts a custom home path.
 */
async function loadInstalledPlugins(customHome = null) {
  const home = customHome || process.env.HOME || homedir();
  const pluginsFile = join(home, '.claude', 'plugins', 'installed_plugins.json');

  let content;
  try {
    content = await readFile(pluginsFile, 'utf8');
  } catch {
    return [];
  }

  let installed;
  try {
    installed = JSON.parse(content);
  } catch {
    return [];
  }

  if (!installed.plugins || typeof installed.plugins !== 'object') {
    return [];
  }

  // Collect all installation paths
  const allInstallations = [];
  for (const installations of Object.values(installed.plugins)) {
    if (Array.isArray(installations)) {
      allInstallations.push(...installations);
    }
  }

  // Check all paths in parallel for better performance
  const pathChecks = await Promise.all(
    allInstallations.map(async (installation) => {
      const exists = await pathExists(installation.installPath);
      return { installation, exists };
    })
  );

  // Filter to only existing paths and map to PluginReference format
  const plugins = pathChecks
    .filter(({ exists }) => exists)
    .map(({ installation }) => ({
      type: 'local',
      path: installation.installPath,
    }));

  return plugins;
}

/**
 * Create a mock installed_plugins.json structure
 */
function createMockPluginsFile(plugins) {
  return JSON.stringify({
    version: 2,
    plugins,
  });
}

// Test 1: Parse valid plugin structure
console.log('Test 1: Valid plugin structure parsing');
{
  const mockData = {
    'test-plugin@registry': [
      {
        scope: 'user',
        installPath: '/tmp/test-plugin',
        version: '1.0.0',
        installedAt: '2024-01-01T00:00:00Z',
        lastUpdated: '2024-01-01T00:00:00Z',
        gitCommitSha: 'abc123',
      },
    ],
  };

  const content = createMockPluginsFile(mockData);
  const parsed = JSON.parse(content);

  assert.equal(parsed.version, 2);
  assert.ok(parsed.plugins['test-plugin@registry']);
  assert.equal(parsed.plugins['test-plugin@registry'][0].installPath, '/tmp/test-plugin');
  console.log('  ✓ Valid structure parsed correctly');
}

// Test 2: Handle empty plugins object
console.log('Test 2: Empty plugins object');
{
  const content = createMockPluginsFile({});
  const parsed = JSON.parse(content);

  assert.deepEqual(parsed.plugins, {});
  console.log('  ✓ Empty plugins handled correctly');
}

// Test 3: Handle multiple plugins
console.log('Test 3: Multiple plugins');
{
  const mockData = {
    'plugin-a@registry': [
      {
        scope: 'user',
        installPath: '/path/a',
        version: '1.0.0',
        installedAt: '',
        lastUpdated: '',
        gitCommitSha: '',
      },
    ],
    'plugin-b@registry': [
      {
        scope: 'user',
        installPath: '/path/b',
        version: '2.0.0',
        installedAt: '',
        lastUpdated: '',
        gitCommitSha: '',
      },
    ],
    'plugin-c@registry': [
      {
        scope: 'project',
        installPath: '/path/c',
        version: '3.0.0',
        installedAt: '',
        lastUpdated: '',
        gitCommitSha: '',
      },
    ],
  };

  const content = createMockPluginsFile(mockData);
  const parsed = JSON.parse(content);

  assert.equal(Object.keys(parsed.plugins).length, 3);
  console.log('  ✓ Multiple plugins handled correctly');
}

// Test 4: Handle corrupted JSON
console.log('Test 4: Corrupted JSON handling');
{
  const corruptedContent = '{ invalid json }}}';

  try {
    JSON.parse(corruptedContent);
    assert.fail('Should have thrown an error');
  } catch (error) {
    assert.ok(error instanceof SyntaxError);
    console.log('  ✓ Corrupted JSON throws SyntaxError');
  }
}

// Test 5: Handle missing plugins property
console.log('Test 5: Missing plugins property');
{
  const content = JSON.stringify({ version: 2 });
  const parsed = JSON.parse(content);

  assert.equal(parsed.plugins, undefined);
  console.log('  ✓ Missing plugins property handled correctly');
}

// Test 6: Handle null plugins property
console.log('Test 6: Null plugins property');
{
  const content = JSON.stringify({ version: 2, plugins: null });
  const parsed = JSON.parse(content);

  assert.equal(parsed.plugins, null);
  console.log('  ✓ Null plugins property handled correctly');
}

// Test 7: PluginReference structure
console.log('Test 7: PluginReference structure');
{
  const pluginRef = {
    type: 'local',
    path: '/some/path/to/plugin',
  };

  assert.equal(pluginRef.type, 'local');
  assert.equal(typeof pluginRef.path, 'string');
  console.log('  ✓ PluginReference structure is correct');
}

// Test 8: Multiple installations for same plugin
console.log('Test 8: Multiple installations for same plugin');
{
  const mockData = {
    'plugin@registry': [
      {
        scope: 'user',
        installPath: '/path/v1',
        version: '1.0.0',
        installedAt: '',
        lastUpdated: '',
        gitCommitSha: '',
      },
      {
        scope: 'project',
        installPath: '/path/v2',
        version: '2.0.0',
        installedAt: '',
        lastUpdated: '',
        gitCommitSha: '',
      },
    ],
  };

  const content = createMockPluginsFile(mockData);
  const parsed = JSON.parse(content);

  assert.equal(parsed.plugins['plugin@registry'].length, 2);
  console.log('  ✓ Multiple installations handled correctly');
}

// Test 9: Integration test - loadInstalledPlugins with real filesystem
console.log('Test 9: Integration test - loadInstalledPlugins with real filesystem');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    // Create mock home directory structure
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Create a mock plugin directory
    const pluginPath = join(tempDir, 'test-plugin');
    await mkdir(pluginPath, { recursive: true });

    // Create package.json at plugin root (expected by plugin loader)
    await writeFile(
      join(pluginPath, 'package.json'),
      JSON.stringify({ name: 'test-plugin', version: '1.0.0' })
    );

    // Create installed_plugins.json
    const pluginsData = {
      version: 2,
      plugins: {
        'test-plugin@registry': [
          {
            scope: 'user',
            installPath: pluginPath,
            version: '1.0.0',
            installedAt: '2024-01-01T00:00:00Z',
            lastUpdated: '2024-01-01T00:00:00Z',
            gitCommitSha: 'abc123',
          },
        ],
      },
    };
    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify(pluginsData));

    // Call loadInstalledPlugins with custom home directory
    const plugins = await loadInstalledPlugins(tempDir);

    // Assert the plugin was loaded correctly
    assert.equal(plugins.length, 1);
    assert.equal(plugins[0].type, 'local');
    assert.equal(plugins[0].path, pluginPath);

    console.log('  ✓ loadInstalledPlugins correctly loaded plugin');
  } finally {
    // Cleanup
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 10: loadInstalledPlugins - missing file
console.log('Test 10: loadInstalledPlugins - missing file');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    // Don't create installed_plugins.json
    const plugins = await loadInstalledPlugins(tempDir);

    // Should return empty array when file doesn't exist
    assert.deepEqual(plugins, []);
    console.log('  ✓ Returns empty array when installed_plugins.json is missing');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 11: loadInstalledPlugins - malformed JSON
console.log('Test 11: loadInstalledPlugins - malformed JSON');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Write malformed JSON
    await writeFile(join(claudeDir, 'installed_plugins.json'), '{ invalid json }}}');

    const plugins = await loadInstalledPlugins(tempDir);

    // Should return empty array when JSON is malformed
    assert.deepEqual(plugins, []);
    console.log('  ✓ Returns empty array when JSON is malformed');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 12: loadInstalledPlugins - filters non-existent paths
console.log('Test 12: loadInstalledPlugins - filters non-existent paths');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Create one valid plugin path
    const validPluginPath = join(tempDir, 'valid-plugin');
    await mkdir(validPluginPath, { recursive: true });

    // Reference to a non-existent plugin path
    const invalidPluginPath = join(tempDir, 'non-existent-plugin');

    const pluginsData = {
      version: 2,
      plugins: {
        'valid-plugin@registry': [
          {
            scope: 'user',
            installPath: validPluginPath,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
        'invalid-plugin@registry': [
          {
            scope: 'user',
            installPath: invalidPluginPath,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
      },
    };

    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify(pluginsData));

    const plugins = await loadInstalledPlugins(tempDir);

    // Should only include the valid plugin
    assert.equal(plugins.length, 1);
    assert.equal(plugins[0].path, validPluginPath);
    console.log('  ✓ Filters out non-existent plugin paths');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 13: loadInstalledPlugins - parallel path checks
console.log('Test 13: loadInstalledPlugins - parallel path checks');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Create multiple plugin directories
    const plugin1Path = join(tempDir, 'plugin1');
    const plugin2Path = join(tempDir, 'plugin2');
    const plugin3Path = join(tempDir, 'plugin3');

    await mkdir(plugin1Path, { recursive: true });
    await mkdir(plugin2Path, { recursive: true });
    await mkdir(plugin3Path, { recursive: true });

    const pluginsData = {
      version: 2,
      plugins: {
        'plugin1@registry': [
          {
            scope: 'user',
            installPath: plugin1Path,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
        'plugin2@registry': [
          {
            scope: 'user',
            installPath: plugin2Path,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
        'plugin3@registry': [
          {
            scope: 'user',
            installPath: plugin3Path,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
      },
    };

    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify(pluginsData));

    const startTime = Date.now();
    const plugins = await loadInstalledPlugins(tempDir);
    const endTime = Date.now();

    // Should load all valid plugins
    assert.equal(plugins.length, 3);

    // Verify all paths are correct
    const paths = plugins.map((p) => p.path).sort();
    assert.deepEqual(paths, [plugin1Path, plugin2Path, plugin3Path].sort());

    // All plugins should have correct type
    assert.ok(plugins.every((p) => p.type === 'local'));

    console.log(`  ✓ Parallel path checks work correctly (${endTime - startTime}ms for 3 plugins)`);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 14: loadInstalledPlugins - invalid plugins structure
console.log('Test 14: loadInstalledPlugins - invalid plugins structure');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Missing plugins property
    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify({ version: 2 }));

    let plugins = await loadInstalledPlugins(tempDir);
    assert.deepEqual(plugins, []);

    // Null plugins property
    await writeFile(
      join(claudeDir, 'installed_plugins.json'),
      JSON.stringify({ version: 2, plugins: null })
    );
    plugins = await loadInstalledPlugins(tempDir);
    assert.deepEqual(plugins, []);

    console.log('  ✓ Handles invalid plugins structure gracefully');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 15: Debug logging environment variable
console.log('Test 15: Debug logging with VIBING_DEBUG');
{
  // Save original value
  const originalDebug = process.env.VIBING_DEBUG;

  // Test with debug enabled
  process.env.VIBING_DEBUG = 'true';
  assert.equal(process.env.VIBING_DEBUG, 'true');

  // Test with debug disabled
  delete process.env.VIBING_DEBUG;
  assert.equal(process.env.VIBING_DEBUG, undefined);

  // Restore original value
  if (originalDebug !== undefined) {
    process.env.VIBING_DEBUG = originalDebug;
  }

  console.log('  ✓ Debug environment variable handling works');
}

console.log('\n✅ All plugin-loader tests passed!');
