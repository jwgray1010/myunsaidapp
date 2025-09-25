#!/usr/bin/env node
/**
 * add-raw-tone.js
 * Adds a `rawTone` (one of: neutral, positive, supportive, anxious, angry, frustrated, sad, assertive, safety_concern)
 * next to `triggerTone` (alert|caution|clear) for each advice item.
 *
 * Usage:
 *   node add-raw-tone.js --in therapy_advice.json --out therapy_advice.with_raw.json
 *   node add-raw-tone.js --in advice.json --out out.json --map id_to_rawtone.json
 *   node add-raw-tone.js --in advice.json --out out.json --mode placeholder
 *   node add-raw-tone.js --in advice.json --out out.json --force
 *
 * Notes:
 * - Input can be an array or { items: [...] }.
 * - Won’t overwrite existing `rawTone` unless --force.
 */

import fs from 'fs';
import path from 'path';

const RAW_TONES = new Set([
  'neutral','positive','supportive','anxious','angry','frustrated','sad','assertive','safety_concern'
]);

const argv = Object.fromEntries(
  process.argv.slice(2).map(a => {
    const [k, ...rest] = a.split('=');
    if (k.startsWith('--')) return [k.slice(2), rest.join('=') || true];
    return [k, true];
  })
);

const inPath = argv.in || argv.input;
const outPath = argv.out || argv.output || (inPath ? autoOutPath(inPath) : null);
const mapPath = argv.map || null;
const mode = (argv.mode || 'auto').toLowerCase(); // 'auto' | 'placeholder'
const force = !!argv.force;

if (!inPath || !outPath) {
  console.error('Usage: node add-raw-tone.js --in <input.json> --out <output.json> [--map id_to_rawtone.json] [--mode auto|placeholder] [--force]');
  process.exit(1);
}

function autoOutPath(p) {
  const dir = path.dirname(p);
  const base = path.basename(p, path.extname(p));
  return path.join(dir, `${base}.with_raw${path.extname(p) || '.json'}`);
}

// ---------- Load input ----------
let data;
try {
  data = JSON.parse(fs.readFileSync(inPath, 'utf8'));
} catch (e) {
  console.error(`Failed to read/parse ${inPath}:`, e.message);
  process.exit(1);
}

// Support array or { items: [...] }
const rootIsArray = Array.isArray(data);
const items = rootIsArray ? data : Array.isArray(data.items) ? data.items : null;
if (!items) {
  console.error('Input must be a JSON array or an object with an `items` array.');
  process.exit(1);
}

// ---------- Optional ID->rawTone map ----------
let idMap = {};
if (mapPath) {
  try {
    idMap = JSON.parse(fs.readFileSync(mapPath, 'utf8'));
  } catch (e) {
    console.error(`Failed to read/parse map file ${mapPath}:`, e.message);
    process.exit(1);
  }
}

// ---------- Keyword banks ----------
const KW = {
  safety: /\b(safety|safe|unsafe|harm|self-?harm|emergency|crisis|suicide|danger|threat)\b/i,
  angry: /\b(angry|mad|furious|rage|irritated|pissed|resent|blame)\b/i,
  frustrated: /\b(frustrated|stuck|fed up|tired of|exhausted|over it|impatient)\b/i,
  sad: /\b(sad|hurt|disappointed|grief|grieving|cry|tears|lonely|loss|ashamed|guilt|guilty)\b/i,
  anxious: /\b(anxious|worried|scared|afraid|nervous|panic|panicky|uncertain|unsure|fear)\b/i,
  supportive: /\b(support|with you|here for|together|listen(?:ing)?|validate|understand|empathy|encourage|reassur)\w*/i,
  positive: /\b(appreciate|grateful|gratitude|thank|proud|celebrate|glad|happy|warm)\b/i,
  assertive: /\b(boundary|not ok(?:ay)?|not okay|unacceptable|i need\b|i want\b|request|ask that you|please do not|no[.! ]|hold on)\b/i,
  crisisCtx: /(crisis|safety|emergency|safety_check|emergency_deescalation|selfharm|suicide|danger)/i
};

// ---------- Heuristic classifier ----------
function chooseRawTone(item) {
  const trig = String(item.triggerTone || '').toLowerCase(); // alert|caution|clear
  const contexts = Array.isArray(item.contexts) ? item.contexts.join(' ').toLowerCase() : '';
  const advice = String(item.advice || '');
  const text = `${advice} ${contexts}`;

  // Strong signals first
  if (KW.safety.test(text) || KW.crisisCtx.test(text)) return 'safety_concern';
  if (KW.angry.test(text)) return 'angry';
  if (KW.frustrated.test(text)) return 'frustrated';
  if (KW.sad.test(text)) return 'sad';
  if (KW.anxious.test(text)) return 'anxious';
  if (KW.assertive.test(text)) return 'assertive';
  if (KW.supportive.test(text)) return 'supportive';
  if (KW.positive.test(text)) return 'positive';

  // Fallback by triggerTone
  if (trig === 'alert') return 'anxious';
  if (trig === 'caution') return 'neutral';
  return 'neutral'; // clear → neutral by default
}

// ---------- Transform ----------
let added = 0, skipped = 0, overwritten = 0, mapped = 0;

const transformed = items.map((orig) => {
  const o = (orig && typeof orig === 'object') ? orig : {};
  const id = o.id || '';

  // Respect existing rawTone unless --force
  if (o.rawTone && !force) { skipped++; return o; }

  // From explicit ID map?
  if (id && idMap[id]) {
    const tone = String(idMap[id]).toLowerCase();
    if (!RAW_TONES.has(tone)) {
      console.warn(`⚠️  Map value for ${id} is not a valid rawTone: ${idMap[id]}`);
    } else {
      mapped++;
      return insertRawToneNextToTrigger(o, tone);
    }
  }

  // Mode handling
  let tone = '';
  if (mode === 'placeholder') {
    tone = '';
  } else {
    tone = chooseRawTone(o);
  }

  if (o.rawTone && force) overwritten++;
  else if (!o.rawTone) added++;

  return insertRawToneNextToTrigger(o, tone);
});

// Insert `rawTone` after `triggerTone` key (best effort, order not guaranteed by JSON spec, but we recreate object)
function insertRawToneNextToTrigger(obj, rawTone) {
  const result = {};
  const keys = Object.keys(obj);
  let inserted = false;
  for (const k of keys) {
    result[k] = obj[k];
    if (k === 'triggerTone') {
      result['rawTone'] = rawTone;
      inserted = true;
    }
  }
  if (!inserted) {
    // If no triggerTone field, still add at top for visibility
    return { rawTone, ...obj };
  }
  return result;
}

// ---------- Write out ----------
let outObj = rootIsArray ? transformed : { ...data, items: transformed };
fs.writeFileSync(outPath, JSON.stringify(outObj, null, 2));
console.log(`✅ Wrote ${outPath}`);
console.log(`   Added: ${added}, Mapped: ${mapped}, Overwritten: ${overwritten}${force ? ' (force)': ''}, Skipped existing: ${skipped}`);
