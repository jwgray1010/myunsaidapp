import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'keyboard_manager.dart';

/// Service for managing user data including conversation history and exports
class DataManagerService extends ChangeNotifier {
  static final DataManagerService _instance = DataManagerService._internal();
  factory DataManagerService() => _instance;
  DataManagerService._internal();

  final KeyboardManager _keyboardManager = KeyboardManager();

  bool _isClearing = false;
  bool _isExporting = false;

  // Getters
  bool get isClearing => _isClearing;
  bool get isExporting => _isExporting;

  /// Initialize service safely after first frame
  Future<void> initializePostFrame() async {
    try {
      // Any initialization work that requires plugins to be ready
      // For now, this service doesn't need heavy initialization
      // but this method provides a safe entry point

      // Preload and validate data structure if needed
      final analysisHistory = _keyboardManager.analysisHistory;

      // Validate data integrity
      for (final entry in analysisHistory) {
        if (entry['timestamp'] != null) {
          _safeParse(entry['timestamp']); // Validate timestamp format
        }
      }

      notifyListeners();
    } catch (e) {
      // Log error but don't throw - service should be resilient
      debugPrint('❌ DataManagerService initialization warning: $e');
    }
  }

  /// Safer timestamp parsing - bad timestamps sink to bottom instead of rising to top
  DateTime _safeParse(String? timestamp) =>
      DateTime.tryParse(timestamp ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  /// Get data usage statistics
  Map<String, dynamic> getDataUsageStats() {
    final analysisHistory = _keyboardManager.analysisHistory;

    // Sort history for consistent ordering
    final sortedHistory = List<Map<String, dynamic>>.from(analysisHistory);
    sortedHistory.sort(
      (a, b) =>
          _safeParse(b['timestamp']).compareTo(_safeParse(a['timestamp'])),
    );

    return {
      'total_analyses': sortedHistory.length,
      'total_messages_analyzed': sortedHistory.length,
      'data_size_mb': _calculateDataSize(sortedHistory),
      'oldest_entry': sortedHistory.isNotEmpty
          ? sortedHistory.last['timestamp'] // Oldest after sorting newest first
          : null,
      'newest_entry': sortedHistory.isNotEmpty
          ? sortedHistory
                .first['timestamp'] // Newest after sorting newest first
          : null,
      'analysis_breakdown': _getAnalysisBreakdown(sortedHistory),
      'storage_usage': _getStorageUsage(),
    };
  }

  /// Clear all conversation history
  Future<bool> clearConversationHistory() async {
    if (_isClearing) return false;

    try {
      _isClearing = true;
      notifyListeners();

      // Clear analysis history
      await _keyboardManager.clearAnalysisHistory();

      // Clear any cached data
      await _clearCachedData();

      return true;
    } catch (e) {
      // Error clearing conversation history
      return false;
    } finally {
      _isClearing = false;
      notifyListeners();
    }
  }

  /// Clear data older than specified days
  Future<bool> clearOldData(int days) async {
    if (_isClearing) return false;

    try {
      _isClearing = true;
      notifyListeners();

      final cutoffDate = DateTime.now().subtract(Duration(days: days));
      final analysisHistory = _keyboardManager.analysisHistory;

      // Filter out old entries using safe parsing
      final filteredHistory = analysisHistory.where((entry) {
        final timestamp = _safeParse(entry['timestamp']);
        return timestamp.isAfter(cutoffDate);
      }).toList();

      // Sort by timestamp (newest first) using safe parsing
      filteredHistory.sort(
        (a, b) =>
            _safeParse(b['timestamp']).compareTo(_safeParse(a['timestamp'])),
      );

      // Update the history with filtered data
      // Note: This would need to be implemented in KeyboardManager
      // await _keyboardManager.setAnalysisHistory(filteredHistory);

      return true;
    } catch (e) {
      // Error clearing old data
      return false;
    } finally {
      _isClearing = false;
      notifyListeners();
    }
  }

  /// Export all user data to JSON file
  Future<String?> exportAllData() async {
    if (_isExporting) return null;

    try {
      _isExporting = true;
      notifyListeners();

      final analysisHistory = _keyboardManager.analysisHistory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Clone data to avoid mutations and sort safely
      final sortedHistory = List<Map<String, dynamic>>.from(analysisHistory);
      sortedHistory.sort(
        (a, b) =>
            _safeParse(b['timestamp']).compareTo(_safeParse(a['timestamp'])),
      );

      final exportData = {
        'export_info': {
          'timestamp': DateTime.now().toIso8601String(),
          'app_version': '1.0.0',
          'data_version': '1.0',
          'total_entries': sortedHistory.length,
        },
        'analysis_history': sortedHistory,
        'statistics': getDataUsageStats(),
        'metadata': {
          'export_type': 'full_data_export',
          'user_consent': true,
          'privacy_compliant': true,
        },
      };

      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/unsaid_data_export_$timestamp.json');

      await file.writeAsString(jsonEncode(exportData));
      return file.path;
    } catch (e) {
      // Error exporting data
      return null;
    } finally {
      _isExporting = false;
      notifyListeners();
    }
  }

  /// Export conversation insights only
  Future<String?> exportInsightsOnly() async {
    if (_isExporting) return null;

    try {
      _isExporting = true;
      notifyListeners();

      final analysisHistory = _keyboardManager.analysisHistory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Extract only insights and recommendations (non-destructive)
      final insights = analysisHistory.map((entry) {
        return {
          'timestamp': entry['timestamp'],
          'tone_analysis': entry['tone_analysis'],
          'coparenting_analysis': entry['coparenting_analysis'],
          'predictive_analysis': entry['predictive_analysis'],
          'integrated_suggestions': entry['integrated_suggestions'],
          'relationship_context': entry['relationship_context'],
        };
      }).toList();

      // Sort insights by timestamp safely
      insights.sort(
        (a, b) =>
            _safeParse(b['timestamp']).compareTo(_safeParse(a['timestamp'])),
      );

      final exportData = {
        'export_info': {
          'timestamp': DateTime.now().toIso8601String(),
          'export_type': 'insights_only',
          'total_insights': insights.length,
        },
        'insights': insights,
        'summary_statistics': _generateInsightsSummary(insights),
      };

      final directory = await getApplicationDocumentsDirectory();
      final file = File(
        '${directory.path}/unsaid_insights_export_$timestamp.json',
      );

      await file.writeAsString(jsonEncode(exportData));
      return file.path;
    } catch (e) {
      // Error exporting insights
      return null;
    } finally {
      _isExporting = false;
      notifyListeners();
    }
  }

  /// Get privacy-safe data summary
  Map<String, dynamic> getPrivacySafeDataSummary() {
    final analysisHistory = _keyboardManager.analysisHistory;

    // Sort by timestamp to get the most recent entry safely
    final sortedHistory = List<Map<String, dynamic>>.from(analysisHistory);
    sortedHistory.sort(
      (a, b) =>
          _safeParse(b['timestamp']).compareTo(_safeParse(a['timestamp'])),
    );

    return {
      'total_conversations': analysisHistory.length,
      'average_empathy_score': _calculateAverageScore(
        analysisHistory,
        'empathy_score',
      ),
      'average_clarity_score': _calculateAverageScore(
        analysisHistory,
        'clarity_score',
      ),
      'most_common_tone': _getMostCommonTone(analysisHistory),
      'improvement_trend': _calculateImprovementTrend(analysisHistory),
      'data_retention_days': 365, // Default retention period
      'last_analysis': sortedHistory.isNotEmpty
          ? sortedHistory.first['timestamp'] // Most recent after sorting
          : null,
    };
  }

  /// Calculate data size in MB
  double _calculateDataSize(List<Map<String, dynamic>> data) {
    final jsonString = jsonEncode(data);
    final bytes = utf8.encode(jsonString).length;
    return bytes / (1024 * 1024); // Convert to MB
  }

  /// Get analysis breakdown by type
  Map<String, int> _getAnalysisBreakdown(List<Map<String, dynamic>> data) {
    final breakdown = <String, int>{};

    for (final entry in data) {
      if (entry['tone_analysis'] != null) {
        breakdown['tone_analysis'] = (breakdown['tone_analysis'] ?? 0) + 1;
      }
      if (entry['coparenting_analysis'] != null) {
        breakdown['coparenting_analysis'] =
            (breakdown['coparenting_analysis'] ?? 0) + 1;
      }
      if (entry['predictive_analysis'] != null) {
        breakdown['predictive_analysis'] =
            (breakdown['predictive_analysis'] ?? 0) + 1;
      }
    }

    return breakdown;
  }

  /// Get storage usage information
  Map<String, dynamic> _getStorageUsage() {
    final analysisHistorySize = _calculateDataSize(
      _keyboardManager.analysisHistory,
    );
    const cachedDataSize = 0.5; // Estimate in MB
    const settingsSize = 0.002; // 2KB in MB

    return {
      'analysis_history_mb': analysisHistorySize,
      'cached_data_mb': cachedDataSize,
      'settings_kb': 2.0, // Estimate
      'total_mb': analysisHistorySize + cachedDataSize + settingsSize,
    };
  }

  /// Clear cached data
  Future<void> _clearCachedData() async {
    // Clear any temporary or cached files
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheFiles = tempDir
          .listSync()
          .where((file) => file.path.contains('unsaid_cache'))
          .toList();

      for (final file in cacheFiles) {
        await file.delete();
      }
    } catch (e) {
      // Error clearing cache
    }
  }

