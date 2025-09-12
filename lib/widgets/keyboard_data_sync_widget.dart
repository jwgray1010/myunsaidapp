import 'package:flutter/material.dart';
import '../services/keyboard_data_service.dart';

/// Widget that automatically syncs keyboard data when the app becomes active
/// Place this in your app's main widget tree to enable automatic data sync
class KeyboardDataSyncWidget extends StatefulWidget {
  final Widget child;
  final Function(KeyboardAnalyticsData)? onDataReceived;
  final Function(String)? onError;
  final bool enableAutoSync;
  final Duration syncInterval;

  const KeyboardDataSyncWidget({
    super.key,
    required this.child,
    this.onDataReceived,
    this.onError,
    this.enableAutoSync = true,
    this.syncInterval = const Duration(minutes: 5),
  });

  @override
  State<KeyboardDataSyncWidget> createState() => _KeyboardDataSyncWidgetState();
}

class _KeyboardDataSyncWidgetState extends State<KeyboardDataSyncWidget>
    with WidgetsBindingObserver {
  final KeyboardDataService _keyboardDataService = KeyboardDataService();
  bool _isSyncing = false;
  bool _isNewUser = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Perform initial sync when widget is created
    if (widget.enableAutoSync) {
      _performInitialSync();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }


  /// Perform initial data sync when app starts
  Future<void> _performInitialSync() async {
    // Small delay to let the app fully initialize
    await Future.delayed(const Duration(milliseconds: 500));
    await _performDataSync();
  }

  /// Check if this appears to be a new user
  bool _detectNewUser(Map<String, dynamic>? metadata) {
    if (metadata == null) return true;

    final totalItems = metadata['total_items'] ?? 0;
    final lastChecked = metadata['last_checked'] ?? 0;
    final interactionCount = metadata['interaction_count'] ?? 0;

    // Consider new user if no items and either no last check or very recent
    return totalItems == 0 &&
        interactionCount == 0 &&
        (lastChecked == 0 ||
            DateTime.now().millisecondsSinceEpoch / 1000.0 - lastChecked <
                3600);
  }

  /// Perform keyboard data sync
  Future<void> _performDataSync() async {
    if (_isSyncing) return; // Prevent concurrent syncs

    setState(() {
      _isSyncing = true;
    });

    try {
      debugPrint('🔄 KeyboardDataSyncWidget: Starting data sync...');

      // Check for pending data first with timeout protection
      final metadata = await _keyboardDataService
          .getKeyboardStorageMetadata()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              debugPrint(
                '⏱️ KeyboardDataSyncWidget: Metadata request timed out',
              );
              return null;
            },
          );

      // Detect if this is a new user for better UX
      _isNewUser = _detectNewUser(metadata);

      // Safe handling of null metadata
      if (metadata == null) {
        if (_isNewUser) {
          debugPrint(
            '👋 KeyboardDataSyncWidget: Welcome! Start using the keyboard to see data sync.',
          );
        } else {
          debugPrint(
            'ℹ️ KeyboardDataSyncWidget: No metadata available (error occurred)',
          );
        }
        return;
      }

      final hasPendingData = metadata['has_pending_data'] == true;
      final totalItems = metadata['total_items'] ?? 0;

      if (!hasPendingData || totalItems == 0) {
        if (_isNewUser) {
          debugPrint(
            '👋 KeyboardDataSyncWidget: New user detected - no data to sync yet. Start typing to generate data!',
          );
        } else {
          debugPrint(
            '✅ KeyboardDataSyncWidget: No pending data to sync (total_items: $totalItems)',
          );
        }
        return;
      }

      debugPrint('📊 KeyboardDataSyncWidget: Found $totalItems items to sync');

      // Retrieve keyboard data with timeout
      final keyboardData = await _keyboardDataService
          .retrievePendingKeyboardData()
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              debugPrint('⏱️ KeyboardDataSyncWidget: Data retrieval timed out');
              return null;
            },
          );

      if (keyboardData != null && keyboardData.hasData) {
        debugPrint(
          '📥 KeyboardDataSyncWidget: Retrieved ${keyboardData.totalItems} items',
        );

        // Process the data
        await _keyboardDataService.processKeyboardData(keyboardData);

        // Notify callback if provided
        widget.onDataReceived?.call(keyboardData);

        // Clear the data
        final cleared = await _keyboardDataService
            .clearPendingKeyboardData()
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                debugPrint(
                  '⏱️ KeyboardDataSyncWidget: Clear operation timed out',
                );
                return false;
              },
            );

        if (cleared) {
          debugPrint(
            '✅ KeyboardDataSyncWidget: Data sync completed successfully',
          );
        } else {
          debugPrint(
            '⚠️ KeyboardDataSyncWidget: Warning - data not cleared after sync',
          );
        }
      } else {
        debugPrint(
          'ℹ️ KeyboardDataSyncWidget: No keyboard data to process (empty result)',
        );
      }
    } catch (e) {
      debugPrint('❌ KeyboardDataSyncWidget: Data sync error: $e');
      widget.onError?.call(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// Extension to add keyboard data sync to any app
/// Usage: Wrap your MaterialApp with this widget
class KeyboardDataSyncApp extends StatelessWidget {
  final Widget app;
  final Function(KeyboardAnalyticsData)? onDataReceived;
  final Function(String)? onError;

  const KeyboardDataSyncApp({
    super.key,
    required this.app,
    this.onDataReceived,
    this.onError,
  });

  @override
  Widget build(BuildContext context) {
    return KeyboardDataSyncWidget(
      onDataReceived: onDataReceived,
      onError: onError,
      child: app,
    );
  }
}

/// Service extension for manual data sync operations
extension KeyboardDataManualSync on KeyboardDataService {
  /// Manually trigger a data sync (useful for testing)
  static Future<void> manualSync() async {
    final service = KeyboardDataService();
    final success = await service.performDataSync();

    if (success) {
      debugPrint('✅ Manual keyboard data sync completed');
    } else {
      debugPrint('❌ Manual keyboard data sync failed');
    }
  }

  /// Check if there's pending keyboard data
  static Future<bool> hasPendingData() async {
    final service = KeyboardDataService();
    final metadata = await service.getKeyboardStorageMetadata();
    return metadata?['has_pending_data'] == true;
  }

  /// Get summary of pending data
  static Future<String> getPendingDataSummary() async {
    final service = KeyboardDataService();
    final metadata = await service.getKeyboardStorageMetadata();

    if (metadata == null) return 'No metadata available';

    final interactions = metadata['total_interactions'] ?? 0;
    final toneData = metadata['total_tone_data'] ?? 0;
    final suggestions = metadata['total_suggestions'] ?? 0;
    final analytics = metadata['total_analytics'] ?? 0;

    return 'Pending: $interactions interactions, $toneData tone analyses, $suggestions suggestions, $analytics analytics';
  }
}
