/**
 * api/_lib/metrics.ts
 *
 * Production-grade TypeScript metrics for Vercel serverless functions.
 * - Per-route HTTP request duration tracking
 * - Request/response metrics
 * - Error counters
 * - Helpers to time arbitrary async work
 * - Prometheus-compatible format
 * - Memory-efficient in-memory storage
 */

import { logger } from './logger';
import { env } from './env';

// ---- Configuration ----
const metricsConfig = {
  enabled: process.env.METRICS_ENABLED !== 'false',
  prefix: 'unsaid_',
  serviceName: process.env.SERVICE_NAME || 'unsaid-api',
  nodeEnv: env.NODE_ENV,
  serviceVersion: process.env.SERVICE_VERSION || '0.0.0',
  metricsBuckets: process.env.METRICS_BUCKETS || '',
};

// ---- Common buckets (matching JavaScript version) ----
const defaultHttpBuckets = (metricsConfig.metricsBuckets
  ? metricsConfig.metricsBuckets.split(',').map(Number).filter(n => !Number.isNaN(n))
  : [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]);

// ---- Interfaces ----
interface MetricData {
  name: string;
  value: number;
  labels?: Record<string, string>;
  timestamp: number;
  type: 'counter' | 'gauge' | 'histogram';
}

interface HistogramEntry {
  value: number;
  timestamp: number;
  labels: Record<string, string>;
}

interface TimerData {
  start: bigint;
  name: string;
  labels?: Record<string, string>;
}

// ---- Core Metrics Storage ----
class MetricsRegistry {
  private counters = new Map<string, number>();
  private gauges = new Map<string, number>();
  private histograms = new Map<string, HistogramEntry[]>();
  private timers = new Map<string, TimerData>();
  private metrics: MetricData[] = [];

  // Default labels (matching JavaScript version)
  private defaultLabels = {
    service: metricsConfig.serviceName,
    env: metricsConfig.nodeEnv,
    version: metricsConfig.serviceVersion,
  };

  private getFullName(name: string): string {
    return `${metricsConfig.prefix}${name}`;
  }

  private addLabels(labels?: Record<string, string>): Record<string, string> {
    return { ...this.defaultLabels, ...labels };
  }

  private record(metric: MetricData): void {
    if (!metricsConfig.enabled) return;
    
    this.metrics.push(metric);
    
    // Log metric (in production, send to monitoring service)
    logger.debug('Metric recorded', {
      metric: metric.name,
      value: metric.value,
      labels: metric.labels,
      type: metric.type
    });

    // Keep only last 1000 metrics to prevent memory leaks
    if (this.metrics.length > 1000) {
      this.metrics = this.metrics.slice(-1000);
    }
  }

  // Counter increment (matching JavaScript version)
  inc(name: string, labels: Record<string, string> = {}, value: number = 1): void {
    if (!metricsConfig.enabled) return;
    
    const fullName = this.getFullName(name);
    const key = `${fullName}_${JSON.stringify(labels)}`;
    const current = this.counters.get(key) || 0;
    const newValue = current + value;
    
    this.counters.set(key, newValue);
    
    this.record({
      name: fullName,
      value: newValue,
      labels: this.addLabels(labels),
      timestamp: Date.now(),
      type: 'counter'
    });
  }

  // Gauge set (matching JavaScript version)
  gaugeSet(name: string, value: number, labels: Record<string, string> = {}): void {
    if (!metricsConfig.enabled) return;
    
    const fullName = this.getFullName(name);
    const key = `${fullName}_${JSON.stringify(labels)}`;
    
    this.gauges.set(key, value);
    
    this.record({
      name: fullName,
      value,
      labels: this.addLabels(labels),
      timestamp: Date.now(),
      type: 'gauge'
    });
  }

