const fs = require('fs');

const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));
let fixed = 0;

data.forEach(item => {
  if (item.triggerTone && !item.rawTone) {
    if (item.triggerTone.includes('alert')) {
      item.rawTone = ['angry'];
    } else if (item.triggerTone.includes('caution')) {
      item.rawTone = ['frustrated'];
    } else if (item.triggerTone.includes('clear')) {
      item.rawTone = ['neutral'];
    }
    fixed++;
  }
});

fs.writeFileSync('data/therapy_advice.json', JSON.stringify(data, null, 2));
console.log(`Fixed ${fixed} entries missing rawTone`);