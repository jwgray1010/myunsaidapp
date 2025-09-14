// api/v1/test-suggestions-enhancements.ts
// Comprehensive test harness for suggestions.ts enhancements
import { VercelRequest, VercelResponse } from '@vercel/node';

interface TestResult {
  name: string;
  description: string;
  status: 'PASS' | 'FAIL' | 'SKIP';
  details?: any;
  error?: string;
  performance?: {
    duration: number;
    cached: boolean;
  };
}

interface TestSuite {
  name: string;
  tests: TestResult[];
  summary: {
    passed: number;
    failed: number;
    skipped: number;
    total: number;
  };
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const testSuites: TestSuite[] = [];

  try {
    // Import the suggestions service
    const suggestionsModule = await import('../_lib/services/suggestions');
    const suggestionsService = suggestionsModule.suggestionsService;

    // Test Suite 1: Profanity Detection with Word Boundaries
    const profanityTests: TestResult[] = [];
    
    const testProfanityBoundaries = async () => {
      const tests = [
        { text: "I can't think straight", expected: false, description: "Should not flag 'can't' as profanity" },
        { text: "You damn fool", expected: true, description: "Should flag direct profanity" },
        { text: "This is classic behavior", expected: false, description: "Should not flag 'ass' in 'classic'" },
        { text: "You're being an ass", expected: true, description: "Should flag standalone profanity" },
        { text: "Assessment needed", expected: false, description: "Should not flag 'ass' in 'assessment'" }
      ];

      for (const test of tests) {
        try {
          const start = Date.now();
          const result = await suggestionsService.generateAdvancedSuggestions(test.text, 'general');
          const duration = Date.now() - start;
          
          // Check if suggestions were filtered for profanity
          const hasSuggestions = result.suggestions && result.suggestions.length > 0;
          const passed = test.expected ? !hasSuggestions : hasSuggestions;
          
          profanityTests.push({
            name: `Profanity Boundary Test: ${test.description}`,
            description: `Text: "${test.text}" - Expected filtered: ${test.expected}`,
            status: passed ? 'PASS' : 'FAIL',
            details: { 
              suggestionsCount: result.suggestions?.length || 0,
              expectedFiltered: test.expected,
              actuallyFiltered: !hasSuggestions
            },
            performance: { duration, cached: false }
          });
        } catch (error) {
          profanityTests.push({
            name: `Profanity Boundary Test: ${test.description}`,
            description: test.description,
            status: 'FAIL',
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
    };

    await testProfanityBoundaries();
    
    testSuites.push({
      name: 'Profanity Detection - Word Boundaries',
      tests: profanityTests,
      summary: {
        passed: profanityTests.filter(t => t.status === 'PASS').length,
        failed: profanityTests.filter(t => t.status === 'FAIL').length,
        skipped: profanityTests.filter(t => t.status === 'SKIP').length,
        total: profanityTests.length
      }
    });

    // Test Suite 2: Context Filtering Re-enablement
    const contextTests: TestResult[] = [];
    
    const testContextFiltering = async () => {
      const tests = [
        { text: "I need relationship advice", context: "relationship", expected: true, description: "Should allow relevant context" },
        { text: "Tell me about cooking recipes", context: "relationship", expected: false, description: "Should filter irrelevant context" },
        { text: "I'm feeling anxious", context: "general", expected: true, description: "Should allow general context" }
      ];

      for (const test of tests) {
        try {
          const start = Date.now();
          const result = await suggestionsService.generateAdvancedSuggestions(test.text, test.context);
          const duration = Date.now() - start;
          
          const hasSuggestions = result.suggestions && result.suggestions.length > 0;
          const passed = test.expected === hasSuggestions;
          
          contextTests.push({
            name: `Context Filtering Test: ${test.description}`,
            description: `Text: "${test.text}" in context "${test.context}"`,
            status: passed ? 'PASS' : 'FAIL',
            details: { 
              suggestionsCount: result.suggestions?.length || 0,
              expectedSuggestions: test.expected,
              actualSuggestions: hasSuggestions,
              context: test.context
            },
            performance: { duration, cached: false }
          });
        } catch (error) {
          contextTests.push({
            name: `Context Filtering Test: ${test.description}`,
            description: test.description,
            status: 'FAIL',
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
    };

    await testContextFiltering();
    
    testSuites.push({
      name: 'Context Filtering Re-enablement',
      tests: contextTests,
      summary: {
        passed: contextTests.filter(t => t.status === 'PASS').length,
        failed: contextTests.filter(t => t.status === 'FAIL').length,
        skipped: contextTests.filter(t => t.status === 'SKIP').length,
        total: contextTests.length
      }
    });

    // Test Suite 3: Performance & Caching
    const performanceTests: TestResult[] = [];
    
    const testCaching = async () => {
      const testText = "I'm feeling frustrated with my partner";
      const context = "relationship";
      
      try {
        // First call - should be cache miss
        const start1 = Date.now();
        const result1 = await suggestionsService.generateAdvancedSuggestions(testText, context);
        const duration1 = Date.now() - start1;
        
        // Second call - should be cache hit
        const start2 = Date.now();
        const result2 = await suggestionsService.generateAdvancedSuggestions(testText, context);
        const duration2 = Date.now() - start2;
        
        const cacheWorking = duration2 < duration1 * 0.5; // Second call should be much faster
        
        performanceTests.push({
          name: 'Caching Performance Test',
          description: 'Second identical request should be significantly faster',
          status: cacheWorking ? 'PASS' : 'FAIL',
          details: {
            firstCallDuration: duration1,
            secondCallDuration: duration2,
            speedImprovement: Math.round((duration1 - duration2) / duration1 * 100),
            suggestionsMatch: JSON.stringify(result1.suggestions) === JSON.stringify(result2.suggestions)
          },
          performance: { duration: duration2, cached: true }
        });
      } catch (error) {
        performanceTests.push({
          name: 'Caching Performance Test',
          description: 'Test caching functionality',
          status: 'FAIL',
          error: error instanceof Error ? error.message : String(error)
        });
      }
    };

    await testCaching();
    
    testSuites.push({
      name: 'Performance Optimizations',
      tests: performanceTests,
      summary: {
        passed: performanceTests.filter(t => t.status === 'PASS').length,
        failed: performanceTests.filter(t => t.status === 'FAIL').length,
        skipped: performanceTests.filter(t => t.status === 'SKIP').length,
        total: performanceTests.length
      }
    });

    // Test Suite 4: Enhanced Second-Person Detection
    const pronTests: TestResult[] = [];
    
    const testSecondPersonDetection = async () => {
      const tests = [
        { text: "You are amazing", expected: true, confidence: 0.8, description: "Direct second-person" },
        { text: "If you think about it", expected: true, confidence: 0.5, description: "Conditional second-person" },
        { text: "The weather is nice", expected: false, confidence: 0.1, description: "No second-person" },
        { text: "Try to relax yourself", expected: true, confidence: 0.6, description: "Imperative with second-person" },
        { text: "Your feelings matter", expected: true, confidence: 0.8, description: "Possessive second-person" }
      ];

      for (const test of tests) {
        try {
          const start = Date.now();
          const result = await suggestionsService.generateAdvancedSuggestions(test.text, 'general');
          const duration = Date.now() - start;
          
          // Check if second-person detection worked
          const analysis = result.analysis;
          const secondPerson = (analysis as any).secondPerson;
          
          const detectionWorked = test.expected ? secondPerson?.hasSecondPerson : !secondPerson?.hasSecondPerson;
          const confidenceMatch = !secondPerson || Math.abs((secondPerson.confidence || 0) - test.confidence) < 0.3;
          
          pronTests.push({
            name: `Second-Person Detection: ${test.description}`,
            description: `Text: "${test.text}"`,
            status: detectionWorked && confidenceMatch ? 'PASS' : 'FAIL',
            details: {
              expectedDetection: test.expected,
              actualDetection: secondPerson?.hasSecondPerson || false,
              expectedConfidence: test.confidence,
              actualConfidence: secondPerson?.confidence || 0,
              patterns: secondPerson?.patterns || [],
              targeting: secondPerson?.targeting || 'none'
            },
            performance: { duration, cached: false }
          });
        } catch (error) {
          pronTests.push({
            name: `Second-Person Detection: ${test.description}`,
            description: test.description,
            status: 'FAIL',
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
    };

    await testSecondPersonDetection();
    
    testSuites.push({
      name: 'spaCy PRON_2P Integration',
      tests: pronTests,
      summary: {
        passed: pronTests.filter(t => t.status === 'PASS').length,
        failed: pronTests.filter(t => t.status === 'FAIL').length,
        skipped: pronTests.filter(t => t.status === 'SKIP').length,
        total: pronTests.length
      }
    });

    // Test Suite 5: Enhanced Guardrails
    const guardrailTests: TestResult[] = [];
    
    const testEnhancedGuardrails = async () => {
      const tests = [
        { 
          text: "You must change your behavior now!", 
          intensity: 0.9, 
          expected: false, 
          description: "High intensity confrontational text should be filtered" 
        },
        { 
          text: "Perhaps you might consider talking gently", 
          intensity: 0.6, 
          expected: true, 
          description: "High intensity with softeners should pass" 
        },
        { 
          text: "I feel like this situation is challenging", 
          intensity: 0.3, 
          expected: true, 
          description: "Low intensity gentle language should pass" 
        }
      ];

      for (const test of tests) {
        try {
          const start = Date.now();
          const result = await suggestionsService.generateAdvancedSuggestions(test.text, 'general');
          const duration = Date.now() - start;
          
          const hasSuggestions = result.suggestions && result.suggestions.length > 0;
          const passed = test.expected === hasSuggestions;
          
          guardrailTests.push({
            name: `Enhanced Guardrails: ${test.description}`,
            description: `Text: "${test.text}"`,
            status: passed ? 'PASS' : 'FAIL',
            details: {
              expectedPass: test.expected,
              actualPass: hasSuggestions,
              suggestionsCount: result.suggestions?.length || 0,
              intensityScore: test.intensity
            },
            performance: { duration, cached: false }
          });
        } catch (error) {
          guardrailTests.push({
            name: `Enhanced Guardrails: ${test.description}`,
            description: test.description,
            status: 'FAIL',
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
    };

    await testEnhancedGuardrails();
    
    testSuites.push({
      name: 'Enhanced Guardrails',
      tests: guardrailTests,
      summary: {
        passed: guardrailTests.filter(t => t.status === 'PASS').length,
        failed: guardrailTests.filter(t => t.status === 'FAIL').length,
        skipped: guardrailTests.filter(t => t.status === 'SKIP').length,
        total: guardrailTests.length
      }
    });

    // Calculate overall summary
    const overallSummary = testSuites.reduce((acc, suite) => ({
      passed: acc.passed + suite.summary.passed,
      failed: acc.failed + suite.summary.failed,
      skipped: acc.skipped + suite.summary.skipped,
      total: acc.total + suite.summary.total
    }), { passed: 0, failed: 0, skipped: 0, total: 0 });

    // Return comprehensive test results
    res.status(200).json({
      timestamp: new Date().toISOString(),
      testRunId: `test_${Date.now()}`,
      status: overallSummary.failed === 0 ? 'PASS' : 'FAIL',
      summary: overallSummary,
      testSuites,
      recommendations: generateRecommendations(testSuites),
      metadata: {
        version: '4.0.0',
        environment: 'test',
        enhancements: [
          'Profanity Detection - Word Boundaries',
          'Context Filtering Re-enablement', 
          'Vector Retrieval Optimization',
          'JSON-driven Tone Bucket Mapping',
          'Temperature-based Calibration',
          'Enhanced Guardrails',
          'Deterministic Sorting',
          'spaCy PRON_2P Integration',
          'Performance Optimizations'
        ]
      }
    });

  } catch (error) {
    res.status(500).json({
      error: 'Test harness failed',
      message: error instanceof Error ? error.message : String(error),
      timestamp: new Date().toISOString()
    });
  }
}

function generateRecommendations(testSuites: TestSuite[]): string[] {
  const recommendations: string[] = [];
  
  for (const suite of testSuites) {
    if (suite.summary.failed > 0) {
      recommendations.push(`${suite.name}: ${suite.summary.failed} test(s) failed - review implementation`);
    }
    
    if (suite.summary.total === 0) {
      recommendations.push(`${suite.name}: No tests executed - add test coverage`);
    }
    
    // Performance recommendations
    const perfTests = suite.tests.filter(t => t.performance);
    if (perfTests.length > 0) {
      const avgDuration = perfTests.reduce((sum, t) => sum + (t.performance?.duration || 0), 0) / perfTests.length;
      if (avgDuration > 1000) {
        recommendations.push(`${suite.name}: Average response time ${avgDuration}ms is high - optimize performance`);
      }
    }
  }
  
  if (recommendations.length === 0) {
    recommendations.push('All tests passed! System is functioning correctly with new enhancements.');
  }
  
  return recommendations;
}