// api/_lib/logger.ts
import { env } from './env';

type Level = 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal';

const LEVELS: Record<Level, number> = {
  trace: 10,
  debug: 20,
  info: 30,
  warn: 40,
  error: 50,
  fatal: 60,
};

function normalizeLevel(input?: string): Level {
  const v = (input || '').toLowerCase() as Level;
  return (v in LEVELS ? v : 'info');
}

function pickConsole(level: Level) {
  switch (level) {
    case 'trace': return console.debug ?? console.log;
    case 'debug': return console.debug ?? console.log;
    case 'info':  return console.info  ?? console.log;
    case 'warn':  return console.warn  ?? console.log;
    case 'error': return console.error ?? console.log;
    case 'fatal': return console.error ?? console.log;
    default:      return console.log;
  }
}

function isErrorLike(x: any): x is Error {
  return !!x && (x instanceof Error || (typeof x === 'object' && ('message' in x || 'stack' in x)));
}

const DEFAULT_REDACTIONS = ['authorization', 'password', 'pass', 'token', 'api_key', 'apikey', 'secret', 'set-cookie'];

function redact(obj: any, extraKeys: string[] = []): any {
  const keys = new Set([...DEFAULT_REDACTIONS, ...extraKeys].map(k => k.toLowerCase()));
  const seen = new WeakSet<object>();

  function _walk(value: any): any {
    if (value == null) return value;
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value;
    if (typeof value === 'function') return undefined;
    if (isErrorLike(value)) {
      return {
        name: value.name,
        message: value.message,
        stack: value.stack,
      };
    }
    if (typeof value !== 'object') return value;
    if (seen.has(value)) return '[Circular]';
    seen.add(value);

    if (Array.isArray(value)) return value.map(_walk);

    const out: Record<string, any> = {};
    for (const [k, v] of Object.entries(value)) {
      if (keys.has(k.toLowerCase())) {
        out[k] = '[REDACTED]';
      } else {
        out[k] = _walk(v);
      }
    }
    return out;
  }

  return _walk(obj);
}

function safeStringify(obj: any, limit = 8 * 1024): string {
  try {
    const s = JSON.stringify(obj);
    if (s.length <= limit) return s;
    return s.slice(0, limit) + '…';
  } catch {
    try {
      return JSON.stringify(String(obj));
    } catch {
      return '"[Unserializable]"';
    }
  }
}

export interface Logger {
  trace(message: string, data?: any): void;
  debug(message: string, data?: any): void;
  info(message: string, data?: any): void;
  warn(message: string, data?: any): void;
  error(message: string, data?: any): void;
  fatal(message: string, data?: any): void;
  child(bindings: Record<string, any>): Logger;
  setLevel(level: Level): void;
  getLevel(): Level;
}

interface LoggerConfig {
  level: Level;
  service: string;
  env: string;
  version: string;
  pretty: boolean;
  silent: boolean;
  redactKeys?: string[];
}

class ConsoleLogger implements Logger {
  private config: LoggerConfig;
  private bindings: Record<string, any>;

  constructor(config?: Partial<LoggerConfig>, bindings: Record<string, any> = {}) {
    this.config = {
      level: normalizeLevel(process.env.LOG_LEVEL),
      service: process.env.SERVICE_NAME || 'unsaid-api',
      env: env.NODE_ENV,
      version: process.env.SERVICE_VERSION || '0.0.0',
      pretty: env.NODE_ENV !== 'production' || process.env.PRETTY_LOGS === '1',
      silent: process.env.LOG_SILENT === '1',
      redactKeys: [],
      ...config,
    };
    this.bindings = bindings;
  }

  setLevel(level: Level) {
    this.config.level = normalizeLevel(level);
  }
  getLevel(): Level {
    return this.config.level;
  }

  private shouldLog(level: Level): boolean {
    if (this.config.silent) return false;
    return LEVELS[level] >= LEVELS[this.config.level];
  }

  private baseEntry(level: Level, message: string, data?: any) {
    const ts = new Date().toISOString();
    const mergedData = (data && typeof data === 'object')
      ? data
      : (data === undefined ? undefined : { data });

    const errPart = isErrorLike(data)
      ? { error: { name: data.name, message: data.message, stack: data.stack } }
      : {};

    return {
      timestamp: ts,
      level: level.toUpperCase(),
      service: this.config.service,
      env: this.config.env,
      version: this.config.version,
      message,
      ...this.bindings,
      ...errPart,
      ...(mergedData && !isErrorLike(data) ? redact(mergedData, this.config.redactKeys) : undefined),
    };
  }

  private log(level: Level, message: string, data?: any): void {
    if (!this.shouldLog(level)) return;

    const entry = this.baseEntry(level, message, data);
    const writer = pickConsole(level);

    if (this.config.pretty) {
      const ctx = Object.keys(this.bindings).length
        ? ` [${Object.entries(this.bindings).map(([k, v]) => `${k}=${v}`).join(', ')}]`
        : '';
      const tail = data !== undefined ? ' ' + safeStringify(redact(data, this.config.redactKeys)) : '';
      writer(`[${entry.timestamp}] ${level.toUpperCase()}${ctx}: ${message}${tail}`);
    } else {
      writer(safeStringify(entry));
    }
  }

  trace(msg: string, data?: any) { this.log('trace', msg, data); }
  debug(msg: string, data?: any) { this.log('debug', msg, data); }
  info (msg: string, data?: any) { this.log('info',  msg, data); }
  warn (msg: string, data?: any) { this.log('warn',  msg, data); }
  error(msg: string, data?: any) { this.log('error', msg, data); }
  fatal(msg: string, data?: any) { this.log('fatal', msg, data); }

  child(bindings: Record<string, any>): Logger {
    // Inherit config & level, merge bindings
    return new ConsoleLogger(this.config, { ...this.bindings, ...bindings });
  }
}

// Base logger instance
export const logger: Logger = new ConsoleLogger();

// Module-scoped child helper
export function withModule(moduleName: string, extra: Record<string, any> = {}): Logger {
  return logger.child({ module: moduleName, ...extra });
}

// Stable ID helper (kept for compatibility)
export function genId(prefix: string = 'id'): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).substring(2, 10)}`;
}
