/**
 * Local path resolver for models, tokenizers, and data files
 * Safely resolves file paths without network dependencies
 * Compatible with Vercel/Lambda serverless environments
 */

import { join, resolve } from 'path';
import { existsSync } from 'fs';

/**
 * Resolve a relative path to an absolute path by trying common locations
 * @param rel - Relative path to resolve (e.g., 'models/mnli-mini.onnx')
 * @param extra - Additional paths to try
 * @returns Absolute path if found, null otherwise
 */
export function resolveLocalPath(rel: string, extra: string[] = []): string | null {
  const tries = [
    join(process.cwd(), rel),                              // Current working directory
    join(resolve(__dirname, '..', '..'), rel),            // From api/_lib/
    join(resolve(__dirname, '..', '..', '..'), rel),      // From project root
    join('/var/task', rel),                               // Lambda/Vercel runtime
    ...extra                                              // Custom additional paths
  ];
  
  for (const p of tries) {
    if (existsSync(p)) {
      return p;
    }
  }
  
  return null;
}

/**
 * Resolve data JSON files specifically
 * @param filename - JSON filename (e.g., 'context_classifier.json')
 * @returns Absolute path if found, null otherwise
 */
export function resolveDataPath(filename: string): string | null {
  return resolveLocalPath(`data/${filename}`);
}

/**
 * Resolve model files specifically
 * @param filename - Model filename (e.g., 'mnli-mini.onnx')
 * @returns Absolute path if found, null otherwise
 */
export function resolveModelPath(filename: string): string | null {
  return resolveLocalPath(`models/${filename}`);
}