  // Histogram observe (matching JavaScript version)
  observe(name: string, value: number, labels: Record<string, string> = {}): void {
    if (!metricsConfig.enabled) return;
    
    const fullName = this.getFullName(name);
    const key = `${fullName}_${JSON.stringify(labels)}`;
    
    if (!this.histograms.has(key)) {
      this.histograms.set(key, []);
    }
    
    const entries = this.histograms.get(key)!;
    entries.push({
      value,
      timestamp: Date.now(),
      labels: this.addLabels(labels)
    });
    
    // Keep only last 1000 entries per histogram
    if (entries.length > 1000) {
      entries.splice(0, entries.length - 1000);
    }
    
    this.record({
      name: fullName,
      value,
      labels: this.addLabels(labels),
      timestamp: Date.now(),
      type: 'histogram'
    });
  }

  // Timer utilities
  startTimer(name: string, labels: Record<string, string> = {}): string {
    if (!metricsConfig.enabled) return '';
    
    const timerId = `${name}_${Date.now()}_${Math.random()}`;
    this.timers.set(timerId, {
      start: process.hrtime.bigint(),
      name,
      labels
    });
    return timerId;
  }

  endTimer(timerId: string, additionalLabels: Record<string, string> = {}): number | null {
    if (!metricsConfig.enabled || !timerId) return null;
    
    const timer = this.timers.get(timerId);
    if (!timer) {
      logger.warn('Timer not found', { timerId });
      return null;
    }

    const end = process.hrtime.bigint();
    const durationNs = Number(end - timer.start);
    const durationSeconds = durationNs / 1e9;
    
    this.timers.delete(timerId);
    
    // Record duration as histogram
    this.observe(
      `${timer.name}_duration_seconds`,
      durationSeconds,
      { ...timer.labels, ...additionalLabels }
    );

    return durationSeconds;
  }

  // HTTP-specific metrics (matching JavaScript structure)
  trackHttpRequest(method: string, route: string, statusCode: number, durationMs: number, requestSize?: number, responseSize?: number): void {
    if (!metricsConfig.enabled) return;
    
    const labels = {
      method: method.toUpperCase(),
      route,
      status_code: statusCode.toString()
    };

    // Total requests
    this.inc('http_requests_total', labels);
    
    // Request duration
    this.observe('http_request_duration_seconds', durationMs / 1000, labels);
    
    // Errors (>= 500)
    if (statusCode >= 500) {
      this.inc('http_errors_total', { method: method.toUpperCase(), route });
    }
    
    // Request/response sizes
    if (requestSize !== undefined) {
      this.observe('http_request_size_bytes', requestSize, { method: method.toUpperCase(), route });
    }
    
    if (responseSize !== undefined) {
      this.observe('http_response_size_bytes', responseSize, labels);
    }
  }

  // Service uptime
  markServiceUp(): void {
    this.gaugeSet('up', 1);
  }

  markServiceDown(): void {
    this.gaugeSet('up', 0);
  }

