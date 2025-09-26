const fs = require('fs');

const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));
let converted = 0;

data.forEach(item => {
  // Convert single-item triggerTone arrays to strings
  if (Array.isArray(item.triggerTone) && item.triggerTone.length === 1) {
    item.triggerTone = item.triggerTone[0];
    converted++;
  }
  
  // Convert single-item rawTone arrays to strings
  if (Array.isArray(item.rawTone) && item.rawTone.length === 1) {
    item.rawTone = item.rawTone[0];
    converted++;
  }
  
  // Convert single-item intent arrays to strings
  if (Array.isArray(item.intent) && item.intent.length === 1) {
    item.intent = item.intent[0];
    converted++;
  }
});

fs.writeFileSync('data/therapy_advice.json', JSON.stringify(data, null, 2));
console.log(`Converted ${converted} single-item arrays to strings`);