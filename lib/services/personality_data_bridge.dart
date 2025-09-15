import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Flutter bridge to connect with PersonalityDataBridge.swift
/// Uses the 'com.unsaid/personality_data' method channel
class PersonalityDataBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.unsaid/personality_data',
  );

  /// Store personality data to iOS shared storage
  static Future<bool> storePersonalityData(
    Map<String, dynamic> personalityData,
  ) async {
    try {
      if (!Platform.isIOS) return true; // No-op on non-iOS platforms

      final result = await _channel.invokeMethod(
        'storePersonalityData',
        personalityData,
      );
      if (kDebugMode) {
        print('✅ PersonalityDataBridge: Stored personality data');
      }
      return (result as bool?) ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error storing personality data: $e');
      }
      return false;
    }
  }

  /// Get personality data from iOS shared storage (null-safe)
  static Future<Map<String, dynamic>> getPersonalityData() async {
    try {
      if (!Platform.isIOS) return <String, dynamic>{};

      final data = await _channel.invokeMethod('getPersonalityData');
      if (data is Map) {
        // Safely convert Map<Object?, Object?> to Map<String, dynamic>
        final converted = <String, dynamic>{};
        data.forEach((key, value) {
          if (key != null) {
            converted[key.toString()] = value;
          }
        });
        if (kDebugMode) {
          print(
            '✅ PersonalityDataBridge: Retrieved personality data with ${converted.keys.length} keys',
          );
        }
        return converted;
      }
      return <String, dynamic>{};
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting personality data: $e');
      }
      return <String, dynamic>{};
    }
  }

  /// Check if personality test is complete
  static Future<bool> isPersonalityTestComplete() async {
    try {
      if (!Platform.isIOS) return false;

      final result = await _channel.invokeMethod('isPersonalityTestComplete');
      return (result as bool?) ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error checking test completion: $e');
      }
      return false;
    }
  }

  /// Store emotional state
  static Future<void> setUserEmotionalState({
    required String state,
    required String bucket,
    required String label,
  }) async {
    try {
      if (!Platform.isIOS) return;

      await _channel.invokeMethod('setUserEmotionalState', {
        'state': state,
        'bucket': bucket,
        'label': label,
      });
      if (kDebugMode) {
        print(
          '✅ PersonalityDataBridge: Set emotional state - $label ($bucket)',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error setting emotional state: $e');
      }
    }
  }

  /// Get current emotional state
  static Future<String> getUserEmotionalState() async {
    try {
      if (!Platform.isIOS) return 'neutral_distracted';

      final result = await _channel.invokeMethod('getUserEmotionalState');
      return (result as String?) ?? 'neutral_distracted';
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting emotional state: $e');
      }
      return 'neutral_distracted';
    }
  }

  /// Get current emotional bucket
  static Future<String> getUserEmotionalBucket() async {
    try {
      if (!Platform.isIOS) return 'moderate';

      final result = await _channel.invokeMethod('getUserEmotionalBucket');
      return (result as String?) ?? 'moderate';
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting emotional bucket: $e');
      }
      return 'moderate';
    }
  }

  /// Store personality test results
  static Future<void> storePersonalityTestResults(
    Map<String, dynamic> results,
  ) async {
    try {
      if (!Platform.isIOS) return;

      await _channel.invokeMethod('storePersonalityTestResults', results);
      if (kDebugMode) {
        print('✅ PersonalityDataBridge: Stored personality test results');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error storing test results: $e');
      }
    }
  }

  /// Store personality components
  static Future<void> storePersonalityComponents(
    Map<String, dynamic> components,
  ) async {
    try {
      if (!Platform.isIOS) return;

      await _channel.invokeMethod('storePersonalityComponents', components);
      if (kDebugMode) {
        print('✅ PersonalityDataBridge: Stored personality components');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error storing components: $e');
      }
    }
  }

  /// Get personality test results
  static Future<Map<String, dynamic>> getPersonalityTestResults() async {
    try {
      if (!Platform.isIOS) return <String, dynamic>{};

      final data = await _channel.invokeMethod('getPersonalityTestResults');
      if (data is Map) {
        // Safely convert Map<Object?, Object?> to Map<String, dynamic>
        final converted = <String, dynamic>{};
        data.forEach((key, value) {
          if (key != null) {
            converted[key.toString()] = value;
          }
        });
        return converted;
      }
      return <String, dynamic>{};
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting test results: $e');
      }
      return <String, dynamic>{};
    }
  }

  /// Get dominant personality type
  static Future<String> getDominantPersonalityType() async {
    try {
      if (!Platform.isIOS) return 'B';

      final result = await _channel.invokeMethod('getDominantPersonalityType');
      return (result as String?) ?? 'B';
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting dominant type: $e');
      }
      return 'B';
    }
  }

  /// Get personality type label
  static Future<String> getPersonalityTypeLabel() async {
    try {
      if (!Platform.isIOS) return 'Secure Attachment';

      final result = await _channel.invokeMethod('getPersonalityTypeLabel');
      return (result as String?) ?? 'Secure Attachment';
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting type label: $e');
      }
      return 'Secure Attachment';
    }
  }

  /// Get personality scores
  static Future<Map<String, int>> getPersonalityScores() async {
    try {
      if (!Platform.isIOS) return <String, int>{};

      final result = await _channel.invokeMethod('getPersonalityScores');
      if (result is Map) {
        return Map<String, int>.from(
          result.map(
            (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
          ),
        );
      }
      return <String, int>{};
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error getting scores: $e');
      }
      return <String, int>{};
    }
  }

  /// Generate personality context string
  static Future<String> generatePersonalityContext() async {
    try {
      if (!Platform.isIOS) {
        return 'Type B (Secure Attachment), Attachment Secure';
      }

      final result = await _channel.invokeMethod('generatePersonalityContext');
      return (result as String?) ??
          'Type B (Secure Attachment), Attachment Secure';
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error generating context: $e');
      }
      return 'Type B (Secure Attachment), Attachment Secure';
    }
  }

  /// Generate personality context dictionary
  static Future<Map<String, dynamic>>
  generatePersonalityContextDictionary() async {
    try {
      if (!Platform.isIOS) return <String, dynamic>{};

      final result = await _channel.invokeMethod(
        'generatePersonalityContextDictionary',
      );
      if (result is Map) {
        // Safely convert Map<Object?, Object?> to Map<String, dynamic>
        final converted = <String, dynamic>{};
        result.forEach((key, value) {
          if (key != null) {
            converted[key.toString()] = value;
          }
        });
        return converted;
      }
      return <String, dynamic>{};
    } catch (e) {
      if (kDebugMode) {
        print(
          '❌ PersonalityDataBridge: Error generating context dictionary: $e',
        );
      }
      return <String, dynamic>{};
    }
  }

  /// Clear all personality data
  static Future<bool> clearPersonalityData() async {
    try {
      if (!Platform.isIOS) return true;

      final result = await _channel.invokeMethod('clearPersonalityData');
      if (kDebugMode) {
        print('✅ PersonalityDataBridge: Cleared personality data');
      }
      return (result as bool?) ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error clearing data: $e');
      }
      return false;
    }
  }

  /// Debug personality data (unified method name)
  static Future<void> debugPersonalityData() async {
    try {
      if (!Platform.isIOS) return;

      await _channel.invokeMethod('debugPersonalityData');
      if (kDebugMode) {
        print('✅ PersonalityDataBridge: Debug output triggered');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error in debug output: $e');
      }
    }
  }

  /// Set test personality data (for debugging)
  static Future<void> setTestPersonalityData() async {
    try {
      if (!Platform.isIOS) return;

      await _channel.invokeMethod('setTestPersonalityData');
      if (kDebugMode) {
        print('✅ PersonalityDataBridge: Set test personality data');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ PersonalityDataBridge: Error setting test data: $e');
      }
    }
  }
}
