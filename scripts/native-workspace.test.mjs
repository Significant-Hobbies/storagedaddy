import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('native cleanup safeguards, exclusions and packaged UI resources', { timeout: 118_000 }, () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const result = spawnSync('npx', [
    '--offline', 'xcodebuildmcp', 'swift-package', 'test', '--package-path', root,
    '--filter', 'CleanupBatchTests|StorageUIResourcesTests|FolderExclusion|StorageWorkspace', '--parallel', 'false',
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
  assert.ok(Number(summary[1]) >= 10, 'Cleanup, exclusions and UI resource checks must execute');
  assert.equal(Number(summary[2]), 0);
});
