#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

function reformatTherapyAdvice() {
  const therapyAdvicePath = path.join(__dirname, 'data', 'therapy_advice.json');
  
  console.log('Reading therapy_advice.json...');
  const data = JSON.parse(fs.readFileSync(therapyAdvicePath, 'utf8'));
  
  console.log(`Total entries: ${data.length}`);
  
  // Custom JSON stringifier to format arrays compactly when appropriate
  const customStringify = (obj, indent = 0) => {
    const spaces = '  '.repeat(indent);
    
    if (Array.isArray(obj)) {
      // For short arrays (like triggerTone with 2 elements), keep on one line
      if (obj.length <= 2 && obj.every(item => typeof item === 'string')) {
        return JSON.stringify(obj);
      }
      // For longer arrays, format vertically
      if (obj.length === 0) return '[]';
      
      const items = obj.map(item => 
        typeof item === 'object' ? customStringify(item, indent + 1) : JSON.stringify(item)
      );
      
      return '[\n' + spaces + '  ' + items.join(',\n' + spaces + '  ') + '\n' + spaces + ']';
    }
    
    if (obj && typeof obj === 'object' && obj.constructor === Object) {
      const keys = Object.keys(obj);
      if (keys.length === 0) return '{}';
      
      const items = keys.map(key => {
        const value = obj[key];
        const stringValue = typeof value === 'object' ? customStringify(value, indent + 1) : JSON.stringify(value);
        return `${JSON.stringify(key)}: ${stringValue}`;
      });
      
      return '{\n' + spaces + '  ' + items.join(',\n' + spaces + '  ') + '\n' + spaces + '}';
    }
    
    return JSON.stringify(obj);
  };
  
  // Format the entire array
  console.log('Reformatting JSON...');
  const formattedJson = '[\n' + data.map(entry => '  ' + customStringify(entry, 1)).join(',\n') + '\n]';
  
  console.log('Writing reformatted therapy_advice.json...');
  fs.writeFileSync(therapyAdvicePath, formattedJson, 'utf8');
  
  console.log('✅ Successfully reformatted therapy_advice.json with compact arrays');
  
  // Show example of new format
  console.log('\n📋 Sample formatted entry:');
  console.log('triggerTone arrays will now be formatted as: ["alert", "angry"]');
  console.log('Instead of:');
  console.log('  "triggerTone": [');
  console.log('    "alert",'); 
  console.log('    "angry"');
  console.log('  ]');
}

// Run the reformatting
reformatTherapyAdvice();