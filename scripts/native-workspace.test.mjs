import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import test from 'node:test';

test('native cleanup safeguards, exclusions and packaged UI resources', { timeout: 118_000 }, () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const result = spawnSync('npx', [
    '--offline', 'xcodebuildmcp', 'swift-package', 'test', '--package-path', root,
    '--filter', 'AgentAccessIntegrationTests|QuickCleanupTests|CleanupBatchTests|CleanupReviewFilterTests|StorageUIResourcesTests|FolderExclusion', '--parallel', 'false',
  ], {
    cwd: root, encoding: 'utf8', timeout: 115_000, maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, STORAGEDADDY_MAC_UI_EVIDENCE: '0', STORAGEDADDY_CLEANUP_SCROLL_EVIDENCE: '0' },
  });
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  process.stdout.write(output);
  assert.ifError(result.error);
  assert.equal(result.status, 0, 'The authoritative XcodeBuildMCP checks failed');
  const summary = output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .match(/(\d+)\s+tests?\s+passed,\s*(\d+)\s+failed/);
  assert.ok(summary, 'XcodeBuildMCP did not report completed native checks');
  assert.ok(Number(summary[1]) >= 16, 'Cleanup, exclusions and UI resource checks must execute');
  assert.equal(Number(summary[2]), 0);
  const logReference = output.match(/Build Logs:\s*(.+\.log)/)?.[1]?.trim();
  assert.ok(logReference, 'Expected the authoritative native test log');
  const logPath = resolve(logReference.startsWith('~/') ? join(homedir(), logReference.slice(2)) : logReference);
  const logRoot = join(homedir(), 'Library/Developer/XcodeBuildMCP/workspaces');
  assert.ok(!relative(logRoot, logPath).startsWith('..'), 'Native log must belong to XcodeBuildMCP');
  const nativeLog = readFileSync(logPath, 'utf8');
  for (const suite of ['AgentAccessIntegrationTests', 'QuickCleanupTests', 'CleanupBatchTests', 'CleanupReviewFilterTests', 'StorageUIResourcesTests', 'FolderExclusionsTests']) {
    assert.match(nativeLog, new RegExp(`Suite ['"]?${suite}['"]? passed`), `Native suite ${suite} did not complete`);
  }
});
