import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'keyboard_extension.dart';
import 'secure_config.dart';
import 'conversation_data_service.dart';
import 'keyboard_data_service.dart';
import 'package:flutter/services.dart';

class KeyboardManager extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'com.unsaid/keyboard_analytics',
  );

  static final KeyboardManager _instance = KeyboardManager._internal();
  factory KeyboardManager() => _instance;
  KeyboardManager._internal();

  // Keyboard state
  bool _isKeyboardInstalled = false;
  bool _isKeyboardEnabled = false;
  bool _isKeyboardActive = false;
  Map<String, dynamic> _keyboardSettings = {};

  // Getters
  bool get isKeyboardInstalled => _isKeyboardInstalled;
  bool get isKeyboardEnabled => _isKeyboardEnabled;
  bool get isKeyboardActive => _isKeyboardActive;
  Map<String, dynamic> get keyboardSettings => Map.from(_keyboardSettings);

  // Default keyboard settings
  static const Map<String, dynamic> _defaultSettings = {
    'toneDetection': true,
    'smartSuggestions': true,
    'hapticFeedback': true,
    'soundFeedback': false,
    'keyboardTheme': 'auto',
    'keySize': 'medium',
    'showNumbers': true,
    'showEmojis': true,
    'swipeGestures': true,
    'autoCorrect': true,
    'predictiveText': true,
    'sensitivity': 0.5,
    'tone': 'neutral',
    'relationshipContext': 'Dating',
    'attachmentStyle': 'Secure Attachment',
    'communicationStyle': 'Secure Attachment',
    'profanityLevel': 2,
    'sarcasmLevel': 2,
  };

  // Store recent emotion/tone history for analytics
  final List<Map<String, dynamic>> _toneHistory = [];
  List<Map<String, dynamic>> get toneHistory => List.unmodifiable(_toneHistory);

  // Keyboard data service for retrieving stored data from keyboard extension
  final KeyboardDataService _keyboardDataService = KeyboardDataService();

  // Conversation service for storing interaction data
  final ConversationDataService _conversationService =
      ConversationDataService();

  // Store trigger/conflict words for alerts
  static const List<String> _triggerWords = [
    'always',
    'never',
    'never',
    'fault',
    'blame',
    'stupid',
    'hate',
    'useless',
    'idiot',
    'liar',
    'selfish',
    'custody',
    'court',
    'lawyer',
    'threat',
    'danger',
    'abuse',
    'unsafe',
    'neglect',
    'harm',
    'fight',
    'argue',
    'problem',
    'issue',
    'bad parent',
    'unfit',
    'take away',
    'lose',
    'win',
    'lose custody',
    'police',
    'report',
    'restraining order',
  ];

  // Privacy: all analysis is on-device unless user opts in to cloud
  bool _onDeviceProcessing = true;
  bool get onDeviceProcessing => _onDeviceProcessing;
  void setOnDeviceProcessing(bool value) {
    _onDeviceProcessing = value;
    notifyListeners();
  }

  // Feedback loop: user can rate suggestions
  final List<Map<String, dynamic>> _suggestionFeedback = [];
  void addSuggestionFeedback(String original, String suggestion, int rating) {
    _suggestionFeedback.add({
      'original': original,
      'suggestion': suggestion,
      'rating': rating,
      'timestamp': DateTime.now().toIso8601String(),
    });
    notifyListeners();
  }

  // Add to tone history (call after each analysis)
  void addToneHistory(Map<String, dynamic> analysis) {
    _toneHistory.add({
      ...analysis,
      'timestamp': DateTime.now().toIso8601String(),
    });
    if (_toneHistory.length > 50) _toneHistory.removeAt(0); // keep last 50

    // Store in conversation service for deeper analytics
    _storeAnalysisForConversation(analysis);

    notifyListeners();
  }

  // Store analysis data for conversation tracking
  Future<void> _storeAnalysisForConversation(
    Map<String, dynamic> analysis,
  ) async {
    try {
      final messageData = {
        'text': analysis['original_message'] ?? analysis['original_text'] ?? '',
        'tone_analysis': analysis,
        'timestamp': DateTime.now().toIso8601String(),
        'user_id': 'current_user', // Replace with actual user ID
        'source': 'keyboard',
      };

      // Create or append to today's conversation
      final today = DateTime.now();
      final conversationId = 'daily_${today.year}_${today.month}_${today.day}';

      await _conversationService.storeMessage(conversationId, messageData);
    } catch (e) {
      debugPrint('Error storing analysis for conversation: $e');
    }
  }

  // Detect trigger/conflict words in a message
  List<String> detectTriggerWords(String text) {
    final lower = text.toLowerCase();
    return _triggerWords.where((w) => lower.contains(w)).toList();
  }

  // Detect if message is escalating (conflict/disagreement)
  bool isEscalating(String text) {
    final triggers = detectTriggerWords(text);
    return triggers.isNotEmpty || text.contains('!') || text.contains('YOU ');
  }

  // Suggest child-centered rephrasing
  String childCenteredRephrase(String text) {
    // Simple demo: replace "I"/"you" with "our child" where possible
    return text
        .replaceAll(RegExp(r'\bI\b', caseSensitive: false), 'We')
        .replaceAll(RegExp(r'\byou\b', caseSensitive: false), 'our child');
  }

  // Suggest micro-coaching tips based on context
  List<String> microCoachingTips(String text, {String? context}) {
    final tips = <String>[];
    if (isEscalating(text)) tips.add('Pause and focus on shared goals.');
    if (detectTriggerWords(text).isNotEmpty) {
      tips.add('Try to avoid trigger words for a calmer conversation.');
    }
    if (context != null && context.toLowerCase().contains('parent')) {
      tips.add('Keep the message child-centered.');
    }
    if (!text.toLowerCase().contains('child')) {
      tips.add('Mention your child to keep the focus positive.');
    }
    return tips;
  }

  // Mediation: suggest neutral language if conflict detected
  String mediateMessage(String text) {
    if (!isEscalating(text)) return text;
    // Simple demo: soften direct statements
    return text
        .replaceAll('!', '.')
        .replaceAll(RegExp(r'\bmust\b', caseSensitive: false), 'could')
        .replaceAll(
          RegExp(r'\bneed\b', caseSensitive: false),
          'might consider',
        );
  }

  // Perspective switcher: rewrite from other parent's view
  String perspectiveSwitch(String text) {
    // Simple demo: swap "I" and "you"
    return text
        .replaceAll(RegExp(r'\bI\b', caseSensitive: false), '[Other Parent]')
        .replaceAll(RegExp(r'\byou\b', caseSensitive: false), 'I');
  }

  // Emotion/Empathy meter (0-100)
  int empathyScore(String text) {
    final analysis = _simulateToneAnalysis(text);
    int score = 50;
    if (analysis['dominant_tone'] == 'gentle') score += 25;
    if (analysis['emotion'] == 'positive') score += 15;
    if (detectTriggerWords(text).isNotEmpty) score -= 20;
    if (isEscalating(text)) score -= 10;
    return score.clamp(0, 100);
  }

  Future<void> initialize() async {
    await _loadSettings();
    await _loadAnalysisHistory();
    await _checkKeyboardStatus();

    // Sync any pending data from keyboard storage
    await _syncPendingKeyboardData();

    notifyListeners();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = prefs.getString('keyboard_settings');
      if (settingsJson != null) {
        final Map<String, dynamic> loaded = json.decode(settingsJson);
        _keyboardSettings = Map.from(_defaultSettings)..addAll(loaded);
      } else {
        _keyboardSettings = Map.from(_defaultSettings);
      }
    } catch (e) {
      print('Error loading keyboard settings: $e');
      _keyboardSettings = Map.from(_defaultSettings);
    }
  }

  /// Save keyboard settings to persistent storage
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsJson = json.encode(_keyboardSettings);
      await prefs.setString('keyboard_settings', settingsJson);
    } catch (e) {
      print('Error saving keyboard settings: $e');
    }
  }

  /// Load analysis history from persistent storage
  Future<void> _loadAnalysisHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString('analysis_history');
      if (historyJson != null) {
        final List<dynamic> loaded = json.decode(historyJson);
        _analysisHistory.clear();
        _analysisHistory.addAll(loaded.cast<Map<String, dynamic>>());
      }
    } catch (e) {
      print('Error loading analysis history: $e');
    }
  }

  /// Save analysis history to persistent storage
  Future<void> _saveAnalysisHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = json.encode(_analysisHistory);
      await prefs.setString('analysis_history', historyJson);
    } catch (e) {
      print('Error saving analysis history: $e');
    }
  }

  /// Sync pending data from keyboard storage to app
  Future<void> _syncPendingKeyboardData() async {
    try {
      final keyboardData = await _keyboardDataService
          .retrievePendingKeyboardData();

      if (keyboardData != null && keyboardData.hasData) {
        print(
          '📱 Syncing ${keyboardData.totalItems} items from keyboard storage...',
        );

        // Process the stored keyboard data
        await _keyboardDataService.processKeyboardData(keyboardData);

        // Clear the storage after successful processing
        await _keyboardDataService.clearPendingKeyboardData();

        print('✅ Keyboard data sync completed successfully');
      } else {
        print('📱 No pending keyboard data to sync');
      }
    } catch (e) {
      print('❌ Error syncing keyboard data: $e');
      // Don't throw - this shouldn't block app initialization
    }
  }

  Future<void> _checkKeyboardStatus() async {
    try {
      _isKeyboardInstalled =
          await UnsaidKeyboardExtension.isKeyboardAvailable();
      _isKeyboardEnabled = await UnsaidKeyboardExtension.isKeyboardEnabled();

      if (_isKeyboardEnabled) {
        final status = await UnsaidKeyboardExtension.getKeyboardStatus();
        _isKeyboardActive = status['active'] ?? false;
      }
    } catch (e) {
      print('Error checking keyboard status: $e');
      _isKeyboardInstalled = false;
      _isKeyboardEnabled = false;
      _isKeyboardActive = false;
    }
  }

  Future<bool> installKeyboard() async {
    try {
      // Request permissions first
      if (!await UnsaidKeyboardExtension.requestKeyboardPermissions()) {
        return false;
      }

      // Open keyboard settings for user to enable
      await UnsaidKeyboardExtension.openKeyboardSettings();

      // Check status after potential setup
      await _checkKeyboardStatus();
      notifyListeners();

      return _isKeyboardEnabled;
    } catch (e) {
      print('Error installing keyboard: $e');
      return false;
    }
  }

  // Wrapper method for compatibility with keyboard setup screen
  Future<void> requestKeyboardInstallation() async {
    await installKeyboard();
  }

  Future<bool> enableKeyboard(bool enable) async {
    try {
      final success = await UnsaidKeyboardExtension.enableKeyboard(enable);
      if (success) {
        _isKeyboardEnabled = enable;
        if (enable) {
          await UnsaidKeyboardExtension.updateKeyboardSettings(
            _keyboardSettings,
          );
        }
        notifyListeners();
      }
      return success;
    } catch (e) {
      print('Error enabling keyboard: $e');
      return false;
    }
  }

  Future<void> updateSetting(String key, dynamic value) async {
    _keyboardSettings[key] = value;
    await _saveSettings();

    if (_isKeyboardEnabled) {
      await UnsaidKeyboardExtension.updateKeyboardSettings(_keyboardSettings);
    }

    notifyListeners();
  }

  Future<void> updateSettings(Map<String, dynamic> newSettings) async {
    _keyboardSettings.addAll(newSettings);
    await _saveSettings();

    if (_isKeyboardEnabled) {
      await UnsaidKeyboardExtension.updateKeyboardSettings(_keyboardSettings);
    }

    notifyListeners();
  }

  Future<void> sendToneAnalysis(
    String text,
    Map<String, dynamic> analysis, {
    String? language,
    String? aiSuggestion,
    String? attachmentStyle,
    String? communicationStyle,
  }) async {
    if (_isKeyboardEnabled) {
      final payload = {
        'text': text,
        'analysis': analysis,
        'language': language ?? _keyboardSettings['language'],
        'aiSuggestion': aiSuggestion,
        'attachmentStyle':
            attachmentStyle ?? _keyboardSettings['attachmentStyle'],
        'communicationStyle':
            communicationStyle ?? _keyboardSettings['communicationStyle'],
      };
      await UnsaidKeyboardExtension.sendToneAnalysisPayload(payload);
    }
  }

  Future<String> processText(String input) async {
    if (!_isKeyboardEnabled) return input;

    try {
      return await UnsaidKeyboardExtension.processTextInput(input);
    } catch (e) {
      print('Error processing text: $e');
      return input;
    }
  }

  /// Analyze tone with relationship, attachment, and communication style context.
  Future<Map<String, dynamic>> analyzeTone(
    String text, {
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
  }) async {
    if (text.trim().isEmpty) {
      return {
        'dominant_tone': 'balanced',
        'confidence': 0.5,
        'analysis': {},
        'suggestions': [],
      };
    }

    // Use settings if not provided
    final relContext =
        relationshipContext ?? _keyboardSettings['relationshipContext'];
    final attachStyle = attachmentStyle ?? _keyboardSettings['attachmentStyle'];
    final commStyle =
        communicationStyle ?? _keyboardSettings['communicationStyle'];

    final analysis = _simulateToneAnalysis(
      text,
      relationshipContext: relContext,
      attachmentStyle: attachStyle,
      communicationStyle: commStyle,
    );

    // Send analysis to keyboard if enabled
    if (_isKeyboardEnabled && _keyboardSettings['toneDetection'] == true) {
      await sendToneAnalysis(text, analysis);
    }

    return analysis;
  }

  /// Simulate tone and emotion analysis with context for relationship, attachment, and communication style.
  Map<String, dynamic> _simulateToneAnalysis(
    String text, {
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
  }) {
    final lowerText = text.toLowerCase();

    // Simple keyword-based tone detection for demo
    int gentleScore = 0;
    int directScore = 0;
    int balancedScore = 0;

    // Gentle tone indicators
    const gentleWords = [
      'please',
      'thank',
      'kindly',
      'appreciate',
      'grateful',
      'wonderful',
      'amazing',
      'lovely',
      'gentle',
      'soft',
      'maybe',
      'perhaps',
      'could',
      'would',
      'might',
      'care',
      'support',
      'understand',
      'listen',
      'safe',
      'secure',
    ];

    // Direct tone indicators
    const directWords = [
      'need',
      'must',
      'should',
      'require',
      'demand',
      'urgent',
      'immediately',
      'now',
      'asap',
      'critical',
      'important',
      'fix',
      'wrong',
      'error',
      'problem',
      'issue',
      'boundary',
      'limit',
      'expect',
      'responsible',
    ];

    // Balanced tone indicators
    const balancedWords = [
      'suggest',
      'recommend',
      'consider',
      'think',
      'believe',
      'propose',
      'discuss',
      'review',
      'examine',
      'analyze',
      'collaborate',
      'together',
      'share',
      'open',
      'honest',
      'trust',
      'respect',
    ];

    for (final word in gentleWords) {
      if (lowerText.contains(word)) gentleScore += 2;
    }

    for (final word in directWords) {
      if (lowerText.contains(word)) directScore += 2;
    }

    for (final word in balancedWords) {
      if (lowerText.contains(word)) balancedScore += 2;
    }

    // Check punctuation
    if (text.contains('!')) directScore += 1;
    if (text.contains('?')) gentleScore += 1;
    if (text.contains('.')) balancedScore += 1;

    // Determine dominant tone
    String dominantTone = 'balanced';
    int maxScore = balancedScore;

    if (gentleScore > maxScore) {
      dominantTone = 'gentle';
      maxScore = gentleScore;
    }

    if (directScore > maxScore) {
      dominantTone = 'direct';
      maxScore = directScore;
    }

    // Simple sentiment/emotion detection
    String emotion = 'neutral';
    if (lowerText.contains('happy') ||
        lowerText.contains('joy') ||
        lowerText.contains('excited')) {
      emotion = 'positive';
    } else if (lowerText.contains('sad') ||
        lowerText.contains('angry') ||
        lowerText.contains('upset')) {
      emotion = 'negative';
    }

    // Calculate confidence (0.0 to 1.0)
    final totalScore = gentleScore + directScore + balancedScore;
    final confidence = totalScore > 0
        ? (maxScore.toDouble() / totalScore)
        : 0.5;

    return {
      'dominant_tone': dominantTone,
      'confidence': confidence.clamp(0.0, 1.0),
      'emotion': emotion,
      'analysis': {
        'gentle_score': gentleScore,
        'direct_score': directScore,
        'balanced_score': balancedScore,
      },
      'relationship_context': relationshipContext,
      'attachment_style': attachmentStyle,
      'communication_style': communicationStyle,
      'suggestions': _generateToneSuggestions(
        dominantTone,
        text,
        relationshipContext: relationshipContext,
        attachmentStyle: attachmentStyle,
        communicationStyle: communicationStyle,
      ),
    };
  }

  /// Generate suggestions based on tone, relationship, attachment, and communication style.
  List<String> _generateToneSuggestions(
    String tone,
    String originalText, {
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
  }) {
    final suggestions = <String>[];

    // Relationship/attachment/communication style–aware suggestions
    if (relationshipContext != null) {
      if (relationshipContext == 'Co-Parenting') {
        suggestions.add('Focus on child-centered language and shared goals.');
      } else if (relationshipContext == 'Dating') {
        suggestions.add('Balance honesty with warmth to build trust.');
      } else if (relationshipContext == 'Long-term' ||
          relationshipContext == 'Married') {
        suggestions.add('Emphasize respect and collaboration.');
      }
    }

    if (attachmentStyle != null) {
      if (attachmentStyle == 'Anxious Attachment') {
        suggestions.add('Offer reassurance and avoid ambiguous language.');
      } else if (attachmentStyle == 'Dismissive Avoidant') {
        suggestions.add('Respect boundaries and avoid overwhelming detail.');
      } else if (attachmentStyle == 'Disorganized/Fearful Avoidant') {
        suggestions.add('Use clear, consistent, and supportive language.');
      } else if (attachmentStyle == 'Secure Attachment') {
        suggestions.add('Maintain open, honest, and empathetic communication.');
      }
    }

    if (communicationStyle != null) {
      if (communicationStyle == 'Direct') {
        suggestions.add('Soften requests with gentle language if needed.');
      } else if (communicationStyle == 'Indirect') {
        suggestions.add('Clarify your needs to avoid misunderstandings.');
      } else if (communicationStyle == 'Secure Attachment') {
        suggestions.add(
          'Continue using balanced, assertive, and empathetic tone.',
        );
      } else if (communicationStyle == 'Anxious Attachment') {
        suggestions.add('Pause before sending to check for reassurance needs.');
      } else if (communicationStyle == 'Dismissive Avoidant') {
        suggestions.add('Share feelings as well as facts for connection.');
      } else if (communicationStyle == 'Disorganized/Fearful Avoidant') {
        suggestions.add('Use structure and validation to support clarity.');
      }
    }

    // Tone-specific suggestions
    switch (tone) {
      case 'direct':
        suggestions.addAll([
          'Consider softening with "please" or "kindly".',
          'Add a thank you to show appreciation.',
          'Use "could you" instead of "you must".',
        ]);
        break;
      case 'gentle':
        suggestions.addAll([
          'Be more specific about your request.',
          'Add urgency if time-sensitive.',
          'State your needs more clearly.',
        ]);
        break;
      case 'balanced':
        suggestions.addAll([
          'Your tone is well-balanced.',
          'Consider the context and recipient.',
          'Adjust if needed for your audience.',
        ]);
        break;
    }

    return suggestions;
  }

  /// Get a GPT-powered suggestion or rephrasing for the given text and context.
  Future<String> getGptSuggestion(
    String text, {
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
  }) async {
    try {
      final apiKey = await SecureConfig.instance.getOpenAIKey();
      if (!SecureConfig.instance.isValidApiKey(apiKey)) {
        return 'AI suggestion unavailable (API key not configured)';
      }

      // TODO: Implement actual API call here (see OpenAI docs or your backend)
      // Example prompt would be:
      // 'Rewrite this message to be more empathetic and clear, considering the following context: '
      // 'Relationship: "${relationshipContext ?? _keyboardSettings['relationshipContext']}", '
      // 'Attachment Style: "${attachmentStyle ?? _keyboardSettings['attachmentStyle']}", '
      // 'Communication Style: "${communicationStyle ?? _keyboardSettings['communicationStyle']}". '
      // 'Message: "$text".';

      // For now, return a placeholder
      await Future.delayed(const Duration(milliseconds: 500));
      return '[AI Suggestion Placeholder]: $text';
    } catch (e) {
      return 'AI suggestion unavailable (error: $e)';
    }
  }

  void openKeyboardSettings() async {
    try {
      // For iOS, try to open directly to keyboard settings
      await UnsaidKeyboardExtension.openKeyboardSettings();
    } catch (e) {
      // Fallback: open general settings
      print('Could not open keyboard settings directly: $e');
      // You could also use url_launcher to open app-settings:
      // but for now, the platform channel should handle this
    }
  }

  Future<void> refreshStatus() async {
    await _checkKeyboardStatus();
    notifyListeners();
  }

  /// Adaptive learning: update user style preferences based on their writing.
  Future<void> adaptUserStyleFromMessage(String text) async {
    // Simple demo: if user uses lots of gentle words, shift attachment style to 'Secure' or 'Anxious'.
    final analysis = _simulateToneAnalysis(text);
    String? newAttachment;
    String? newCommStyle;

    // Example: if gentle score is much higher, suggest 'Secure' or 'Anxious' attachment
    final gentle = analysis['analysis']['gentle_score'] ?? 0;
    final direct = analysis['analysis']['direct_score'] ?? 0;
    final balanced = analysis['analysis']['balanced_score'] ?? 0;

    if (gentle > direct && gentle > balanced && gentle > 4) {
      newAttachment = 'Secure';
      newCommStyle = 'Secure Attachment';
    } else if (direct > gentle && direct > balanced && direct > 4) {
      newAttachment = 'Avoidant';
      newCommStyle = 'Direct';
    }
    // You can expand this logic for more nuance

    // Update settings if a new style is detected
    if (newAttachment != null &&
        newAttachment != _keyboardSettings['attachmentStyle']) {
      _keyboardSettings['attachmentStyle'] = newAttachment;
      await _saveSettings();
    }
    if (newCommStyle != null &&
        newCommStyle != _keyboardSettings['communicationStyle']) {
      _keyboardSettings['communicationStyle'] = newCommStyle;
      await _saveSettings();
    }
    notifyListeners();
  }

  // Preset configurations
  void applyPreset(String presetName) {
    switch (presetName) {
      case 'professional':
        updateSettings({
          'toneDetection': true,
          'tone': 'formal',
          'smartSuggestions': true,
          'autoCorrect': true,
          'sensitivity': 0.7,
        });
        break;
      case 'casual':
        updateSettings({
          'toneDetection': true,
          'tone': 'friendly',
          'showEmojis': true,
          'swipeGestures': true,
          'sensitivity': 0.3,
        });
        break;
      case 'minimal':
        updateSettings({
          'toneDetection': false,
          'smartSuggestions': false,
          'showNumbers': false,
          'showEmojis': false,
          'hapticFeedback': false,
        });
        break;
    }
  }

  /// Returns the dominant tone as a string for the given text and context.
  Future<String?> detectTone(String text, {String? context}) async {
    final analysis = await analyzeTone(text, relationshipContext: context);
    final tone = analysis['dominant_tone'];
    if (tone is String && tone.isNotEmpty) {
      return tone[0].toUpperCase() + tone.substring(1);
    }
    return null;
  }

  // Store recent analysis results for learning
  final List<Map<String, dynamic>> _analysisHistory = [];

  // Use keyboard extension for all API calls through Swift bridge
  // No direct AI service instances - everything goes through the bridge

  // Get analysis history
  List<Map<String, dynamic>> get analysisHistory =>
      List.unmodifiable(_analysisHistory);

  /// Retrieve processed analysis from keyboard storage (no redundant API calls)
  Future<Map<String, dynamic>> performComprehensiveAnalysis(
    String message, {
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
    int? childAge,
  }) async {
    if (message.trim().isEmpty) {
      return {'error': 'Message cannot be empty'};
    }

    try {
      // First try to get processed data from keyboard storage
      final keyboardData = await _keyboardDataService
          .retrievePendingKeyboardData();

      if (keyboardData != null && keyboardData.hasData) {
        print(
          '📱 Retrieved analysis from keyboard storage: ${keyboardData.summary}',
        );

        // Process and format the stored data
        final comprehensiveAnalysis = _formatKeyboardStorageData(
          keyboardData,
          message,
          relationshipContext,
          attachmentStyle,
          communicationStyle,
          childAge,
        );

        // Clear the processed data from storage
        await _keyboardDataService.clearPendingKeyboardData();

        return comprehensiveAnalysis;
      }

      // Fallback: If no keyboard data available, return basic structure
      // This happens when analysis is requested but keyboard hasn't stored data yet
      print('📱 No keyboard storage data available, returning basic structure');

      final basicAnalysis = _createBasicAnalysisStructure(
        message,
        relationshipContext,
        attachmentStyle,
        communicationStyle,
        childAge,
      );

      return basicAnalysis;
    } catch (e) {
      print('Error retrieving keyboard data: $e');
      // Fallback to basic structure
      return _createBasicAnalysisStructure(
        message,
        relationshipContext,
        attachmentStyle,
        communicationStyle,
        childAge,
      );
    }
  }

  /// Send comprehensive analysis to iOS keyboard
  Future<void> _sendAnalysisToKeyboard(Map<String, dynamic> analysis) async {
    try {
      // Send co-parenting analysis
      await UnsaidKeyboardExtension.sendCoParentingAnalysis(
        analysis['message'],
        analysis['coparenting_analysis'],
      );

      // Send EQ coaching
      await UnsaidKeyboardExtension.sendEQCoaching(
        analysis['message'],
        analysis['emotional_analysis'],
      );

      // Send child development analysis if applicable
      if (analysis['context']['child_age'] != null) {
        await UnsaidKeyboardExtension.sendChildDevelopmentAnalysis(
          analysis['message'],
          {
            'child_age': analysis['context']['child_age'],
            'developmental_considerations':
                analysis['coparenting_analysis']['child_impact_analysis'],
          },
        );
      }

      // Send tone analysis
      await UnsaidKeyboardExtension.sendToneAnalysisPayload({
        'text': analysis['message'],
        'analysis': analysis['tone_analysis'],
        'suggestions': analysis['integrated_suggestions'],
      });
    } catch (e) {
      print('Error sending analysis to keyboard: $e');
    }
  }

  // Helper methods for creating profiles and contexts

  /// Map relationship context to API context format
  String _mapContextToApiContext(String relationshipContext) {
    switch (relationshipContext.toLowerCase()) {
      case 'dating':
        return 'general';
      case 'marriage':
      case 'married':
        return 'repair';
      case 'co-parenting':
      case 'coparenting':
        return 'boundary';
      case 'conflict':
        return 'conflict';
      case 'jealousy':
        return 'jealousy';
      default:
        return 'general';
    }
  }

  /// Format tone analysis response for consistency
  Map<String, dynamic> _formatToneAnalysis(Map<String, dynamic>? analysis) {
    if (analysis == null) {
      return {
        'dominant_tone': 'neutral',
        'confidence': 0.5,
        'overall_tone': 'neutral',
        'suggestions': ['Message analysis unavailable'],
      };
    }

    return {
      'dominant_tone': analysis['tone'] ?? 'neutral',
      'confidence': analysis['confidence'] ?? 0.5,
      'overall_tone': analysis['tone'] ?? 'neutral',
      'suggestions': (analysis['suggestions'] as List?)?.cast<String>() ?? [],
    };
  }

  // Mock methods for other analyses until bridge methods are available
  Map<String, dynamic> _mockCoParentingAnalysis() {
    return {
      'child_impact_score': 0.7,
      'collaboration_potential': 0.8,
      'suggestions': [
        'Keep the focus on the child',
        'Use collaborative language',
      ],
      'tone_recommendations': ['neutral', 'collaborative'],
    };
  }

  Map<String, dynamic> _mockEmotionalAnalysis() {
    return {
      'primary_emotion': 'neutral',
      'intensity': 0.5,
      'regulation_suggestions': ['Take a breath', 'Consider perspective'],
    };
  }

  Map<String, dynamic> _mockPredictiveAnalysis() {
    return {
      'predicted_outcome': 'neutral',
      'confidence': 0.7,
      'risk_factors': ['unclear communication'],
      'recommendations': ['Be more specific', 'Add context'],
    };
  }

  List<String> _generateIntegratedSuggestions(
    Map<String, dynamic>? toneAnalysis,
  ) {
    final suggestions = <String>[];

    if (toneAnalysis != null) {
      final toneSuggestions =
          (toneAnalysis['suggestions'] as List?)?.cast<String>() ?? [];
      suggestions.addAll(toneSuggestions);
    }

    // Add default suggestions
    suggestions.addAll([
      'Consider rephrasing for clarity',
      'Add more context to avoid misunderstandings',
      'Focus on the child\'s needs',
      'Use neutral, collaborative language',
    ]);

    return suggestions.take(4).toList(); // Limit to 4 suggestions
  }

  Future<Map<String, dynamic>> getComprehensiveRealData() async {
    try {
      final analytics = await _channel.invokeMethod('getKeyboardAnalytics');
      final interactions = await _channel.invokeMethod(
        'getKeyboardInteractions',
      );
      return {
        'real_data': true,
        'analytics': analytics,
        'interactions': interactions,
      };
    } catch (e) {
      print('Error fetching keyboard analytics: $e');
      return {'real_data': false};
    }
  }

  /// Sync children names to the keyboard extension
  Future<void> syncChildrenNames(List<String> names) async {
    try {
      // Save to local storage for keyboard extension access
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('children_names', names);

      // Send to iOS keyboard extension via platform channel
      await _channel.invokeMethod('syncChildrenNames', {
        'names': names,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      print('✅ Children names synced to keyboard extension: $names');
    } catch (e) {
      print('❌ Error syncing children names to keyboard: $e');
      // Don't rethrow - this shouldn't block the UI flow
    }
  }

  /// Format data retrieved from keyboard storage
  Map<String, dynamic> _formatKeyboardStorageData(
    KeyboardAnalyticsData keyboardData,
    String message,
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
    int? childAge,
  ) {
    final context = {
      'relationship': relationshipContext ?? 'Dating',
      'attachment_style': attachmentStyle ?? 'secure',
      'communication_style': communicationStyle ?? 'direct',
      'child_age': childAge ?? 8,
    };

    // Extract tone data from keyboard storage
    Map<String, dynamic> toneAnalysis = {};
    if (keyboardData.toneData.isNotEmpty) {
      final latestTone = keyboardData.toneData.last;
      toneAnalysis = {
        'dominant_tone': latestTone['tone'] ?? 'neutral',
        'confidence': latestTone['confidence'] ?? 0.5,
        'overall_tone': latestTone['primaryTone'] ?? 'neutral',
        'suggestions': latestTone['suggestions'] ?? [],
      };
    } else {
      toneAnalysis = _formatToneAnalysis(null);
    }

    // Extract analytics data
    Map<String, dynamic> coParentingAnalysis = _mockCoParentingAnalysis();
    Map<String, dynamic> emotionalAnalysis = _mockEmotionalAnalysis();
    Map<String, dynamic> predictiveAnalysis = _mockPredictiveAnalysis();

    if (keyboardData.analytics.isNotEmpty) {
      final latestAnalytics = keyboardData.analytics.last;

      // Extract co-parenting specific data
      if (latestAnalytics['coparenting'] != null) {
        coParentingAnalysis = {
          'child_impact_score':
              latestAnalytics['coparenting']['childFocus'] ?? 0.7,
          'collaboration_potential':
              latestAnalytics['coparenting']['collaboration'] ?? 0.8,
          'suggestions':
              latestAnalytics['coparenting']['suggestions'] ??
              ['Keep focus on child'],
          'tone_recommendations': ['collaborative', 'respectful'],
        };
      }

      // Extract emotional analysis
      if (latestAnalytics['emotional'] != null) {
        emotionalAnalysis = {
          'primary_emotion':
              latestAnalytics['emotional']['primaryEmotion'] ?? 'neutral',
          'intensity': latestAnalytics['emotional']['intensity'] ?? 0.5,
          'regulation_suggestions':
              latestAnalytics['emotional']['suggestions'] ??
              ['Consider your emotional state'],
        };
      }

      // Extract predictive analysis
      if (latestAnalytics['predictive'] != null) {
        predictiveAnalysis = {
          'predicted_outcome':
              latestAnalytics['predictive']['outcome'] ?? 'neutral',
          'confidence': latestAnalytics['predictive']['confidence'] ?? 0.7,
          'risk_factors':
              latestAnalytics['predictive']['risks'] ??
              ['unclear communication'],
          'recommendations':
              latestAnalytics['predictive']['recommendations'] ??
              ['Be specific'],
        };
      }
    }

    // Extract suggestions
    List<String> suggestions = [];
    if (keyboardData.suggestions.isNotEmpty) {
      for (final suggestionData in keyboardData.suggestions) {
        if (suggestionData['suggestions'] is List) {
          suggestions.addAll(
            (suggestionData['suggestions'] as List).cast<String>(),
          );
        }
      }
    }

    final comprehensiveAnalysis = {
      'timestamp': DateTime.now().toIso8601String(),
      'message': message,
      'context': context,
      'tone_analysis': toneAnalysis,
      'coparenting_analysis': coParentingAnalysis,
      'emotional_analysis': emotionalAnalysis,
      'predictive_analysis': predictiveAnalysis,
      'suggestions': suggestions,
      'integrated_suggestions': _generateIntegratedSuggestions(toneAnalysis),
      'data_source': 'keyboard_storage',
      'sync_timestamp': keyboardData.syncTimestamp.toIso8601String(),
      'storage_metadata': keyboardData.metadata,
    };

    // Store in history
    _analysisHistory.add(comprehensiveAnalysis);
    if (_analysisHistory.length > 20) {
      _analysisHistory.removeAt(0);
    }

    // Save analysis history to persistent storage
    _saveAnalysisHistory();

    return comprehensiveAnalysis;
  }

  /// Create basic analysis structure when no keyboard data is available
  Map<String, dynamic> _createBasicAnalysisStructure(
    String message,
    String? relationshipContext,
    String? attachmentStyle,
    String? communicationStyle,
    int? childAge,
  ) {
    return {
      'timestamp': DateTime.now().toIso8601String(),
      'message': message,
      'context': {
        'relationship': relationshipContext ?? 'Dating',
        'attachment_style': attachmentStyle ?? 'secure',
        'communication_style': communicationStyle ?? 'direct',
        'child_age': childAge ?? 8,
      },
      'tone_analysis': _formatToneAnalysis(null),
      'coparenting_analysis': _mockCoParentingAnalysis(),
      'emotional_analysis': _mockEmotionalAnalysis(),
      'predictive_analysis': _mockPredictiveAnalysis(),
      'suggestions': <String>[],
      'integrated_suggestions': <String>[],
      'data_source': 'basic_fallback',
      'note': 'No keyboard storage data available - using basic structure',
    };
  }

  Future<void> clearAnalysisHistory() async {
    // Implement clearing logic here
  }
}
