/**
 * GBrain CMRC/DRCD Benchmark
 * Imports passages into fresh PGLite DBs, runs hybrid queries, measures Hit@1/3/5/10.
 * Usage: GEMINI_API_KEY=... bun run gbrain-cmrc-drcd-benchmark.ts
 */

import { PGLiteEngine } from '/home/oldrabbit/gbrain/src/core/pglite-engine.ts';
import { embedBatch } from '/home/oldrabbit/gbrain/src/core/embedding.ts';
import { rrfFusion } from '/home/oldrabbit/gbrain/src/core/search/hybrid.ts';
import { dedupResults } from '/home/oldrabbit/gbrain/src/core/search/dedup.ts';
import { runEmbedCore } from '/home/oldrabbit/gbrain/src/commands/embed.ts';
import * as fs from 'fs';
import * as path from 'path';
import Database from 'bun:sqlite';

const CHUNK_MAX = 400;
const K_VALUES = [1, 3, 5, 10];
const RRF_K = 60;

// Separate DB paths for each dataset
const CMRC_DB_PATH = '/tmp/gbrain-cmrc-bench/brain.pglite';
const DRCD_DB_PATH = '/tmp/gbrain-drcd-bench/brain.pglite';
const CMRC_JSON = '/tmp/cmrc2018_dev.json';
const DRCD_JSON = '/tmp/DRCD_test.json';
const OUT_DIR = '/home/oldrabbit/.claude-bots/bots/anna/staging';

// ── Text chunking (same logic as MemOcean benchmark) ──────────────────────────

function splitContext(context: string, maxLen = CHUNK_MAX): Array<[number, number, string]> {
  const parts = context.split(/(?<=[。！？\n])/);
  const chunks: Array<[number, number, string]> = [];
  let cur = '';
  let curStart = 0;

  for (const part of parts) {
    if (!part) continue;
    if (cur.length + part.length <= maxLen) {
      cur += part;
    } else {
      if (cur) {
        chunks.push([curStart, curStart + cur.length, cur]);
        curStart += cur.length;
      }
      let remaining = part;
      while (remaining.length > maxLen) {
        chunks.push([curStart, curStart + maxLen, remaining.slice(0, maxLen)]);
        curStart += maxLen;
        remaining = remaining.slice(maxLen);
      }
      cur = remaining;
    }
  }
  if (cur) chunks.push([curStart, curStart + cur.length, cur]);
  return chunks;
}

// ── Dataset parsing ────────────────────────────────────────────────────────────

interface ParsedDataset {
  rows: Array<{ slug: string; title: string; text: string }>;
  qaPairs: Array<{ question: string; goldSlugs: string[] }>;
}

function parseSquadStyle(jsonPath: string, slugPrefix: string): ParsedDataset {
  const data = JSON.parse(fs.readFileSync(jsonPath, 'utf-8'));
  const rows: Array<{ slug: string; title: string; text: string }> = [];
  const qaPairs: Array<{ question: string; goldSlugs: string[] }> = [];

  for (const article of data.data) {
    const title = article.title || '';
    for (const para of article.paragraphs || []) {
      const paraId = para.id || '';
      const context = para.context || '';
      const chunks = splitContext(context);

      const paraRows: Array<{ slug: string; start: number; end: number }> = [];
      for (let idx = 0; idx < chunks.length; idx++) {
        const [start, end, text] = chunks[idx];
        const slug = `${slugPrefix}_${paraId}_${idx}`.toLowerCase();
        paraRows.push({ slug, start, end });
        rows.push({ slug, title, text });
      }

      for (const qa of para.qas || []) {
        const question = qa.question || '';
        const answers = qa.answers || [];
        if (!answers.length) continue;

        const goldSlugs: string[] = [];
        for (const ans of answers) {
          const ansStart = ans.answer_start ?? -1;
          if (ansStart < 0) continue;
          for (const { slug, start, end } of paraRows) {
            if (start <= ansStart && ansStart < end) {
              if (!goldSlugs.includes(slug)) goldSlugs.push(slug);
              break;
            }
          }
        }
        if (goldSlugs.length) qaPairs.push({ question, goldSlugs });
      }
    }
  }

  return { rows, qaPairs };
}

// ── Benchmark runner ──────────────────────────────────────────────────────────

interface BenchResult {
  dataset: string;
  total: number;
  evaluated: number;
  hit_at_1: number;
  hit_at_3: number;
  hit_at_5: number;
  hit_at_10: number;
  run_at: string;
  p95_latency_ms: number;
  cost_note: string;
}

