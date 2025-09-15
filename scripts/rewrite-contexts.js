#!/usr/bin/env node
/**
 * One-shot context normalizer for therapy_advice.json
 * - Safely rewrites item.contexts[] to your canonical slugs
 * - Optionally rewrites item.contextLink[] IDs to canonical IDs
 * - Works on JSON array files; also supports NDJSON via --ndjson
 *
 * Usage:
 *   node scripts/rewrite-contexts.js path/to/therapy_advice.json > therapy_advice.normalized.json
 *   # or NDJSON:
 *   node scripts/rewrite-contexts.js --ndjson path/to/advice.jsonl > advice.normalized.jsonl
 */

const fs = require('node:fs');

const args = process.argv.slice(2);
const isNdjson = args[0] === '--ndjson';
const filePath = isNdjson ? args[1] : args[0];
if (!filePath) {
  console.error('Usage: rewrite-contexts.js [--ndjson] <input.json|input.jsonl>');
  process.exit(1);
}

// Context value → canonical slug (based on actual therapy_advice.json patterns)
const CONTEXT_MAP = new Map(Object.entries({
  "micro-apology": "repair",
  "co-regulation": "reassurance", 
  "invisible_labor": "practical",
  "comparison": "jealousy",
  "hesitation": "reassurance",
  "insecurity": "vulnerability",
  "longing": "intimacy",
  "parenting": "co-parenting",
  "power_imbalance": "defense",
  "validation": "praise",
  "rupture": "rupture",
  "co_parenting": "co-parenting"
}));

// Optional: contextLink ID → canonical (based on actual therapy advice patterns)
const CONTEXTLINK_MAP = new Map(Object.entries({
  "CTX_MICRO_APOLOGY": "CTX_REPAIR",
  "CTX_CO_REGULATION": "CTX_REASSURANCE",
  "CTX_INVISIBLE_LABOR": "CTX_PRACTICAL", 
  "CTX_COMPARISON": "CTX_JEALOUSY",
  "CTX_HESITATION": "CTX_REASSURANCE",
  "CTX_INSECURITY": "CTX_VULNERABILITY",
  "CTX_LONGING": "CTX_INTIMACY",
  "CTX_PARENTING": "CTX_CO_PARENTING",
  "CTX_POWER_IMBALANCE": "CTX_DEFENSE",
  "CTX_VALIDATION": "CTX_PRAISE"
}));

function normalizeContexts(arr) {
  if (!Array.isArray(arr)) return arr;
  const out = [];
  const seen = new Set();
  for (const v of arr) {
    if (typeof v !== 'string') { out.push(v); continue; }
    const mapped = CONTEXT_MAP.get(v) || v;
    if (!seen.has(mapped)) { seen.add(mapped); out.push(mapped); }
  }
  return out;
}

function normalizeContextLinks(arr) {
  if (!Array.isArray(arr)) return arr;
  return arr.map(v => (typeof v === 'string' ? (CONTEXTLINK_MAP.get(v) || v) : v));
}

function transformItem(item) {
  if (item && Array.isArray(item.contexts)) {
    item.contexts = normalizeContexts(item.contexts);
  }
  if (item && Array.isArray(item.contextLink)) {
    item.contextLink = normalizeContextLinks(item.contextLink);
  }
  return item;
}

if (isNdjson) {
  const rl = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  const out = rl.map(line => {
    if (!line.trim()) return '';
    try {
      const obj = JSON.parse(line);
      return JSON.stringify(transformItem(obj));
    } catch {
      return line; // leave non-JSON lines untouched
    }
  }).join('\n');
  process.stdout.write(out);
} else {
  const raw = fs.readFileSync(filePath, 'utf8').trim();
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    console.error('Input is not valid JSON. If it is NDJSON, pass --ndjson.');
    process.exit(1);
  }
  if (Array.isArray(data)) {
    const out = data.map(transformItem);
    process.stdout.write(JSON.stringify(out, null, 2));
  } else if (data && typeof data === 'object' && Array.isArray(data.items)) {
    // supports { items: [...] } wrapper
    data.items = data.items.map(transformItem);
    process.stdout.write(JSON.stringify(data, null, 2));
  } else {
    // Single object? Try to transform anyway.
    process.stdout.write(JSON.stringify(transformItem(data), null, 2));
  }
}