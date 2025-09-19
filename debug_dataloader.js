// Debug script to test dataLoader behavior
const path = require('path');
const fs = require('fs');

console.log('=== DataLoader Debug Test ===');

// Test direct file access (like health check does)
const dataDir = path.join(process.cwd(), 'data');
console.log(`Data directory: ${dataDir}`);
console.log(`Directory exists: ${fs.existsSync(dataDir)}`);

if (fs.existsSync(dataDir)) {
  const files = fs.readdirSync(dataDir);
  console.log(`Files in data directory: ${files.length}`);
  
  // Check specific problem files
  const problemFiles = ['attachment_learning.json', 'semantic_thesaurus.json'];
  
  for (const file of problemFiles) {
    const filePath = path.join(dataDir, file);
    console.log(`\n--- ${file} ---`);
    console.log(`File exists: ${fs.existsSync(filePath)}`);
    
    if (fs.existsSync(filePath)) {
      try {
        const content = fs.readFileSync(filePath, 'utf8');
        const parsed = JSON.parse(content);
        console.log(`File size: ${content.length} chars`);
        console.log(`JSON valid: true`);
        console.log(`Has version: ${!!parsed.version}`);
        console.log(`Version: ${parsed.version || 'N/A'}`);
      } catch (err) {
        console.log(`JSON parse error: ${err.message}`);
      }
    }
  }
}