async function runBenchmark(
  datasetName: string,
  jsonPath: string,
  slugPrefix: string,
  dbPath: string,
  rawOutPath: string,
): Promise<BenchResult> {
  console.log(`\n=== ${datasetName} Benchmark ===`);

  // Parse dataset
  console.log('Parsing dataset...');
  const { rows, qaPairs } = parseSquadStyle(jsonPath, slugPrefix);
  console.log(`  ${rows.length} passages, ${qaPairs.length} QA pairs`);

  // Create fresh DB
  console.log(`Creating DB at ${dbPath}...`);
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  if (fs.existsSync(dbPath)) {
    fs.rmSync(dbPath, { recursive: true, force: true });
    console.log('  Cleared existing DB');
  }

  const engine = new PGLiteEngine();
  await engine.connect({ engine: 'pglite', database_path: dbPath });
  await engine.initSchema();
  console.log('  DB initialized');

  // Import passages
  console.log('Importing passages...');
  let imported = 0;
  for (const { slug, title, text } of rows) {
    await engine.putPage(slug, {
      type: 'source',
      title,
      compiled_truth: text,
    });
    await engine.upsertChunks(slug, [{ chunk_index: 0, chunk_text: text, chunk_source: 'compiled_truth' }]);
    imported++;
    if (imported % 200 === 0) console.log(`  ${imported}/${rows.length} passages imported`);
  }
  console.log(`  All ${imported} passages imported`);

  // Embed all passages (stale embed)
  console.log('Embedding passages...');
  const embedStart = Date.now();
  await runEmbedCore(engine, { stale: true });
  console.log(`  Embedding done in ${((Date.now() - embedStart) / 1000).toFixed(1)}s`);

  // Pre-embed all query texts in batches
  console.log('Pre-embedding queries...');
  const queryTexts = qaPairs.map(qa => qa.question);
  const queryEmbedStart = Date.now();
  const queryEmbeddings: Float32Array[] = await embedBatch(queryTexts);
  console.log(`  Query embedding done in ${((Date.now() - queryEmbedStart) / 1000).toFixed(1)}s, ${queryEmbeddings.length} vectors`);

  // Run search for each QA pair
  console.log('Running hybrid queries...');
  const latencies: number[] = [];
  const hits = { 1: 0, 3: 0, 5: 0, 10: 0 };
  const rawResults: any[] = [];

  for (let i = 0; i < qaPairs.length; i++) {
    const { question, goldSlugs } = qaPairs[i];
    const queryEmb = queryEmbeddings[i];

    const qStart = Date.now();

    // Keyword search
    const kwResults = await engine.searchKeyword(question, { limit: 20 });

    // Vector search with pre-computed embedding
    const vecResults = await engine.searchVector(queryEmb, { limit: 20 });

    // RRF fusion
    const fused = rrfFusion([vecResults, kwResults], RRF_K, true);
    const deduped = dedupResults(fused).slice(0, 10);

    const latency = Date.now() - qStart;
    latencies.push(latency);

    const retrievedSlugs = deduped.map(r => r.slug);

    // Check hits at each k
    for (const k of K_VALUES) {
      const topK = retrievedSlugs.slice(0, k);
      const hit = goldSlugs.some(gs => topK.includes(gs));
      if (hit) hits[k as keyof typeof hits]++;
    }

    rawResults.push({
      id: `${slugPrefix}_q${i}`,
      question,
      gold_slugs: goldSlugs,
      top_10: retrievedSlugs,
      hit_at_1: goldSlugs.some(gs => retrievedSlugs.slice(0, 1).includes(gs)),
      hit_at_3: goldSlugs.some(gs => retrievedSlugs.slice(0, 3).includes(gs)),
      hit_at_5: goldSlugs.some(gs => retrievedSlugs.slice(0, 5).includes(gs)),
      hit_at_10: goldSlugs.some(gs => retrievedSlugs.slice(0, 10).includes(gs)),
      latency_ms: latency,
    });

    if ((i + 1) % 500 === 0) {
      const pct5 = ((hits[5] / (i + 1)) * 100).toFixed(1);
      console.log(`  ${i + 1}/${qaPairs.length} queries done, running Hit@5=${pct5}%`);
    }
  }

  await engine.disconnect();

  // Compute latency p95
  const sorted = [...latencies].sort((a, b) => a - b);
  const p95 = sorted[Math.floor(sorted.length * 0.95)];

  const total = qaPairs.length;
  const result: BenchResult = {
    dataset: datasetName,
    total,
    evaluated: total,
    hit_at_1: hits[1] / total,
    hit_at_3: hits[3] / total,
    hit_at_5: hits[5] / total,
    hit_at_10: hits[10] / total,
    run_at: new Date().toISOString(),
    p95_latency_ms: p95,
    cost_note: 'Gemini gemini-embedding-001 free tier; query embeddings pre-computed in batch',
  };

  // Write raw results
  fs.writeFileSync(rawOutPath, JSON.stringify({ summary: result, results: rawResults }, null, 2));
  console.log(`  Raw results → ${rawOutPath}`);

  console.log(`\n${datasetName} Results:`);
  console.log(`  Hit@1:  ${(result.hit_at_1 * 100).toFixed(1)}%`);
  console.log(`  Hit@3:  ${(result.hit_at_3 * 100).toFixed(1)}%`);
  console.log(`  Hit@5:  ${(result.hit_at_5 * 100).toFixed(1)}%`);
  console.log(`  Hit@10: ${(result.hit_at_10 * 100).toFixed(1)}%`);
  console.log(`  p95 latency: ${p95}ms`);

  return result;
}

// ── Main ──────────────────────────────────────────────────────────────────────

const cmrcResult = await runBenchmark(
  'CMRC 2018 dev split',
  CMRC_JSON,
  'cmrc',
  CMRC_DB_PATH,
  path.join(OUT_DIR, 'gbrain-cmrc-raw.json'),
);

const drcdResult = await runBenchmark(
  'DRCD v2 test split',
  DRCD_JSON,
  'drcd',
  DRCD_DB_PATH,
  path.join(OUT_DIR, 'gbrain-drcd-raw.json'),
);

// Write summary
const summary = { cmrc: cmrcResult, drcd: drcdResult };
fs.writeFileSync(path.join(OUT_DIR, 'gbrain-cmrc-drcd-summary.json'), JSON.stringify(summary, null, 2));

console.log('\n=== Final Summary ===');
console.log('CMRC:', JSON.stringify({ hit_at_1: cmrcResult.hit_at_1.toFixed(4), hit_at_5: cmrcResult.hit_at_5.toFixed(4) }));
console.log('DRCD:', JSON.stringify({ hit_at_1: drcdResult.hit_at_1.toFixed(4), hit_at_5: drcdResult.hit_at_5.toFixed(4) }));
