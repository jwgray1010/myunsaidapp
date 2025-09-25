const fs = require('fs');

// Read the current file
const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));

// UI bucket tones vs Raw tones
const UI_BUCKETS = new Set(['alert', 'caution', 'clear', 'neutral']);
const RAW_TONES = new Set([
  'neutral', 'positive', 'supportive', 'anxious', 'angry', 'frustrated', 'sad', 
  'assertive', 'safety_concern', 'withdrawn', 'apologetic', 'curious', 'dismissive', 
  'defensive', 'jealous_insecure', 'catastrophizing', 'minimization', 'playful', 
  'reflective', 'logistical', 'confused_ambivalent'
]);

let fixCount = 0;

// Process each entry to fix triggerTone/rawTone separation
data.forEach(entry => {
  if (entry.triggerTone && Array.isArray(entry.triggerTone)) {
    const uiBuckets = [];
    const rawTones = entry.rawTone ? [...entry.rawTone] : [];
    
    entry.triggerTone.forEach(tone => {
      if (UI_BUCKETS.has(tone)) {
        uiBuckets.push(tone);
      } else if (RAW_TONES.has(tone)) {
        if (rawTones.indexOf(tone) === -1) {
          rawTones.push(tone);
        }
        fixCount++;
      } else {
        uiBuckets.push(tone); // Keep unknown tones in triggerTone for safety
      }
    });
    
    entry.triggerTone = uiBuckets;
    if (rawTones.length > 0) {
      entry.rawTone = rawTones;
    }
  }
});

console.log(`🔧 Fixed ${fixCount} tone separation issues`);

// Format with compact style like TA_NEGOTIATION_ALERT_172
function formatCompact(obj) {
  if (Array.isArray(obj)) {
    return '[' + obj.map(item => JSON.stringify(item)).join(',') + ']';
  } else if (obj && typeof obj === 'object') {
    const entries = Object.entries(obj).map(([k, v]) => JSON.stringify(k) + ': ' + JSON.stringify(v));
    return '{' + entries.join(',') + '}';
  }
  return JSON.stringify(obj);
}

// Write formatted output
let output = '[\n';
data.forEach((entry, index) => {
  output += '  {\n';
  Object.entries(entry).forEach(([key, value], keyIndex) => {
    const isLast = keyIndex === Object.entries(entry).length - 1;
    const formatted = formatCompact(value);
    output += `    "${key}": ${formatted}${isLast ? '' : ','}\n`;
  });
  output += '  }' + (index === data.length - 1 ? '' : ',') + '\n';
});
output += ']';

fs.writeFileSync('data/therapy_advice.json', output, 'utf8');
console.log('✅ Applied compact formatting like TA_NEGOTIATION_ALERT_172 to entire file');