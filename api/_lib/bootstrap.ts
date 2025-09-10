// api/_lib/bootstrap.ts
import { dataLoader } from './services/dataLoader';
import { initAdviceSearch } from './services/adviceIndex';
import * as path from 'path';

let ready: Promise<void> | null = null;

export function ensureBoot() {
  if (!ready) {
    ready = (async () => {
      // DataLoader already knows its path from constructor
      await dataLoader.initialize();
      // Initialize advice search index for suggestions service
      await initAdviceSearch();
    })();
  }
  return ready;
}