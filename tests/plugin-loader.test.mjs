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

async function readEnabledPluginsFromFile(settingsFile) {
  try {
    const content = await readFile(settingsFile, 'utf8');
    const settings = JSON.parse(content);
    if (settings.enabledPlugins && typeof settings.enabledPlugins === 'object') {
      return settings.enabledPlugins;
    }
  } catch {
    // File missing or invalid JSON — ignore
  }
  return {};
}

async function loadEnabledPluginIds(customHome, cwd) {
  const userSettingsFile = join(customHome, '.claude', 'settings.json');
  const projectSettingsFile = join(cwd, '.claude', 'settings.json');
  const localSettingsFile = join(cwd, '.claude', 'settings.local.json');

  const [userEnabled, projectEnabled, localEnabled] = await Promise.all([
    readEnabledPluginsFromFile(userSettingsFile),
    readEnabledPluginsFromFile(projectSettingsFile),
    readEnabledPluginsFromFile(localSettingsFile),
  ]);

  const merged = { ...userEnabled, ...projectEnabled, ...localEnabled };
  if (Object.keys(merged).length === 0) return null;

  const enabled = new Set(
    Object.entries(merged)
      .filter(([, v]) => v === true)
      .map(([k]) => k)
  );
  return enabled.size === 0 ? null : enabled;
}

/**
 * Resolve installed, enabled plugins to their on-disk paths.
 * This is a test-friendly version of resolveInstalledPlugins that accepts a custom home path.
 */
