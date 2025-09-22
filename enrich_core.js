// enrich_core.js
// Usage: node enrich_core.js therapy_advice.json
const fs = require('fs');

const INPUT = process.argv[2] || 'data/therapy_advice.json';
const OUTPUT = INPUT.replace(/\.json$/,'') + '.enriched.json';

// ---------- 1) Canonical Core Contexts (your list) ----------
const CORE_CONTEXTS = new Set([
  // Conflict & Resolution
  'conflict','escalation','repair','rupture','rupture_repair','micro-apology','apology',
  // Relationship Dynamics
  'general','boundaries','boundary','power_imbalance','validation','safety',
  // Emotional States
  'insecurity','jealousy','jealousy_comparison','comparison','longing','hesitation',
  // Connection & Intimacy
  'intimacy','presence','co-regulation','co_regulation','vulnerability_disclosure','disclosure',
  // Specific Areas
  'co-parenting','parenting','planning','praise','invisible_labor','mental_health_checkin'
]);

// normalize aliases → your canonical spellings
const CONTEXT_ALIASES = {
  'co-regulation': 'co_regulation',
  'co regulation': 'co_regulation',
  'coregulation': 'co_regulation',
  'micro_apology': 'micro-apology',
  'microapology': 'micro-apology',
  'co-parenting': 'co-parenting', // (already canonical but caught by hyphen/space checks)
};

// ---------- 2) Light heuristics from ID ranges/prefixes ----------
const RANGE_HINTS = [
  [1,100, 'conflict'],                 // de-escalation
  [126,150,'boundaries'],
  [151,190,'escalation'],
  [191,240,'rupture'],
  [241,299,'repair'],
  [300,340,'repair'],                  // text micro-repairs
  [341,440,'planning'],
  [441,520,'vulnerability_disclosure'],
  [521,540,'hesitation'],
  [541,560,'insecurity'],
  [561,580,'validation'],
  [581,640,'praise'],
  [641,649,'praise'],
  [650,655,'praise'],
  [656,699,'intimacy'],                // co-reg + physical closeness
  [700,746,'presence'],
  [747,775,'co_regulation'],
  [776,799,'jealousy'],
  [850,856,'comparison'],
  [857,920,'parenting'],               // + co-parenting later splits by keywords
  [921,940,'co-parenting'],
  [941,980,'power_imbalance'],
  [981,1005,'invisible_labor'],
];

const PREFIX_HINTS = {
  'TA_CONFLICT_': 'conflict',
  'TA_REPAIR_': 'repair',
  'TA_PLANNING_': 'planning',
  'TA_ESCALATION_': 'escalation',
  'TA_SAFETY_': 'safety',
  'TA_BOUNDARY_': 'boundaries',
  'TA_APOLOGY_': 'apology',
  'TA_COREG_': 'co_regulation',
  'TA_RUPTURE_': 'rupture',
  'TA_JEALOUSY_': 'jealousy',
  'TA_VULN_': 'vulnerability_disclosure'
};

