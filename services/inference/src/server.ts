import Fastify from 'fastify';
import * as ort from 'onnxruntime-node';
import { join } from 'node:path';
import { AutoTokenizer } from '@xenova/transformers';

const app = Fastify({ logger: true });
let session: ort.InferenceSession | null = null;
let tokenizer: AutoTokenizer | null = null;

// Data directory for Cloud Run (all config files are local)
const DATA_DIR = join(process.cwd(), 'data');

app.addHook('onRequest', async (req, reply) => {
  const authHeader = req.headers.authorization;
  const expectedToken = process.env.INF_TOKEN;

  if (expectedToken && (!authHeader || !authHeader.startsWith('Bearer ') || authHeader.slice(7) !== expectedToken)) {
    return reply.code(401).send({ error: 'unauthorized' });
  }
});

app.get('/healthz', async () => ({ ok: true, timestamp: new Date().toISOString() }));

app.post('/tone', async (req, reply) => {
  const { text } = req.body as { text?: string } ?? {};
  if (!text) return reply.code(400).send({ error: 'text required' });

  try {
    // Lazy load model and tokenizer
    if (!session) {
      const modelPath = join(process.cwd(), 'models', 'minilm.onnx');
      session = await ort.InferenceSession.create(modelPath, { executionProviders: ['cpu'] });
      console.log('Model loaded from:', modelPath);
    }

    if (!tokenizer) {
      tokenizer = await AutoTokenizer.from_pretrained(join(process.cwd(), 'models', 'tokenizer'));
      console.log('Tokenizer loaded');
    }

    // TODO: Implement proper tokenization and inference
    // For now, return mock scores
    const mockScores = [0.2, 0.3, 0.5];

    return reply.send({
      input: text,
      scores: mockScores,
      model: 'sentiment-roberta',
      timestamp: new Date().toISOString()
    });

  } catch (error) {
    console.error('Inference error:', error);
    return reply.code(500).send({
      error: 'inference_failed',
      message: error instanceof Error ? error.message : 'Unknown error'
    });
  }
});

const start = async () => {
  try {
    await app.listen({ port: 8080, host: '0.0.0.0' });
    console.log('Inference service listening on port 8080');
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
};

start();
