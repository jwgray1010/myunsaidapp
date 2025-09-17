// api/_lib/services/index.ts
export { dataLoader } from './dataLoader';
export { toneAnalysisService, createToneAnalyzer, MLAdvancedToneAnalyzer, mapToneToBuckets, loadAllData } from './toneAnalysis';
export { processWithSpacy, processWithSpacySync } from './spacyBridge';
export { default as spacyClient } from './spacyClient';
export { logger } from '../logger';
export { initAdviceSearch } from './adviceIndex';
export { suggestionsService } from './suggestions';
export { CommunicatorProfile } from './communicatorProfile';