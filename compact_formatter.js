#!/usr/bin/env node

const fs = require('fs');

function compactFormatter(obj, indent = 0) {
  const spaces = ' '.repeat(indent);
  
  if (Array.isArray(obj)) {
    // Keep arrays on single line
    return '[' + obj.map(item => JSON.stringify(item)).join(', ') + ']';
  }
  
  if (obj && typeof obj === 'object') {
    const entries = Object.entries(obj);
    
    // For small objects (like severityThreshold, styleTuning), keep on one line
    if (entries.length <= 4 && !entries.some(([k, v]) => Array.isArray(v) && v.length > 5)) {
      const pairs = entries.map(([key, value]) => {
        if (Array.isArray(value)) {
          return `"${key}": [${value.map(v => JSON.stringify(v)).join(', ')}]`;
        } else if (value && typeof value === 'object') {
          const subPairs = Object.entries(value).map(([k, v]) => `"${k}": ${JSON.stringify(v)}`);
          return `"${key}": {${subPairs.join(', ')}}`;
        } else {
          return `"${key}": ${JSON.stringify(value)}`;
        }
      });
      return '{' + pairs.join(', ') + '}';
    }
    
    // For larger objects, format with proper indentation
    const result = '{\n';
    const formattedEntries = entries.map(([key, value], index) => {
      const isLast = index === entries.length - 1;
      const comma = isLast ? '' : ',';
      
      if (Array.isArray(value)) {
        return `${spaces}  "${key}": [${value.map(v => JSON.stringify(v)).join(', ')}]${comma}`;
      } else if (value && typeof value === 'object') {
        const subPairs = Object.entries(value).map(([k, v]) => `"${k}": ${JSON.stringify(v)}`);
        return `${spaces}  "${key}": {${subPairs.join(', ')}}${comma}`;
      } else {
        return `${spaces}  "${key}": ${JSON.stringify(value)}${comma}`;
      }
    });
    
    return result + formattedEntries.join('\n') + '\n' + spaces + '}';
  }
  
  return JSON.stringify(obj);
}

function formatTherapyAdvice() {
  console.log('📄 Reading therapy advice data...');
  
  const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));
  
  console.log(`📊 Found ${data.length} entries to format`);
  
  // Format the entire array
  const formatted = '[\n' + 
    data.map((entry, index) => {
      const isLast = index === data.length - 1;
      const comma = isLast ? '' : ',';
      return compactFormatter(entry, 2) + comma;
    }).join('\n') + 
    '\n]';
  
  fs.writeFileSync('data/therapy_advice.json', formatted);
  
  console.log('✅ Formatted therapy advice with compact style (keeping all data)');
}

if (require.main === module) {
  try {
    formatTherapyAdvice();
  } catch (error) {
    console.error('❌ Error formatting:', error.message);
    process.exit(1);
  }
}