import 'package:flutter/foundation.dart';
// import 'package:cloud_firestore/cloud_firestore.dart'; // Removed for simplified Firebase setup
import 'secure_storage_service.dart';

/// Service for managing conversation data and history
class ConversationDataService {
  // Removed Firestore collection constants - using local storage only

  // final FirebaseFirestore _firestore = FirebaseFirestore.instance; // Removed for simplified setup
  final SecureStorageService _secureStorage = SecureStorageService();

  /// Get conversation history for analysis
  Future<List<Map<String, dynamic>>> getConversationHistory({
    String? userId,
    String? relationshipId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    try {
      // Use local storage instead of Firestore
      return await _getLocalConversationHistory(
        userId: userId,
        relationshipId: relationshipId,
        startDate: startDate,
        endDate: endDate,
        limit: limit,
      );
    } catch (e) {
      debugPrint('Error getting conversation history: $e');
      // Return mock data for development
      return _getMockConversationHistory();
    }
  }

  /// Get conversation history from local storage
  Future<List<Map<String, dynamic>>> _getLocalConversationHistory({
    String? userId,
    String? relationshipId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    try {
      final localConversations = await _getLocalConversations();
      final filteredConversations = <Map<String, dynamic>>[];

      for (final conversation in localConversations) {
        // Apply filters
        if (userId != null && conversation['user_id'] != userId) {
          continue;
        }
        if (relationshipId != null &&
            conversation['relationship_id'] != relationshipId) {
          continue;
        }

        if (startDate != null) {
          final convDate = DateTime.tryParse(conversation['timestamp'] ?? '');
          if (convDate == null || convDate.isBefore(startDate)) continue;
        }

        if (endDate != null) {
          final convDate = DateTime.tryParse(conversation['timestamp'] ?? '');
          if (convDate == null || convDate.isAfter(endDate)) continue;
        }

        // Get messages for this conversation
        final messages =
            await _getLocalMessagesForConversation(conversation['id']);
        conversation['messages'] = messages;

        filteredConversations.add(conversation);

        if (filteredConversations.length >= limit) break;
      }

      // Sort by timestamp descending
      filteredConversations.sort((a, b) {
        final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.now();
        final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.now();
        return bTime.compareTo(aTime);
      });

      return filteredConversations;
    } catch (e) {
      debugPrint('Error getting local conversation history: $e');
      return [];
    }
  }

  /// Get messages for a specific conversation from local storage
  Future<List<Map<String, dynamic>>> _getLocalMessagesForConversation(
      String conversationId) async {
    try {
      return await _getLocalMessages(conversationId);
    } catch (e) {
      debugPrint('Error getting local messages for conversation: $e');
      return [];
    }
  }

  /// Store message data
  Future<void> storeMessage(
      String conversationId, Map<String, dynamic> messageData) async {
    try {
      // Store locally instead of Firestore
      await _storeMessageLocally(conversationId, messageData);
    } catch (e) {
      debugPrint('Error storing message: $e');
    }
  }

  /// Store conversation data
  Future<void> storeConversation(Map<String, dynamic> conversationData) async {
    try {
      // Store locally instead of Firestore
      await _storeConversationLocally(conversationData);
    } catch (e) {
      debugPrint('Error storing conversation: $e');
    }
  }

  /// Store conversation locally
  Future<void> _storeConversationLocally(
      Map<String, dynamic> conversationData) async {
    try {
      final localConversations = await _getLocalConversations();
      localConversations.add(conversationData);

      await _secureStorage.storeSecureJson('local_conversations', {
        'conversations': localConversations,
        'last_updated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error storing conversation locally: $e');
    }
  }

  /// Store message locally as fallback
  Future<void> _storeMessageLocally(
      String conversationId, Map<String, dynamic> messageData) async {
    try {
      final localMessages = await _getLocalMessages(conversationId);
      localMessages.add(messageData);

      await _secureStorage.storeSecureJson('local_messages_$conversationId', {
        'messages': localMessages,
        'last_updated': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error storing message locally: $e');
    }
  }

  /// Get local conversations
  Future<List<Map<String, dynamic>>> _getLocalConversations() async {
    try {
      final data = await _secureStorage.getSecureJson('local_conversations');
      if (data != null && data['conversations'] != null) {
        return List<Map<String, dynamic>>.from(data['conversations']);
      }
      return [];
    } catch (e) {
      debugPrint('Error getting local conversations: $e');
      return [];
    }
  }

  /// Get local messages for a conversation
  Future<List<Map<String, dynamic>>> _getLocalMessages(
      String conversationId) async {
    try {
      final data =
          await _secureStorage.getSecureJson('local_messages_$conversationId');
      if (data != null && data['messages'] != null) {
        return List<Map<String, dynamic>>.from(data['messages']);
      }
      return [];
    } catch (e) {
      debugPrint('Error getting local messages: $e');
      return [];
    }
  }

  /// Get conversation statistics
  Future<Map<String, dynamic>> getConversationStats({
    String? userId,
    String? relationshipId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final conversations = await getConversationHistory(
        userId: userId,
        relationshipId: relationshipId,
        startDate: startDate,
        endDate: endDate,
      );

      int totalMessages = 0;
      int totalWords = 0;
      final emotionCounts = <String, int>{};

      for (final conversation in conversations) {
        final messages = conversation['messages'] as List<dynamic>? ?? [];
        totalMessages += messages.length;

        for (final message in messages) {
          final text = message['text'] as String? ?? '';
          totalWords += text.split(' ').length;

          // Count emotions from sentiment analysis
          final sentiment = message['sentiment'] as Map<String, dynamic>? ?? {};
          for (final emotion in sentiment.keys) {
            emotionCounts[emotion] = (emotionCounts[emotion] ?? 0) + 1;
          }
        }
      }

      return {
        'total_conversations': conversations.length,
        'total_messages': totalMessages,
        'total_words': totalWords,
        'average_messages_per_conversation':
            totalMessages / (conversations.length + 1),
        'emotion_counts': emotionCounts,
        'analysis_period': {
          'start_date': startDate?.toIso8601String(),
          'end_date': endDate?.toIso8601String(),
        },
      };
    } catch (e) {
      debugPrint('Error getting conversation stats: $e');
      return _getDefaultStats();
    }
  }

  /// Get default stats for error cases
  Map<String, dynamic> _getDefaultStats() {
    return {
      'total_conversations': 0,
      'total_messages': 0,
      'total_words': 0,
      'average_messages_per_conversation': 0.0,
      'emotion_counts': {},
      'analysis_period': {
        'start_date': null,
        'end_date': null,
      },
    };
  }

  /// Get mock conversation history for development
  List<Map<String, dynamic>> _getMockConversationHistory() {
    return [
      {
        'id': 'conv_1',
        'user_id': 'user_123',
        'relationship_id': 'rel_456',
        'timestamp':
            DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
        'messages': [
          {
            'id': 'msg_1',
            'text':
                'I appreciate how you always listen to me when I need to talk.',
            'sender': 'user',
            'timestamp': DateTime.now()
                .subtract(const Duration(days: 1))
                .toIso8601String(),
            'sentiment': {
              'joy': 0.8,
              'sadness': 0.1,
              'anger': 0.0,
              'fear': 0.0,
              'surprise': 0.1,
              'disgust': 0.0,
            },
          },
          {
            'id': 'msg_2',
            'text': 'That means so much to me. I love being here for you.',
            'sender': 'partner',
            'timestamp': DateTime.now()
                .subtract(const Duration(days: 1))
                .toIso8601String(),
            'sentiment': {
              'joy': 0.9,
              'sadness': 0.0,
              'anger': 0.0,
              'fear': 0.0,
              'surprise': 0.0,
              'disgust': 0.1,
            },
          },
        ],
      },
      {
        'id': 'conv_2',
        'user_id': 'user_123',
        'relationship_id': 'rel_456',
        'timestamp':
            DateTime.now().subtract(const Duration(days: 3)).toIso8601String(),
        'messages': [
          {
            'id': 'msg_3',
            'text':
                'I feel anxious when you don\'t respond quickly to my messages.',
            'sender': 'user',
            'timestamp': DateTime.now()
                .subtract(const Duration(days: 3))
                .toIso8601String(),
            'sentiment': {
              'joy': 0.0,
              'sadness': 0.3,
              'anger': 0.2,
              'fear': 0.5,
              'surprise': 0.0,
              'disgust': 0.0,
            },
          },
          {
            'id': 'msg_4',
            'text':
                'I understand. I\'ll try to be more mindful of responding promptly.',
            'sender': 'partner',
            'timestamp': DateTime.now()
                .subtract(const Duration(days: 3))
                .toIso8601String(),
            'sentiment': {
              'joy': 0.2,
              'sadness': 0.1,
              'anger': 0.0,
              'fear': 0.0,
              'surprise': 0.0,
              'disgust': 0.0,
            },
          },
        ],
      },
    ];
  }

  /// Get conversations data
  Future<List<Map<String, dynamic>>> getConversations() async {
    try {
      // Mock conversation data for now
      return [
        {
          'id': '1',
          'timestamp': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'content': 'How was your day?',
          'empathy_score': 0.8,
          'clarity_score': 0.7,
          'tone': 'supportive',
        },
        {
          'id': '2',
          'timestamp': DateTime.now()
              .subtract(const Duration(days: 2))
              .toIso8601String(),
          'content': 'Can we talk about the schedule?',
          'empathy_score': 0.6,
          'clarity_score': 0.9,
          'tone': 'neutral',
        },
      ];
    } catch (e) {
      return [];
    }
  }
}