  // Get metrics in Prometheus format (matching JavaScript /metrics endpoint)
  getPrometheusMetrics(): string {
    if (!metricsConfig.enabled) return '';
    
    const lines: string[] = [];
    const now = Date.now();
    
    // Counters - group by metric name+labelset 
    const countersByMetric = new Map<string, Map<string, number>>();
    Array.from(this.counters.entries()).forEach(([key, value]) => {
      // Extract metric name and labels from key
      const keyParts = key.split('_{"');
      const metricName = keyParts[0];
      const labelsJson = keyParts[1] ? '{"' + keyParts[1] : '{}';
      
      if (!countersByMetric.has(metricName)) {
        countersByMetric.set(metricName, new Map());
      }
      countersByMetric.get(metricName)!.set(labelsJson, value);
    });
    
    countersByMetric.forEach((labelMap, metricName) => {
      lines.push(`# TYPE ${metricName} counter`);
      labelMap.forEach((value, labelsJson) => {
        const labels = labelsJson === '{}' ? this.defaultLabels : {...this.defaultLabels, ...JSON.parse(labelsJson)};
        const formattedLabels = this.formatLabels(labels);
        lines.push(`${metricName}${formattedLabels} ${value} ${now}`);
      });
    });
    
    // Gauges - group by metric name+labelset
    const gaugesByMetric = new Map<string, Map<string, number>>();
    Array.from(this.gauges.entries()).forEach(([key, value]) => {
      const keyParts = key.split('_{"');
      const metricName = keyParts[0];
      const labelsJson = keyParts[1] ? '{"' + keyParts[1] : '{}';
      
      if (!gaugesByMetric.has(metricName)) {
        gaugesByMetric.set(metricName, new Map());
      }
      gaugesByMetric.get(metricName)!.set(labelsJson, value);
    });
    
    gaugesByMetric.forEach((labelMap, metricName) => {
      lines.push(`# TYPE ${metricName} gauge`);
      labelMap.forEach((value, labelsJson) => {
        const labels = labelsJson === '{}' ? this.defaultLabels : {...this.defaultLabels, ...JSON.parse(labelsJson)};
        const formattedLabels = this.formatLabels(labels);
        lines.push(`${metricName}${formattedLabels} ${value} ${now}`);
      });
    });
    
    // Histograms - proper bucket format with per-metric-labelset buckets
    Array.from(this.histograms.entries()).forEach(([key, entries]) => {
      if (entries.length === 0) return;
      
      const keyParts = key.split('_{"');
      const metricName = keyParts[0];
      const labelsJson = keyParts[1] ? '{"' + keyParts[1] : '{}';
      const baseLabels = labelsJson === '{}' ? this.defaultLabels : {...this.defaultLabels, ...JSON.parse(labelsJson)};
      
      const values = entries.map(e => e.value);
      const sum = values.reduce((a, b) => a + b, 0);
      const count = values.length;
      
      lines.push(`# TYPE ${metricName} histogram`);
      
      // Emit bucket{...le="X"} for each bucket
      for (const bucket of defaultHttpBuckets) {
        const bucketCount = values.filter(v => v <= bucket).length;
        const bucketLabels = {...baseLabels, le: bucket.toString()};
        lines.push(`${metricName}_bucket${this.formatLabels(bucketLabels)} ${bucketCount} ${now}`);
      }
      
      // +Inf bucket
      const infLabels = {...baseLabels, le: '+Inf'};
      lines.push(`${metricName}_bucket${this.formatLabels(infLabels)} ${count} ${now}`);
      
      // _sum and _count
      lines.push(`${metricName}_sum${this.formatLabels(baseLabels)} ${sum} ${now}`);
      lines.push(`${metricName}_count${this.formatLabels(baseLabels)} ${count} ${now}`);
    });
    
    return lines.join('\n');
  }

  private formatLabels(labels: Record<string, string>): string {
    const pairs = Object.entries(labels).map(([k, v]) => `${k}="${v}"`);
    return pairs.length > 0 ? `{${pairs.join(',')}}` : '';
  }

  private formatLabelsInline(labels: Record<string, any>): string {
    const pairs = Object.entries(labels)
      .filter(([, value]) => value !== undefined && value !== null)
      .map(([key, value]) => `${key}="${value}"`)
      .sort(); // Consistent ordering
    return pairs.join(', ');
  }

  // Helper for Prometheus metrics endpoint Content-Type
  static getPrometheusContentType(): string {
    return 'text/plain; version=0.0.4; charset=utf-8';
  }

  // Get raw metrics data
  getMetrics(): MetricData[] {
    return [...this.metrics];
  }

  // Clear all metrics
  clear(): void {
    this.counters.clear();
    this.gauges.clear();
    this.histograms.clear();
    this.timers.clear();
    this.metrics = [];
  }
}

// ---- Singleton Registry ----
const register = new MetricsRegistry();

// ---- Public API (matching JavaScript exports) ----

/**
 * Increment a counter (matching JavaScript version)
 */
export function inc(name: string, labels: Record<string, string> = {}, value: number = 1): void {
  register.inc(name, labels, value);
}