// ---------- 3) Keyword rules → core contexts ----------
const RULES = [
  ['conflict',             ['heated','fight','argu','tone','voices','de-escalat','escalat']],
  ['escalation',           ['yell','spiral','ramp','pause','reset','break','slow down']],
  ['repair',               ['repair','reconnect','reset','amends','make it right','together']],
  ['rupture',              ['rupture','broke','distance','trust','wall','disconnect','rejection','shut out','cut off','abandoned']],
  ['rupture_repair',       ['repair after rupture','mend','rebuild','restore closeness']],
  ['micro-apology',        ['sorry for the tone','micro-apolog','micro apology']],
  ['apology',              ['sorry','apolog','forgive','amends','i was wrong']],

  ['boundaries',           ['boundary','limit','i can\'t','i cant',"doesn't work for me","won't discuss","no,"]],
  ['boundary',             ['boundary','limit','i can\'t','i cant','no,']], // keep both spellings if you want both
  ['power_imbalance',      ['power','dominan','veto','overrule','tie-break','decision rights']],
  ['validation',           ['validation','acknowledg','recognition','seen','appreciate that i']], // requester
  ['safety',               ['safe','unsafe','leave now','i need help','i don\'t feel safe']],

  ['insecurity',           ['unlovable','not enough','replaceable','disappoint','worth','self-doubt']],
  ['jealousy',             ['jealous','left out','reassur','rival','threat']],
  ['jealousy_comparison',  ['compare','comparison','someone better']],
  ['comparison',           ['compare','comparison']],
  ['longing',              ['miss you','yearn','ache','longing','distance feels heavy']],
  ['hesitation',           ['hesitate','freeze','pause to think','uncertain','searching for words']],

  ['intimacy',             ['touch','closeness','cuddle','affection','intimate','snuggle']],
  ['presence',             ['present','attention','phones down','undivided','eye contact']],
  ['co_regulation',        ['co-reg','co regulate','shared breath','synchronize breath','hand on heart','grounding together']],
  ['vulnerability_disclosure',['vulnerab','confidential','consent','share something tender','disclose']],
  ['disclosure',           ['disclose','share privately']],

  ['co-parenting',         ['co-parent','handoff','custody','two homes','pickup','teacher communications']],
  ['parenting',            ['child','parenting','discipline','homework','routine','bedtime']],
  ['planning',             ['meet','time','schedule','calendar','option','confirm','invite']],
  ['praise',               ['appreciate','gratitude','thank','noticed','kindness','steadiness','admire']],
  ['invisible_labor',      ['invisible labor','default parent','mental load','unseen work','backstage']],
  ['mental_health_checkin',['check-in','mental health','how are you really','scale 0–10']]
];

// ---------- helpers ----------
function parseId(rawId) {
  if (!rawId) return {};
  for (const pfx of Object.keys(PREFIX_HINTS)) {
    if (rawId.startsWith(pfx)) return { prefix: pfx, num: null };
  }
  const m = rawId.match(/^TA(\d{1,4})$/);
  return { prefix: null, num: m ? parseInt(m[1],10) : null };
}

function add(set, value) {
  if (!value) return;
  const v = CONTEXT_ALIASES[value] || value; // normalize alias
  if (CORE_CONTEXTS.has(v)) set.add(v);
}

function contextsFromRange(n) {
  if (n == null) return [];
  for (const [a,b,ctx] of RANGE_HINTS) {
    if (n>=a && n<=b) return [ctx];
  }
  return [];
}

function contextsFromPrefix(pfx) {
  if (!pfx) return [];
  return [PREFIX_HINTS[pfx]].filter(Boolean);
}

function contextsFromKeywords(text) {
  const t = (text||'').toLowerCase();
  const hits = new Set();
  for (const [ctx, kws] of RULES) {
    if (kws.some(k => t.includes(k))) add(hits, ctx);
  }
  // disambiguate co-parenting vs parenting if both appeared
  if (hits.has('co-parenting') && hits.has('parenting')) hits.delete('parenting');
  // jealousy + comparison → prefer jealousy_comparison if present
  if (hits.has('jealousy') && hits.has('jealousy_comparison')) hits.delete('jealousy');
  return Array.from(hits);
}

function ensureAtLeastGeneral(set) {
  if (set.size === 0) set.add('general');
}

// ---------- optional: keep earlier secondary fields ----------
function deriveIntents(coreContexts) {
  const map = {
    conflict: ['deescalate','clarify'],
    escalation: ['interrupt_spiral','deescalate'],
    repair: ['reconnect','offer_repair'],
    rupture: ['name_rupture'],
    rupture_repair: ['offer_repair'],
    'micro-apology': ['accountability'],
    apology: ['accountability'],
    boundaries: ['set_boundary','protect_capacity'],
    boundary: ['set_boundary','protect_capacity'],
    power_imbalance: ['balance_power','set_process'],
    validation: ['request_validation'],
    safety: ['protect_safety'],
    insecurity: ['request_reassurance'],
    jealousy: ['request_reassurance'],
    jealousy_comparison: ['request_reassurance'],
    comparison: ['set_boundary'],
    longing: ['request_closeness'],
    hesitation: ['ask_for_time'],
    intimacy: ['request_closeness'],
    presence: ['request_presence'],
    co_regulation: ['co_regulate'],
    vulnerability_disclosure: ['disclose','ask_consent'],
    disclosure: ['disclose'],
    'co-parenting': ['align_logistics'],
    parenting: ['align_parenting'],
    planning: ['plan','confirm'],
    praise: ['express_gratitude'],
    invisible_labor: ['seek_ack','rebalance_work'],
    mental_health_checkin: ['check_in']
  };
  const out = new Set();
  coreContexts.forEach(c => (map[c]||[]).forEach(i => out.add(i)));
  return Array.from(out);
}

