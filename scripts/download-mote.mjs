#!/usr/bin/env node

/**
 * Download mote binaries from GitHub Releases
 * Supports: darwin-arm64, darwin-x64, linux-arm64, linux-x64
 */

import fs from 'fs';
import path from 'path';
import https from 'https';
import { spawn } from 'child_process';

const MOTE_VERSION = 'v0.1.1';
const MOTE_REPO = 'shabaraba/mote';
const BIN_DIR = path.join(process.cwd(), 'bin');

// Platform mapping: Node.js platform/arch -> mote release asset name
const PLATFORM_MAP = {
  'darwin-arm64': 'aarch64-apple-darwin',
  'darwin-x64': 'x86_64-apple-darwin',
  'linux-arm64': 'aarch64-unknown-linux-gnu',
  'linux-x64': 'x86_64-unknown-linux-gnu',
};

function getPlatformKey() {
  const platform = process.platform;
  const arch = process.arch;
  return `${platform}-${arch}`;
}

function getAssetName(platformKey) {
  const target = PLATFORM_MAP[platformKey];
  if (!target) {
    throw new Error(`Unsupported platform: ${platformKey}`);
  }
  return `mote-${MOTE_VERSION}-${target}.tar.gz`;
}

function downloadFile(url, maxRedirects = 5, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { 'User-Agent': 'vibing.nvim' } }, (res) => {
        if (res.statusCode === 302 || res.statusCode === 301) {
          // Follow redirect
          if (redirectCount >= maxRedirects) {
            reject(new Error(`Too many redirects (max: ${maxRedirects})`));
            return;
          }
          if (!res.headers.location) {
            reject(new Error('Redirect without Location header'));
            return;
          }
          downloadFile(res.headers.location, maxRedirects, redirectCount + 1)
            .then(resolve)
            .catch(reject);
          return;
        }
        if (res.statusCode !== 200) {
          reject(new Error(`HTTP ${res.statusCode}: ${url}`));
          return;
        }
        resolve(res);
      })
      .on('error', reject);
  });
}

async function downloadAndExtract(platformKey) {
  const assetName = getAssetName(platformKey);
  const url = `https://github.com/${MOTE_REPO}/releases/download/${MOTE_VERSION}/${assetName}`;
  const outputPath = path.join(BIN_DIR, `mote-${platformKey}`);
  const tmpDir = path.join(BIN_DIR, '.tmp');
  const tarPath = path.join(tmpDir, assetName);

  console.log(`[vibing.nvim] Downloading mote binary for ${platformKey}...`);
  console.log(`[vibing.nvim]   URL: ${url}`);

  // Create directories
  if (!fs.existsSync(BIN_DIR)) {
    fs.mkdirSync(BIN_DIR, { recursive: true });
  }
  if (!fs.existsSync(tmpDir)) {
    fs.mkdirSync(tmpDir, { recursive: true });
  }

  // Download tar.gz
  const response = await downloadFile(url);
  const fileStream = fs.createWriteStream(tarPath);
  await new Promise((resolve, reject) => {
    response.pipe(fileStream);
    response.on('error', reject);
    fileStream.on('finish', resolve);
    fileStream.on('error', reject);
  });

  // Extract using tar command (safe with argument array)
  await new Promise((resolve, reject) => {
    const tar = spawn('tar', ['-xzf', tarPath, '-C', tmpDir]);
    tar.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`tar extraction failed with code ${code}`));
      } else {
        resolve();
      }
    });
    tar.on('error', reject);
  });

  // Find mote binary using recursive directory walk
  function findMoteRecursive(dir) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        const found = findMoteRecursive(fullPath);
        if (found) return found;
      } else if (entry.name === 'mote') {
        return fullPath;
      }
    }
    return null;
  }

  const motePath = findMoteRecursive(tmpDir);
  if (!motePath || !fs.existsSync(motePath)) {
    throw new Error('mote binary not found in tar.gz');
  }

  // Move to final location with cross-filesystem fallback
  try {
    fs.renameSync(motePath, outputPath);
  } catch (err) {
    // Cross-filesystem move: copy then unlink
    if (err.code === 'EXDEV') {
      fs.copyFileSync(motePath, outputPath);
      fs.unlinkSync(motePath);
    } else {
      throw err;
    }
  }
  fs.chmodSync(outputPath, 0o755);

  // Cleanup
  fs.rmSync(tmpDir, { recursive: true, force: true });

  console.log(`[vibing.nvim] ✓ Downloaded: ${outputPath}`);
}

async function downloadAllPlatforms() {
  console.log('[vibing.nvim] Downloading mote binaries for all platforms...\n');

  for (const platformKey of Object.keys(PLATFORM_MAP)) {
    try {
      await downloadAndExtract(platformKey);
    } catch (error) {
      console.error(`[vibing.nvim] ✗ Failed to download ${platformKey}: ${error.message}`);
      process.exit(1);
    }
  }

  console.log('\n[vibing.nvim] ✓ All mote binaries downloaded successfully!');
}

// Check if --current-platform flag is provided
const currentPlatformOnly = process.argv.includes('--current-platform');

if (currentPlatformOnly) {
  const platformKey = getPlatformKey();
  downloadAndExtract(platformKey).catch((error) => {
    console.error(`[vibing.nvim] ✗ Failed: ${error.message}`);
    process.exit(1);
  });
} else {
  downloadAllPlatforms().catch((error) => {
    console.error(`[vibing.nvim] ✗ Failed: ${error.message}`);
    process.exit(1);
  });
}
