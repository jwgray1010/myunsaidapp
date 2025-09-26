const fs = require('fs');

const data = JSON.parse(fs.readFileSync('data/therapy_advice.json', 'utf8'));

// Create category mapping from primary context to logical category groups
const contextToCategoryMapping = {
  'conflict': 'conflict_resolution',
  'boundary': 'boundary_setting', 
  'planning': 'coordination',
  'repair': 'relationship_repair',
  'support': 'emotional_support',
  'presence': 'emotional_support',
  'misunderstanding': 'communication_clarification',
  'co_parenting': 'coordination',
  'work/school': 'coordination',
  'safety': 'safety_concerns',
  'finances': 'coordination',
  'gratitude': 'positive_communication',
  'check_in': 'emotional_support',
  'celebration': 'positive_communication',
  'apology': 'relationship_repair',
  'emotional': 'emotional_support',
  'logistics': 'coordination'
};

let added = 0;
let alreadyHasCategory = 0;

data.forEach(item => {
  // Check if already has category field
  if (item.category) {
    alreadyHasCategory++;
    return;
  }
  
  // Get primary context (first item in contexts array)
  if (item.contexts && item.contexts.length > 0) {
    const primaryContext = item.contexts[0];
    const category = contextToCategoryMapping[primaryContext];
    
    if (category) {
      item.category = category;
      added++;
    } else {
      console.log(`Warning: No category mapping for context: ${primaryContext}`);
    }
  }
});

fs.writeFileSync('data/therapy_advice.json', JSON.stringify(data, null, 2));
console.log(`Added category field to ${added} entries`);
console.log(`${alreadyHasCategory} entries already had category field`);

// Show the unique categories created
const categories = new Set();
data.forEach(item => {
  if (item.category) {
    categories.add(item.category);
  }
});

console.log('Categories created:');
Array.from(categories).sort().forEach(cat => console.log(`  ${cat}`));