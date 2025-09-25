#!/usr/bin/env node

// Script to condense the first 20 therapy advice entries to match the compact format
const fs = require('fs');
const path = require('path');

function loadTherapyAdvice() {
    try {
        const advicePath = path.join(__dirname, 'data', 'therapy_advice.json');
        const advice = JSON.parse(fs.readFileSync(advicePath, 'utf8'));
        return advice;
    } catch (error) {
        console.error('Error loading therapy advice:', error);
        return null;
    }
}

function condenseEntry(entry) {
    // Create a condensed version of the entry
    const condensed = {
        id: entry.id,
        advice: entry.advice,
        triggerTone: entry.triggerTone,
        contexts: entry.contexts,
        attachmentStyles: entry.attachmentStyles,
        severityThreshold: entry.severityThreshold,
        spacyLink: entry.spacyLink,
        contextLink: entry.contextLink,
        boostSources: entry.boostSources,
        styleTuning: entry.styleTuning && Object.keys(entry.styleTuning).length > 0 ? entry.styleTuning : {},
        core_contexts: entry.core_contexts,
        intents: entry.intents,
        tags: entry.tags
    };
    
    return condensed;
}

function condenseTherapyAdvice() {
    console.log('🎯 Condensing First 20 Therapy Advice Entries\n');
    
    const advice = loadTherapyAdvice();
    if (!advice) {
        console.error('Failed to load therapy advice');
        return;
    }
    
    let updatedCount = 0;
    
    // Condense first 20 entries
    for (let i = 0; i < Math.min(20, advice.length); i++) {
        const entry = advice[i];
        const condensed = condenseEntry(entry);
        
        console.log(`${entry.id}: Condensed`);
        console.log(`   TriggerTone: ${condensed.triggerTone}`);
        console.log(`   StyleTuning: ${JSON.stringify(condensed.styleTuning)}`);
        console.log('');
        
        // Replace the entry with the condensed version
        advice[i] = condensed;
        updatedCount++;
    }
    
    // Write back to file
    try {
        const advicePath = path.join(__dirname, 'data', 'therapy_advice.json');
        fs.writeFileSync(advicePath, JSON.stringify(advice, null, 2), 'utf8');
        console.log(`✅ Successfully condensed ${updatedCount} entries`);
        console.log(`📁 Updated file: ${advicePath}`);
    } catch (error) {
        console.error('Error writing therapy advice file:', error);
    }
}

// Run the condensing
if (require.main === module) {
    condenseTherapyAdvice();
}

module.exports = {
    condenseEntry,
    condenseTherapyAdvice
};