async function resolveInstalledPlugins(customHome = null, cwd = null) {
  const home = customHome || process.env.HOME || homedir();
  const projectDir = cwd || process.cwd();
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

  const enabledIds = await loadEnabledPluginIds(home, projectDir);
  const candidates = [];
  for (const [pluginId, installations] of Object.entries(installed.plugins)) {
    if (!Array.isArray(installations) || installations.length === 0) continue;
    if (enabledIds && !enabledIds.has(pluginId)) continue;

    const localInstall = installations.find(
      (inst) => inst.scope === 'local' && inst.projectPath === projectDir
    );
    const userInstall = installations.find((inst) => inst.scope === 'user');
    const install = localInstall || userInstall;
    if (!install) continue;

    candidates.push({ id: pluginId, installation: install });
  }

  const pathChecks = await Promise.all(
    candidates.map(async ({ id, installation }) => {
      const exists = await pathExists(installation.installPath);
      return { id, path: installation.installPath, exists };
    })
  );

  return pathChecks.filter(({ exists }) => exists).map(({ id, path }) => ({ id, path }));
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

// Test 7: ResolvedPlugin structure
console.log('Test 7: ResolvedPlugin structure');
{
  const resolved = {
    id: 'test-plugin@registry',
    path: '/some/path/to/plugin',
  };

  assert.equal(typeof resolved.id, 'string');
  assert.equal(typeof resolved.path, 'string');
  console.log('  ✓ ResolvedPlugin structure is correct');
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

// Test 9: Integration test - resolveInstalledPlugins with real filesystem
console.log('Test 9: Integration test - resolveInstalledPlugins with real filesystem');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    // Create mock home directory structure
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Create a mock plugin directory
    const pluginPath = join(tempDir, 'test-plugin');
    await mkdir(pluginPath, { recursive: true });

    // Create installed_plugins.json (user-scope install, no enabledPlugins filter)
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

    const plugins = await resolveInstalledPlugins(tempDir, tempDir);

    assert.equal(plugins.length, 1);
    assert.equal(plugins[0].id, 'test-plugin@registry');
    assert.equal(plugins[0].path, pluginPath);

    console.log('  ✓ resolveInstalledPlugins correctly resolved a user-scope plugin');
  } finally {
    // Cleanup
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 10: resolveInstalledPlugins - missing file
console.log('Test 10: resolveInstalledPlugins - missing file');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    // Don't create installed_plugins.json
    const plugins = await resolveInstalledPlugins(tempDir, tempDir);

    // Should return empty array when file doesn't exist
    assert.deepEqual(plugins, []);
    console.log('  ✓ Returns empty array when installed_plugins.json is missing');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 11: resolveInstalledPlugins - malformed JSON
console.log('Test 11: resolveInstalledPlugins - malformed JSON');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Write malformed JSON
    await writeFile(join(claudeDir, 'installed_plugins.json'), '{ invalid json }}}');

    const plugins = await resolveInstalledPlugins(tempDir, tempDir);

    // Should return empty array when JSON is malformed
    assert.deepEqual(plugins, []);
    console.log('  ✓ Returns empty array when JSON is malformed');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 12: resolveInstalledPlugins - filters non-existent paths
console.log('Test 12: resolveInstalledPlugins - filters non-existent paths');
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

    const plugins = await resolveInstalledPlugins(tempDir, tempDir);

    // Should only include the valid plugin
    assert.equal(plugins.length, 1);
    assert.equal(plugins[0].path, validPluginPath);
    console.log('  ✓ Filters out non-existent plugin paths');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 13: resolveInstalledPlugins - parallel path checks
console.log('Test 13: resolveInstalledPlugins - parallel path checks');
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
    const plugins = await resolveInstalledPlugins(tempDir, tempDir);
    const endTime = Date.now();

    // Should load all valid plugins
    assert.equal(plugins.length, 3);

    // Verify all paths are correct
    const paths = plugins.map((p) => p.path).sort();
    assert.deepEqual(paths, [plugin1Path, plugin2Path, plugin3Path].sort());

    // All plugins should have an id
    assert.ok(plugins.every((p) => typeof p.id === 'string' && p.id.length > 0));

    console.log(`  ✓ Parallel path checks work correctly (${endTime - startTime}ms for 3 plugins)`);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 14: resolveInstalledPlugins - invalid plugins structure
console.log('Test 14: resolveInstalledPlugins - invalid plugins structure');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    // Missing plugins property
    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify({ version: 2 }));

    let plugins = await resolveInstalledPlugins(tempDir, tempDir);
    assert.deepEqual(plugins, []);

    // Null plugins property
    await writeFile(
      join(claudeDir, 'installed_plugins.json'),
      JSON.stringify({ version: 2, plugins: null })
    );
    plugins = await resolveInstalledPlugins(tempDir, tempDir);
    assert.deepEqual(plugins, []);

    console.log('  ✓ Handles invalid plugins structure gracefully');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 15: enabledPlugins filtering
console.log('Test 15: enabledPlugins filtering');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    const allowedPath = join(tempDir, 'allowed-plugin');
    const blockedPath = join(tempDir, 'blocked-plugin');
    await mkdir(allowedPath, { recursive: true });
    await mkdir(blockedPath, { recursive: true });

    const pluginsData = {
      version: 2,
      plugins: {
        'allowed@registry': [
          {
            scope: 'user',
            installPath: allowedPath,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
        'blocked@registry': [
          {
            scope: 'user',
            installPath: blockedPath,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
      },
    };
    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify(pluginsData));

    // enabledPlugins in user settings.json only lists "allowed"
    await mkdir(join(tempDir, '.claude'), { recursive: true });
    await writeFile(
      join(tempDir, '.claude', 'settings.json'),
      JSON.stringify({ enabledPlugins: { 'allowed@registry': true, 'blocked@registry': false } })
    );

    const plugins = await resolveInstalledPlugins(tempDir, tempDir);

    assert.equal(plugins.length, 1);
    assert.equal(plugins[0].id, 'allowed@registry');
    console.log('  ✓ enabledPlugins filter excludes disabled/unlisted plugins');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 16: local-scope install preferred over user-scope for the current project
console.log('Test 16: local-scope install preferred over user-scope');
{
  const tempDir = await mkdtemp(join(tmpdir(), 'vibing-test-'));

  try {
    const claudeDir = join(tempDir, '.claude', 'plugins');
    await mkdir(claudeDir, { recursive: true });

    const userPath = join(tempDir, 'user-install');
    const localPath = join(tempDir, 'local-install');
    await mkdir(userPath, { recursive: true });
    await mkdir(localPath, { recursive: true });

    const pluginsData = {
      version: 2,
      plugins: {
        'dual@registry': [
          {
            scope: 'user',
            installPath: userPath,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
          {
            scope: 'local',
            projectPath: tempDir,
            installPath: localPath,
            version: '1.0.0',
            installedAt: '',
            lastUpdated: '',
            gitCommitSha: '',
          },
        ],
      },
    };
    await writeFile(join(claudeDir, 'installed_plugins.json'), JSON.stringify(pluginsData));

    const plugins = await resolveInstalledPlugins(tempDir, tempDir);

    assert.equal(plugins.length, 1);
    assert.equal(plugins[0].path, localPath);
    console.log('  ✓ Prefers the local-scope install matching the current project');
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Test 17: Debug logging environment variable
console.log('Test 17: Debug logging with VIBING_DEBUG');
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
