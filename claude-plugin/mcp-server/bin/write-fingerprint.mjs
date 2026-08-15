#!/usr/bin/env node
/**
 * Records dist/.build-fingerprint for the checkout build.sh just built.
 *
 * Without this, run.mjs's self-build check never sees build.sh's `tsc` run
 * as a valid build (that check only writes the fingerprint from run.mjs
 * itself), so the first launch of the plugin-cache's run.mjs re-runs
 * `npm ci` — which deletes and replaces the node_modules symlink build.sh
 * set up in the cache with a real copy, defeating the point of the symlink
 * until the next build.sh run re-links it.
 */
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { computeFingerprint, fingerprintFilePath } from './build-fingerprint.mjs';

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), '..');
writeFileSync(fingerprintFilePath(mcpDir), computeFingerprint(mcpDir));