function deriveTags(text, coreContexts) {
  const t = (text||'').toLowerCase();
  const tags = new Set(coreContexts.map(c => `ctx:${c}`));
  if (/text|thread|message|emoji|ping|invite/i.test(text)) tags.add('texting');
  if (/breath|exhale|body|shoulder|touch/i.test(text)) tags.add('somatic');
  if (/calendar|invite|schedule|time|meeting/i.test(text)) tags.add('logistics');
  if (/child|parent|school|teacher|custody/i.test(text)) tags.add('family');
  if (/trust|rupture|repair/i.test(text)) tags.add('trust');
  if (/boundary|no |limit/i.test(text)) tags.add('boundary');
  if (/check[- ]?in|scale 0/.test(t)) tags.add('check-in');
  return Array.from(tags);
}

function deriveTone(text) {
  const t = (text||'').toLowerCase();
  if (t.includes('sorry') || t.includes('apolog')) return 'accountable';
  if (t.includes('pause') || t.includes('breathe') || t.includes('slow')) return 'calm';
  if (t.includes('safe') || t.includes('leave now')) return 'protective';
  if (t.includes('thank') || t.includes('appreciat')) return 'warm';
  if (t.includes('no ') || t.includes("doesn't work")) return 'firm';
  return 'neutral';
}

// ---------- main enrich ----------
function enrich(items) {
  return items.map(raw => {
    const item = { ...raw };
    const { prefix, num } = parseId(item.id);

    const ctxSet = new Set();
    contextsFromPrefix(prefix).forEach(c => add(ctxSet, c));
    contextsFromRange(num).forEach(c => add(ctxSet, c));
    contextsFromKeywords(item.advice).forEach(c => add(ctxSet, c));

    // final normalization + fallback
    // (alias pass already in add(); here ensure only allowed values)
    const finalCore = Array.from(ctxSet).filter(c => CORE_CONTEXTS.has(c));
    if (finalCore.length === 0) finalCore.push('general');

    // optional secondary fields (keep or remove as you wish)
    const intents = deriveIntents(finalCore);
    const triggerTone = deriveTone(item.advice);
    const tags = deriveTags(item.advice, finalCore);

    // merge without overwriting existing labels if present
    item.core_contexts = Array.from(new Set([...(item.core_contexts||[]), ...finalCore]));
    item.intents = Array.from(new Set([...(item.intents||[]), ...intents]));
    item.triggerTone = item.triggerTone || triggerTone;
    item.tags = Array.from(new Set([...(item.tags||[]), ...tags]));

    return item;
  });
}

// ---------- run ----------
try {
  const src = fs.readFileSync(INPUT,'utf8');
  const arr = JSON.parse(src);
  if (!Array.isArray(arr)) throw new Error('Input must be an array');

  const enriched = enrich(arr);

  // quick counts
  const stat = {};
  for (const it of enriched) for (const c of it.core_contexts||[]) stat[c]=(stat[c]||0)+1;

  fs.writeFileSync(OUTPUT, JSON.stringify(enriched, null, 2));
  console.log(`✅ Wrote ${enriched.length} items → ${OUTPUT}`);
  console.log('— Core Context counts —');
  Object.entries(stat).sort((a,b)=>b[1]-a[1]).forEach(([k,v])=>console.log(`${k}: ${v}`));
} catch (e) {
  console.error('❌ Failed:', e.message);
  process.exit(1);
}