const fs = require('fs');

// Read the tone_patterns.json file
const tonePatterns = JSON.parse(fs.readFileSync('/Users/johngray/Desktop/Unsaid/data/tone_patterns.json', 'utf8'));

// Define the therapy advice categories to add
const therapyCategories = [
    'attachment_awareness', 'boundary_setting', 'conflict_resolution',
    'communication_awareness', 'communication_clarification', 'communication_structure',
    'emotional_support', 'intimacy_connection', 'vulnerability_sharing',
    'positive_communication', 'feedback_communication', 'general_communication',
    'personal_development', 'relationship_development',
    'decision_making', 'coordination', 'group_communication',
    'digital_communication', 'safety_concerns', 'self_protection',
    'relationship_repair', 'undefined'
];

// Find the highest existing pattern ID
let maxId = 0;
tonePatterns.patterns.forEach(pattern => {
    const idMatch = pattern.id.match(/([A-Z])(\d+)/);
    if (idMatch) {
        const num = parseInt(idMatch[2], 10);
        if (num > maxId) maxId = num;
    }
});

console.log(`Starting from pattern ID: ${maxId + 1}`);

// Create patterns for each therapy category
const newPatterns = [];
let currentId = maxId + 1;

therapyCategories.forEach(category => {
    // Create a positive communication pattern for each therapy category
    const pattern = {
        id: `P${String(currentId).padStart(3, '0')}`, // P for "Positive"
        tone: "clear", // Therapy advice generally promotes clear communication
        category: category,
        matchMode: "semantic", // Use semantic matching for positive patterns
        canonical: `${category.replace(/_/g, ' ')}`,
        variants: [
            `${category.replace(/_/g, ' ')}`,
            category
        ],
        regex: `\\b${category.replace(/_/g, '[ -]?')}\\b`,
        threshold: 0.4,
        styleWeight: 0.8,
        contextOverrides: {},
        notes: `Pattern for ${category} therapy advice category`
    };
    
    newPatterns.push(pattern);
    currentId++;
});

// Add the new patterns to the existing ones
tonePatterns.patterns.push(...newPatterns);

// Update version and notes
tonePatterns.version = "2.1.3-therapy-categories";
tonePatterns.notes = "Categories normalized to snake_case. Added contextOverrides for gratitude. Added therapy advice categories for positive communication patterns.";

console.log(`Added ${newPatterns.length} new patterns for therapy categories`);
console.log(`Total patterns now: ${tonePatterns.patterns.length}`);

// Write the updated file
fs.writeFileSync('/Users/johngray/Desktop/Unsaid/data/tone_patterns.json', JSON.stringify(tonePatterns, null, 2));

console.log('✅ Successfully added therapy advice categories to tone_patterns.json');