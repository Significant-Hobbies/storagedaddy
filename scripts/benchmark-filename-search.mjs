// Synthetic local metadata only; never enumerate the owner's files.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const binary = fileURLToPath(new URL('../artifacts/FinderSearchSupport/storage-search', import.meta.url));
const nodes = [{ id: 0, parent: null, name: 'benchmark', kind: 1, size: 0, mtime: 0 }];
const now = Math.floor(Date.now() / 1000);
for (let folder = 0; folder < 100; folder++) {
  const parent = nodes.length;
  nodes.push({ id: parent, parent: 0, name: `project-${folder}`, kind: 1, size: 0, mtime: now });
  for (let i = 0; i < 1000; i++) {
    nodes.push({ id: nodes.length, parent, name: `cache-artifact-${String(folder * 1000 + i).padStart(6, '0')}.bin`, kind: 0, size: 4096, mtime: now });
  }
}
const needle = nodes.length;
nodes.push({ id: needle, parent: 1, name: 'report-quarterly.pdf', kind: 0, size: 200_000_000, mtime: now });
const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: child.stdout });
const iterator = lines[Symbol.asyncIterator]();
const exit = new Promise((resolve, reject) => {
  child.on('error', reject);
  child.on('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`helper exited: ${code ?? signal}`)));
});
const watchdog = setTimeout(() => child.kill(), 20_000);
async function request(fields) {
  const start = performance.now();
  child.stdin.write(JSON.stringify(fields) + '\n');
  const line = await iterator.next();
  assert.equal(line.done, false);
  const reply = JSON.parse(line.value);
  assert.equal(reply.ok, true, reply.error);
  return { reply, roundTripMs: performance.now() - start };
}
function summary(values) {
  const sorted = values.toSorted((a, b) => a - b);
  return { medianMs: sorted[Math.floor(sorted.length / 2)], p95Ms: sorted[Math.ceil(sorted.length * 0.95) - 1] };
}
try {
  const load = await request({ op: 'load', root: '/synthetic/search-benchmark', nodes });
  const queries = [];
  for (const q of ['reprot ext:pdf', 'report ext:pdf size:>100mb', 'ext:pdf mtime:<7d', 'cache']) {
    const roundTrips = [], engine = [];
    for (let i = 0; i < 35; i++) {
      const result = await request({ op: 'search', q, scope: 0 });
      if (q !== 'cache') assert.deepEqual(result.reply.hits.map(hit => hit.id), [needle]);
      else assert.equal(result.reply.hits.length, 201);
      if (i >= 5) { roundTrips.push(result.roundTripMs); engine.push(result.reply.took_us / 1000); }
    }
    queries.push({ q, roundTrip: summary(roundTrips), engine: summary(engine) });
  }
  console.log(JSON.stringify({ entries: nodes.length, loadRoundTripMs: load.roundTripMs, warmRunsPerQuery: 30, queries }));
} finally {
  child.stdin.end();
  await exit;
  clearTimeout(watchdog);
  lines.close();
}