/**
 * Set a gauge value (matching JavaScript version)
 */
export function gaugeSet(name: string, value: number, labels: Record<string, string> = {}): void {
  register.gaugeSet(name, value, labels);
}

/**
 * Observe a histogram value (matching JavaScript version)
 */
export function observe(name: string, value: number, labels: Record<string, string> = {}): void {
  register.observe(name, value, labels);
}

/**
 * Time an async function and record a histogram (matching JavaScript version)
 * Usage: const result = await timeAsync('db_query_seconds', { table: 'users' }, () => db.users.find(...))
 */
export async function timeAsync<T>(
  name: string,
  labels: Record<string, string>,
  fn: () => Promise<T>
): Promise<T> {
  if (!metricsConfig.enabled) return fn();
  
  const timerId = register.startTimer(name, labels);
  try {
    const result = await fn();
    register.endTimer(timerId);
    return result;
  } catch (error) {
    register.endTimer(timerId, { error: '1' });
    throw error;
  }
}

// ---- Vercel-specific utilities ----

/**
 * Metrics middleware for Vercel functions
 */
export function withMetrics<T extends any[], R>(
  handler: (...args: T) => Promise<R>,
  route: string = 'unknown'
): (...args: T) => Promise<R> {
  return async (...args: T): Promise<R> => {
    if (!metricsConfig.enabled) return handler(...args);
    
    const start = Date.now();
    const timerId = register.startTimer('request_duration', { route });
    
    try {
      const result = await handler(...args);
      const duration = Date.now() - start;
      
      register.endTimer(timerId);
      register.trackHttpRequest('POST', route, 200, duration);
      
      return result;
    } catch (error) {
      const duration = Date.now() - start;
      
      register.endTimer(timerId, { error: '1' });
      register.trackHttpRequest('POST', route, 500, duration);
      
      throw error;
    }
  };
}

/**
 * Track API usage (simplified version)
 */
export function trackApiCall(endpoint: string, method: string, statusCode: number, duration: number): void {
  register.trackHttpRequest(method, endpoint, statusCode, duration);
}

/**
 * Track user actions
 */
export function trackUserAction(action: string, userId: string, success: boolean = true): void {
  register.inc('user_actions_total', {
    action,
    user_id: userId,
    success: success.toString()
  });
}

/**
 * Track service usage
 */
export function trackServiceUsage(service: string, operation: string, duration: number): void {
  register.inc('service_operations_total', { service, operation });
  register.observe('service_operation_duration_seconds', duration / 1000, { service, operation });
}

// ---- Export registry for metrics endpoint ----
export const metricsRegistry = register;

/**
 * Get metrics in Prometheus format (for /metrics endpoint)
 */
export function getPrometheusMetrics(): string {
  register.markServiceUp();
  return register.getPrometheusMetrics();
}

export function getPrometheusContentType(): string {
  return 'text/plain; version=0.0.4; charset=utf-8';
}

// ---- Legacy exports for backwards compatibility ----
export const metrics = {
  increment: (name: string, value: number = 1, tags?: Record<string, string>) => inc(name, tags || {}, value),
  gauge: (name: string, value: number, tags?: Record<string, string>) => gaugeSet(name, value, tags || {}),
  histogram: (name: string, value: number, tags?: Record<string, string>) => observe(name, value, tags || {}),
  startTimer: (name: string, tags?: Record<string, string>) => register.startTimer(name, tags || {}),
  endTimer: (timerId: string) => register.endTimer(timerId),
  trackApiCall,
  trackUserAction,
  trackServiceUsage,
  getMetrics: () => register.getMetrics(),
  clear: () => register.clear(),
};

// ---- Time operation helper (additional export) ----
export async function timeOperation<T>(
  name: string,
  operation: () => Promise<T>,
  labels?: Record<string, string>
): Promise<T> {
  return timeAsync(name, labels || {}, operation);
}