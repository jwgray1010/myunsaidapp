// api/debug/dataloader-test.ts
import { VercelRequest, VercelResponse } from '@vercel/node';
import { dataLoader } from '../_lib/services/dataLoader';
import { success, error as httpError } from '../_lib/http';
import * as fs from 'fs';
import * as path from 'path';

const handler = async (req: VercelRequest, res: VercelResponse) => {
  try {
    // Test file access like health check does
    const healthCheckPath = path.join(process.cwd(), 'data');
    
    // Test dataLoader paths
    const possiblePaths = [
      path.resolve(__dirname, '../../../data'),
      path.resolve(__dirname, '../../../../data'),
      path.resolve(process.cwd(), 'data'),
      path.resolve('/vercel/path0', 'data'),
      path.resolve(process.env.LAMBDA_TASK_ROOT || process.cwd(), 'data')
    ];

    const pathTests = possiblePaths.map(p => ({
      path: p,
      exists: fs.existsSync(p),
      files: fs.existsSync(p) ? fs.readdirSync(p).length : 0
    }));

    // Test specific files
    const testFiles = ['attachment_learning.json', 'semantic_thesaurus.json'];
    const fileTests = testFiles.map(filename => {
      const healthPath = path.join(healthCheckPath, filename);
      return {
        filename,
        healthCheckPath,
        healthExists: fs.existsSync(healthPath),
        dataLoaderResult: filename === 'attachment_learning.json' 
          ? dataLoader.getAttachmentLearning()
          : dataLoader.getSemanticThesaurus(),
        dataLoaderType: filename === 'attachment_learning.json' 
          ? typeof dataLoader.getAttachmentLearning()
          : typeof dataLoader.getSemanticThesaurus()
      };
    });

    return success(res, {
      environment: {
        cwd: process.cwd(),
        __dirname,
        LAMBDA_TASK_ROOT: process.env.LAMBDA_TASK_ROOT,
        NODE_ENV: process.env.NODE_ENV
      },
      pathTests,
      fileTests,
      dataLoaderInitialized: dataLoader.isInitialized()
    });

  } catch (err: any) {
    return httpError(res, `Debug test failed: ${err.message}`, 500);
  }
};

export default handler;