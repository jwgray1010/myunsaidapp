import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'personality_data_bridge.dart';

/// Unified manager that routes calls to the correct method channels:
/// - Keyboard data -> 'com.unsaid/keyboard_data_sync'
/// - Personality data -> 'com.unsaid/personality_data'
class PersonalityDataManager {
  static PersonalityDataManager? _instance;
  static PersonalityDataManager get shared =>
      _instance ??= PersonalityDataManager._();
  PersonalityDataManager._();

  // Keep keyboard data on the keyboard channel
  static const MethodChannel _keyboardChannel = MethodChannel(
    'com.unsaid/keyboard_data_sync',
  );

  // Personality data uses dedicated channel via PersonalityDataBridge
  // (no need to redeclare the channel here)

  // -------- Keyboard storage methods (unchanged channel) --------

  Future<Map<String, dynamic>?> collectKeyboardAnalytics() async {
    try {
      if (!Platform.isIOS) return null;
      final data = await _keyboardChannel.invokeMethod(
        'getAllPendingKeyboardData',
      );
      if (data is Map) {
        final analytics = Map<String, dynamic>.from(data);
        if (kDebugMode) {
          print(
            '✅ Collected keyboard analytics - ${analytics['metadata']?['total_items'] ?? 0} total items',
          );
        }
        return analytics;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error collecting keyboard analytics: $e');
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> getKeyboardStorageMetadata() async {
    try {
      if (!Platform.isIOS) return null;
      final meta = await _keyboardChannel.invokeMethod(
        'getKeyboardStorageMetadata',
      );
      if (meta is Map) {
        final m = Map<String, dynamic>.from(meta);
        if (kDebugMode) {
          print('📊 Storage metadata: ${m['total_items']} items across queues');
        }
        return m;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting storage metadata: $e');
      }
    }
    return null;
  }

  Future<bool> clearProcessedKeyboardData() async {
    try {
      if (!Platform.isIOS) return false;
      final res = await _keyboardChannel.invokeMethod(
        'clearAllPendingKeyboardData',
      );
      final success = (res as bool?) ?? false;
      if (kDebugMode) {
        print(
          success
              ? '✅ Cleared pending keyboard data'
              : '⚠️ Failed to clear keyboard data',
        );
      }
      return success;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error clearing keyboard data: $e');
      }
      return false;
    }
  }

  Future<Map<String, dynamic>?> getKeyboardUserData() async {
    try {
      if (!Platform.isIOS) return null;
      final ud = await _keyboardChannel.invokeMethod('getUserData');
      return (ud is Map) ? Map<String, dynamic>.from(ud) : null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting keyboard user data: $e');
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> getKeyboardAPIData() async {
    try {
      if (!Platform.isIOS) return null;
      final api = await _keyboardChannel.invokeMethod('getAPIData');
      return (api is Map) ? Map<String, dynamic>.from(api) : null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting keyboard API data: $e');
      }
      return null;
    }
  }

  // -------- Personality methods (routed to PersonalityDataBridge) --------

  Future<void> storePersonalityData(
    Map<String, dynamic> personalityData,
  ) async {
    await PersonalityDataBridge.storePersonalityData(personalityData);
  }

  Future<void> setUserEmotionalState({
    required String state,
    required String bucket,
    required String label,
  }) async {
    await PersonalityDataBridge.setUserEmotionalState(
      state: state,
      bucket: bucket,
      label: label,
    );
  }

  Future<String> getUserEmotionalState() async {
    return await PersonalityDataBridge.getUserEmotionalState();
  }

  Future<String> getUserEmotionalBucket() async {
    return await PersonalityDataBridge.getUserEmotionalBucket();
  }

  Future<void> storePersonalityTestResults(Map<String, dynamic> results) async {
    await PersonalityDataBridge.storePersonalityTestResults(results);
  }

  Future<void> storePersonalityComponents(
    Map<String, dynamic> components,
  ) async {
    await PersonalityDataBridge.storePersonalityComponents(components);
  }

  Future<Map<String, dynamic>> getPersonalityData() async {
    return await PersonalityDataBridge.getPersonalityData();
  }

  Future<Map<String, dynamic>> getPersonalityTestResults() async {
    return await PersonalityDataBridge.getPersonalityTestResults();
  }

  Future<String> getDominantPersonalityType() async {
    return await PersonalityDataBridge.getDominantPersonalityType();
  }

  Future<String> getPersonalityTypeLabel() async {
    return await PersonalityDataBridge.getPersonalityTypeLabel();
  }

  Future<Map<String, int>> getPersonalityScores() async {
    return await PersonalityDataBridge.getPersonalityScores();
  }

  Future<String> generatePersonalityContext() async {
    return await PersonalityDataBridge.generatePersonalityContext();
  }

  Future<Map<String, dynamic>> generatePersonalityContextDictionary() async {
    return await PersonalityDataBridge.generatePersonalityContextDictionary();
  }

  Future<bool> isPersonalityTestComplete() async {
    return await PersonalityDataBridge.isPersonalityTestComplete();
  }

  Future<bool> clearPersonalityData() async {
    return await PersonalityDataBridge.clearPersonalityData();
  }

  Future<void> debugPersonalityData() async {
    await PersonalityDataBridge.debugPersonalityData();
  }

  // -------- Analysis methods with safer timestamp handling --------

  /// Convert various timestamp formats to milliseconds
  int _toMillis(dynamic ts) {
    if (ts == null) return 0;
    if (ts is int) return ts < 1e12 ? ts * 1000 : ts; // sec -> ms
    if (ts is double) return (ts < 1e12 ? ts * 1000 : ts).round();
    if (ts is String) {
      final n = int.tryParse(ts) ?? 0;
      return n < 1e12 ? n * 1000 : n;
    }
    return 0;
  }

  /// Calculate data quality score including api_suggestions
  double _calculateDataQuality(Map<String, dynamic> rawData) {
    double score = 0.0;
    int factors = 0;

    for (final category in [
      'interactions',
      'tone_data',
      'suggestions',
      'analytics',
      'api_suggestions',
    ]) {
      final data = rawData[category] as List<dynamic>? ?? const [];
      if (data.isNotEmpty) score += 0.2; // 5 buckets -> 1.0 max
      factors++;
    }

    final metadata = rawData['metadata'] as Map<String, dynamic>? ?? {};
    if ((metadata['total_items'] as num? ?? 0) > 0) {
      score = (score + 0.1).clamp(0.0, 1.0);
    }
    return factors > 0 ? score : 0.0;
  }

  /// Analyze usage patterns with safer timestamp handling
  Map<String, dynamic> _analyzeUsagePatterns(Map<String, dynamic> rawData) {
    final Map<String, int> timeDistribution = {};
    final Map<String, int> dayDistribution = {};
    int totalEvents = 0;

    // Process all data categories
    for (final category in [
      'interactions',
      'tone_data',
      'suggestions',
      'analytics',
      'api_suggestions',
    ]) {
      final events = rawData[category] as List<dynamic>? ?? [];

      for (final event in events) {
        if (event is! Map<String, dynamic>) continue;

        final raw = event['timestamp'];
        final ms = _toMillis(raw);
        if (ms > 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(ms);
          final hour = dt.hour;
          final day = dt.weekday;

          final slot = _getTimeSlot(hour);
          timeDistribution[slot] = (timeDistribution[slot] ?? 0) + 1;

          final dayName = _getDayName(day);
          dayDistribution[dayName] = (dayDistribution[dayName] ?? 0) + 1;

          totalEvents++;
        }
      }
    }

    return {
      'time_distribution': timeDistribution,
      'day_distribution': dayDistribution,
      'total_events': totalEvents,
      'most_active_time': _getMostActive(timeDistribution),
      'most_active_day': _getMostActive(dayDistribution),
    };
  }

  String _getTimeSlot(int hour) {
    if (hour >= 6 && hour < 12) return 'morning';
    if (hour >= 12 && hour < 18) return 'afternoon';
    if (hour >= 18 && hour < 22) return 'evening';
    return 'night';
  }

  String _getDayName(int day) {
    const days = [
      '',
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];
    return (day >= 0 && day < days.length) ? days[day] : 'unknown';
  }

  String _getMostActive(Map<String, int> distribution) {
    if (distribution.isEmpty) return 'unknown';
    return distribution.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  /// Get comprehensive analysis including keyboard and personality data
  Future<Map<String, dynamic>> getComprehensiveAnalysis() async {
    try {
      // Get keyboard data
      final keyboardData = await collectKeyboardAnalytics() ?? {};
      final metadata = await getKeyboardStorageMetadata() ?? {};

      // Get personality data
      final personalityData = await getPersonalityData();
      final isComplete = await isPersonalityTestComplete();

      // Analyze patterns
      final usagePatterns = _analyzeUsagePatterns(keyboardData);
      final dataQuality = _calculateDataQuality(keyboardData);

      return {
        'keyboard_data': keyboardData,
        'keyboard_metadata': metadata,
        'personality_data': personalityData,
        'personality_complete': isComplete,
        'usage_patterns': usagePatterns,
        'data_quality': dataQuality,
        'analysis_timestamp': DateTime.now().toIso8601String(),
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error in comprehensive analysis: $e');
      }
      return {
        'error': e.toString(),
        'analysis_timestamp': DateTime.now().toIso8601String(),
      };
    }
  }

  /// Check if keyboard data is available
  Future<bool> hasKeyboardDataAvailable() async {
    try {
      final metadata = await getKeyboardStorageMetadata();
      if (metadata != null) {
        final totalItems = metadata['total_items'] as num? ?? 0;
        return totalItems > 0;
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking keyboard data availability: $e');
      }
      return false;
    }
  }

  /// Perform startup keyboard analysis
  Future<Map<String, dynamic>> performStartupKeyboardAnalysis() async {
    try {
      return await getComprehensiveAnalysis();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error in startup keyboard analysis: $e');
      }
      return {
        'error': e.toString(),
        'analysis_timestamp': DateTime.now().toIso8601String(),
      };
    }
  }
}