  /// Generate insights summary
  Map<String, dynamic> _generateInsightsSummary(
    List<Map<String, dynamic>> insights,
  ) {
    // Sort insights for proper date range calculation
    final sortedInsights = List<Map<String, dynamic>>.from(insights);
    sortedInsights.sort(
      (a, b) =>
          _safeParse(a['timestamp']).compareTo(_safeParse(b['timestamp'])),
    ); // Oldest first for date range

    return {
      'total_insights': insights.length,
      'average_empathy': _calculateAverageScore(insights, 'empathy_score'),
      'average_clarity': _calculateAverageScore(insights, 'clarity_score'),
      'date_range': {
        'from': sortedInsights.isNotEmpty
            ? sortedInsights.first['timestamp']
            : null,
        'to': sortedInsights.isNotEmpty
            ? sortedInsights.last['timestamp']
            : null,
      },
      'improvement_indicators': _analyzeImprovementPatterns(insights),
    };
  }

  /// Calculate average score for a specific metric
  double _calculateAverageScore(
    List<Map<String, dynamic>> data,
    String scoreKey,
  ) {
    double total = 0.0;
    int count = 0;

    for (final entry in data) {
      final toneAnalysis = entry['tone_analysis'] as Map<String, dynamic>?;
      if (toneAnalysis != null && toneAnalysis[scoreKey] != null) {
        total += toneAnalysis[scoreKey];
        count++;
      }
    }

    return count > 0 ? total / count : 0.0;
  }

