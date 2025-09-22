#!/usr/bin/env node

/**
 * Remove "general" context from all therapy advice entries
 * Keeps other contexts intact, only removes "general"
 */

const fs = require('fs');
const path = require('path');

const THERAPY_ADVICE_FILE = path.join(__dirname, 'data', 'therapy_advice.json');

function removeGeneralContexts() {
    console.log('🔧 Removing "general" contexts from therapy advice...\n');
    
    // Read the current file
    let therapyAdvice;
    try {
        const content = fs.readFileSync(THERAPY_ADVICE_FILE, 'utf8');
        therapyAdvice = JSON.parse(content);
    } catch (error) {
        console.error('❌ Error reading therapy advice file:', error.message);
        return;
    }
    
    if (!Array.isArray(therapyAdvice)) {
        console.error('❌ Therapy advice file is not an array');
        return;
    }
    
    let totalEntries = 0;
    let modifiedEntries = 0;
    let generalOnlyEntries = 0;
    let emptyContextEntries = 0;
    
    // Process each entry
    const processedAdvice = therapyAdvice.map(entry => {
        totalEntries++;
        
        if (!entry.contexts || !Array.isArray(entry.contexts)) {
            return entry;
        }
        
        const originalContexts = [...entry.contexts];
        const hasGeneral = originalContexts.includes('general');
        
        if (hasGeneral) {
            // Remove "general" from contexts
            const filteredContexts = originalContexts.filter(context => context !== 'general');
            
            if (filteredContexts.length === 0) {
                // This entry only had "general" context
                generalOnlyEntries++;
                console.log(`⚠️  ${entry.id}: Had only "general" context - removing entry or need fallback`);
                // For now, we'll keep the entry but with empty contexts
                emptyContextEntries++;
                return {
                    ...entry,
                    contexts: []
                };
            } else {
                modifiedEntries++;
                console.log(`✅ ${entry.id}: Removed "general" from [${originalContexts.join(', ')}] → [${filteredContexts.join(', ')}]`);
                return {
                    ...entry,
                    contexts: filteredContexts
                };
            }
        }
        
        return entry;
    });
    
    // Create backup
    const backupFile = THERAPY_ADVICE_FILE + '.backup.' + Date.now();
    try {
        fs.writeFileSync(backupFile, fs.readFileSync(THERAPY_ADVICE_FILE));
        console.log(`\n💾 Backup created: ${path.basename(backupFile)}`);
    } catch (error) {
        console.error('❌ Error creating backup:', error.message);
        return;
    }
    
    // Write the modified file
    try {
        fs.writeFileSync(THERAPY_ADVICE_FILE, JSON.stringify(processedAdvice, null, 2));
        console.log('✅ Updated therapy_advice.json successfully');
    } catch (error) {
        console.error('❌ Error writing updated file:', error.message);
        return;
    }
    
    // Summary
    console.log('\n📊 Summary:');
    console.log(`   Total entries processed: ${totalEntries}`);
    console.log(`   Entries modified: ${modifiedEntries}`);
    console.log(`   Entries with only "general": ${generalOnlyEntries}`);
    console.log(`   Entries now with empty contexts: ${emptyContextEntries}`);
    
    if (emptyContextEntries > 0) {
        console.log('\n⚠️  Warning: Some entries now have empty contexts arrays.');
        console.log('   You may want to review these entries and assign appropriate contexts.');
    }
    
    console.log('\n🎯 All "general" contexts have been removed!');
    
    // Show some stats about remaining contexts
    const remainingContexts = new Set();
    processedAdvice.forEach(entry => {
        if (entry.contexts && Array.isArray(entry.contexts)) {
            entry.contexts.forEach(context => remainingContexts.add(context));
        }
    });
    
    console.log(`\n📋 Remaining context types (${remainingContexts.size}):`);
    Array.from(remainingContexts).sort().forEach(context => {
        const count = processedAdvice.reduce((acc, entry) => 
            acc + (entry.contexts?.includes(context) ? 1 : 0), 0
        );
        console.log(`   - ${context}: ${count} entries`);
    });
}

function showPreview() {
    console.log('🔍 Preview: Finding entries with "general" context...\n');
    
    try {
        const content = fs.readFileSync(THERAPY_ADVICE_FILE, 'utf8');
        const therapyAdvice = JSON.parse(content);
        
        const generalEntries = therapyAdvice.filter(entry => 
            entry.contexts && entry.contexts.includes('general')
        );
        
        console.log(`Found ${generalEntries.length} entries with "general" context:`);
        
        // Show first 10 as examples
        generalEntries.slice(0, 10).forEach(entry => {
            console.log(`   ${entry.id}: [${entry.contexts.join(', ')}]`);
        });
        
        if (generalEntries.length > 10) {
            console.log(`   ... and ${generalEntries.length - 10} more`);
        }
        
        // Check for entries that only have "general"
        const generalOnlyEntries = generalEntries.filter(entry => 
            entry.contexts.length === 1 && entry.contexts[0] === 'general'
        );
        
        console.log(`\n⚠️  ${generalOnlyEntries.length} entries have ONLY "general" context:`);
        generalOnlyEntries.slice(0, 5).forEach(entry => {
            console.log(`   ${entry.id}: "${entry.advice.substring(0, 60)}..."`);
        });
        
    } catch (error) {
        console.error('❌ Error reading file:', error.message);
    }
}

// Main execution
const args = process.argv.slice(2);

if (args.includes('--preview') || args.includes('-p')) {
    showPreview();
} else if (args.includes('--help') || args.includes('-h')) {
    console.log('📖 Usage:');
    console.log('   node remove-general-contexts.js           # Remove all "general" contexts');
    console.log('   node remove-general-contexts.js --preview # Preview what will be changed');
    console.log('   node remove-general-contexts.js --help    # Show this help');
} else {
    removeGeneralContexts();
}

module.exports = { removeGeneralContexts, showPreview };