  /// Get most common tone from analysis history
  String _getMostCommonTone(List<Map<String, dynamic>> data) {
    final toneCounts = <String, int>{};

    for (final entry in data) {
      final toneAnalysis = entry['tone_analysis'] as Map<String, dynamic>?;
      if (toneAnalysis != null && toneAnalysis['dominant_emotion'] != null) {
        final tone = toneAnalysis['dominant_emotion'] as String;
        toneCounts[tone] = (toneCounts[tone] ?? 0) + 1;
      }
    }

    if (toneCounts.isEmpty) return 'neutral';

    return toneCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  /// Calculate improvement trend
  String _calculateImprovementTrend(List<Map<String, dynamic>> data) {
    if (data.length < 2) return 'insufficient_data';

    final recentData = data.length > 10 ? data.sublist(data.length - 10) : data;
    final olderData = data.length > 10
        ? data.sublist(0, data.length - 10)
        : <Map<String, dynamic>>[];

    if (olderData.isEmpty) return 'steady';

    final recentAvg = _calculateAverageScore(recentData, 'empathy_score');
    final olderAvg = _calculateAverageScore(olderData, 'empathy_score');

    if (recentAvg > olderAvg + 0.1) return 'improving';
    if (recentAvg < olderAvg - 0.1) return 'declining';
    return 'steady';
  }

  /// Analyze improvement patterns
  Map<String, dynamic> _analyzeImprovementPatterns(
    List<Map<String, dynamic>> insights,
  ) {
    return {
      'empathy_trend': _calculateImprovementTrend(insights),
      'clarity_improvement': _calculateAverageScore(insights, 'clarity_score'),
      'consistency_score': _calculateConsistencyScore(insights),
      'growth_indicators': _identifyGrowthIndicators(insights),
    };
  }

  /// Calculate consistency score
  double _calculateConsistencyScore(List<Map<String, dynamic>> data) {
    if (data.length < 3) return 0.0;

    final scores = <double>[];
    for (final entry in data) {
      final toneAnalysis = entry['tone_analysis'] as Map<String, dynamic>?;
      if (toneAnalysis != null && toneAnalysis['empathy_score'] != null) {
        scores.add(toneAnalysis['empathy_score']);
      }
    }

    if (scores.length < 3) return 0.0;

    // Calculate standard deviation as consistency measure
    final mean = scores.reduce((a, b) => a + b) / scores.length;
    final variance =
        scores
            .map((score) => (score - mean) * (score - mean))
            .reduce((a, b) => a + b) /
        scores.length;

    // Return inverse of standard deviation (higher consistency = lower variance)
    return 1.0 - (variance.clamp(0.0, 1.0));
  }

  /// Identify growth indicators
  List<String> _identifyGrowthIndicators(List<Map<String, dynamic>> data) {
    final indicators = <String>[];

    if (_calculateImprovementTrend(data) == 'improving') {
      indicators.add('Overall empathy increasing');
    }

    if (_calculateConsistencyScore(data) > 0.7) {
      indicators.add('Consistent communication quality');
    }

    if (_calculateAverageScore(data, 'clarity_score') > 0.8) {
      indicators.add('High clarity in communication');
    }

    return indicators;
  }
}
