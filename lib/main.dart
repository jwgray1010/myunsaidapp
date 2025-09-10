// Removed unnecessary dart:ui import; adding developer for timeline instrumentation
import 'dart:developer' show Timeline;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'services/auth_service.dart' as auth_service;
import 'services/usage_tracking_service.dart';
import 'services/data_manager_service.dart';
// import 'services/usage_tracking_service.dart'; // Removed for simplified Firebase setup
import 'services/personality_test_service.dart';
import 'services/new_user_experience_service.dart';
import 'services/partner_data_service.dart';
import 'services/trial_service.dart';
import 'services/subscription_service.dart';
import 'services/onboarding_service.dart';
import 'widgets/keyboard_data_sync_widget.dart';
import 'firebase_options.dart';

import 'ui/unsaid_theme.dart';
import 'screens/splash_screen_professional.dart';
import 'screens/onboarding_account_screen_professional.dart';
import 'screens/personality_test_disclaimer_screen_professional.dart';
import 'screens/personality_test_screen_professional_fixed_v2.dart';
import 'screens/personality_test_screen.dart';
import 'screens/personality_results_screen.dart';
import 'screens/premium_screen_professional.dart';
import 'screens/keyboard_intro_screen_professional.dart';
import 'screens/emotional_state_screen.dart';
import 'screens/tone_indicator_tutorial_screen.dart';
// Removed main_shell, relationship insights, and legacy home screen in favor of consolidated insights dashboard
import 'data/randomized_personality_questions.dart';
import 'data/attachment_assessment.dart';
import 'data/assessment_integration.dart';
import 'screens/insights_dashboard_enhanced.dart';

// Global navigator key for post-frame service initialization
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  print("🎯 [FLUTTER DEBUG] main() - START");
  WidgetsFlutterBinding.ensureInitialized();
  print(
    "🎯 [FLUTTER DEBUG] WidgetsFlutterBinding.ensureInitialized() completed",
  );

  // Show the app IMMEDIATELY - don't wait for anything
  print("🎯 [FLUTTER DEBUG] Showing UnsaidApp IMMEDIATELY...");
  runApp(const UnsaidApp());

  // Initialize Firebase in background (non-blocking) with timeline markers
  // ignore: unawaited_futures
  Future(() async {
    Timeline.startSync('firebase_init');
    try {
      print("🚀 [FLUTTER DEBUG] Initializing Firebase (background)...");
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      } else {
        print("ℹ️ Firebase already initialized – skipping duplicate init");
      }
      print(
        "🚀 [FLUTTER DEBUG] Firebase initialized successfully (background)",
      );

      // Verify Firebase app was created and log configuration
      final app = Firebase.app();
      final opts = app.options;
      print("✅ Firebase app: ${app.name}");
      print(
        "✅ Firebase opts: projectId=${opts.projectId}, appId=${opts.appId}, apiKey=${opts.apiKey.substring(0, 6)}...",
      );

      Timeline.finishSync();
      Timeline.startSync('auth_init');
      // Initialize AuthService after Firebase is ready
      await auth_service.AuthService.instance.initialize();
      print(
        "🚀 [FLUTTER DEBUG] AuthService initialized successfully (background)",
      );
    } catch (e) {
      print("🚀 [FLUTTER DEBUG] Firebase/Auth initialization FAILED: $e");
      print("🚀 [FLUTTER DEBUG] Error details: ${e.toString()}");
    } finally {
      // Ensure timeline sections close even on error
      try {
        Timeline.finishSync();
      } catch (_) {}
    }
  });

  // Optional: prove first frame time in logs
  WidgetsBinding.instance.addPostFrameCallback((_) {
    debugPrint('🟢 First Flutter frame drawn - NO MORE BLACK SCREEN!');

    // Initialize TrialService after first frame (non-blocking)
    try {
      final context = navigatorKey.currentContext;
      if (context != null) {
        final trialService = Provider.of<TrialService>(context, listen: false);
        // ignore: unawaited_futures
        trialService
            .initialize()
            .then((_) {
              debugPrint(
                '🚀 TrialService initialized successfully (post-frame)',
              );
            })
            .catchError((e) {
              debugPrint('❌ TrialService initialization failed: $e');
            });

        // Initialize UsageTrackingService after first frame (non-blocking)
        // ignore: unawaited_futures
        UsageTrackingService.instance
            .initialize()
            .then((_) {
              debugPrint(
                '🚀 UsageTrackingService initialized successfully (post-frame)',
              );
            })
            .catchError((e) {
              debugPrint('❌ UsageTrackingService initialization failed: $e');
            });

        // Initialize DataManagerService after first frame (non-blocking)
        // ignore: unawaited_futures
        DataManagerService()
            .initializePostFrame()
            .then((_) {
              debugPrint(
                '🚀 DataManagerService initialized successfully (post-frame)',
              );
            })
            .catchError((e) {
              debugPrint('❌ DataManagerService initialization failed: $e');
            });
      }
    } catch (e) {
      debugPrint('❌ Could not initialize services: $e');
    }
  });

  print("🎯 [FLUTTER DEBUG] main() - END");
}

class UnsaidApp extends StatelessWidget {
  const UnsaidApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Add diagnostic logging for first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('🟢 First frame drawn - UI is now visible!');
    });

    // Boot visual probe removed (issue resolved)

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth_service.AuthService.instance),
        // Removed UsageTrackingService for simplified Firebase setup
        ChangeNotifierProvider<NewUserExperienceService>(
          create: (_) => NewUserExperienceService(),
        ),
        ChangeNotifierProvider<PartnerDataService>(
          create: (_) => PartnerDataService(),
        ),
        ChangeNotifierProvider<TrialService>(create: (_) => TrialService()),
        ChangeNotifierProvider<SubscriptionService>(
          create: (_) => SubscriptionService(),
        ),
      ],
      child: Consumer<auth_service.AuthService>(
        builder: (context, authService, child) {
          final app = KeyboardDataSyncWidget(
            onDataReceived: (data) {
              debugPrint(
                '📱 Main App: Received keyboard data with ${data.totalItems} items',
              );
              // Here you can integrate with your existing analytics or storage
            },
            onError: (error) {
              debugPrint('❌ Main App: Keyboard data sync error: $error');
            },
            child: Semantics(
              // This ensures the app is accessible at the root level.
              label: 'Unsaid communication and relationship app',
              child: MaterialApp(
                navigatorKey: navigatorKey,
                title: 'Unsaid',
                debugShowCheckedModeBanner: false,
                theme: buildUnsaidTheme(),
                // Ensure immediate background matches launch screen
                color: const Color(0xFF2563EB), // Launch screen blue
                builder: (context, child) =>
                    child!, // simplify to rule out builder side-effects
                home: const SplashScreenProfessional(),
                // initialRoute: '/splash', // Commented out to use home instead
                navigatorObservers: [MyNavigatorObserver()],
                routes: {'/insights': (_) => const InsightsDashboardEnhanced()},
                onGenerateRoute: (settings) {
                  switch (settings.name) {
                    case '/splash':
                      return MaterialPageRoute(
                        builder: (context) => const SplashScreenProfessional(),
                      );
                    case '/onboarding':
                      return MaterialPageRoute(
                        builder: (context) {
                          final authService =
                              Provider.of<auth_service.AuthService>(
                                context,
                                listen: false,
                              );
                          return OnboardingAccountScreenProfessional(
                            onSignInWithApple: () async {
                              try {
                                final result = await authService
                                    .signInWithApple();
                                if (result != null && context.mounted) {
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/personality_test_disclaimer',
                                  );
                                } else if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Apple sign-in was cancelled or failed.',
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Apple sign-in error: $e'),
                                    ),
                                  );
                                }
                              }
                            },
                            onSignInWithGoogle: () async {
                              final cred = await FirebaseAuth.instance
                                  .signInWithProvider(GoogleAuthProvider());
                              if (cred.user == null) {
                                throw Exception('google-sign-in-null');
                              }
                              if (context.mounted) {
                                Navigator.pushReplacementNamed(
                                  context,
                                  '/personality_test_disclaimer',
                                );
                              }
                            },
                          );
                        },
                      );
                    case '/personality_test_disclaimer':
                      return MaterialPageRoute(
                        builder: (context) => FutureBuilder<bool>(
                          future: PersonalityTestService.isTestCompleted(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Scaffold(
                                body: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            if (snapshot.data == true) {
                              // Test already completed, check if full onboarding is complete
                              WidgetsBinding.instance.addPostFrameCallback((
                                _,
                              ) async {
                                if (!context.mounted) return;

                                final onboardingService =
                                    OnboardingService.instance;
                                final isOnboardingComplete =
                                    await onboardingService
                                        .isOnboardingComplete();

                                if (!context.mounted) return;

                                if (isOnboardingComplete) {
                                  // Returning user - go to main app
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/main',
                                  );
                                } else {
                                  // New user who completed test but not full onboarding - go to premium
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/premium',
                                  );
                                }
                              });
                              return const Scaffold(
                                body: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            // Test not completed, show disclaimer
                            return PersonalityTestDisclaimerScreenProfessional(
                              onAgree: () => Navigator.pushReplacementNamed(
                                context,
                                '/personality_test_legacy',
                              ),
                              onAgreeModern: () =>
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/personality_test',
                                  ),
                            );
                          },
                        ),
                      );
                    case '/personality_test_legacy':
                      return MaterialPageRoute(
                        builder: (context) => FutureBuilder<bool>(
                          future: PersonalityTestService.isTestCompleted(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Scaffold(
                                body: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            if (snapshot.data == true) {
                              // Test already completed, check if full onboarding is complete
                              WidgetsBinding.instance.addPostFrameCallback((
                                _,
                              ) async {
                                if (!context.mounted) return;

                                final onboardingService =
                                    OnboardingService.instance;
                                final isOnboardingComplete =
                                    await onboardingService
                                        .isOnboardingComplete();

                                if (!context.mounted) return;

                                if (isOnboardingComplete) {
                                  // Returning user - go to main app
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/main',
                                  );
                                } else {
                                  // New user who completed test but not full onboarding - go to premium
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/premium',
                                  );
                                }
                              });
                              return const Scaffold(
                                body: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            // Test not completed, show test
                            final randomizedQuestions =
                                RandomizedPersonalityTest.getRandomizedQuestions();
                            return PersonalityTestScreenProfessional(
                              currentIndex: 0,
                              answers: List<String?>.filled(
                                randomizedQuestions.length,
                                null,
                              ),
                              questions: randomizedQuestions
                                  .map(
                                    (q) => {
                                      'question': q.question,
                                      'options': q.options,
                                    },
                                  )
                                  .toList(),
                              onComplete: (answers) async {
                                // Mark test as completed
                                await PersonalityTestService.markTestCompleted(
                                  answers,
                                );
                                // Navigate to tone tutorial first (new flow)
                                Navigator.pushReplacementNamed(
                                  context,
                                  '/tone_tutorial',
                                );
                              },
                            );
                          },
                        ),
                      );
                    case '/personality_results_legacy':
                      // Redirect legacy route to modern personality results
                      // with default values for backward compatibility
                      return MaterialPageRoute(
                        builder: (context) => PersonalityResultsScreen(
                          config: const MergedConfig(
                            weightModifiers: {},
                            attachmentOverrides: {},
                            guardrailsConfig: {},
                            primaryProfile: 'legacy',
                            attachmentQuadrant: 'mixed',
                            confidenceLevel: 'Moderate',
                            recommendationGating: false,
                            reliabilityScore: 0.7,
                          ),
                          scores: const AttachmentScores(
                            anxiety: 50,
                            avoidance: 50,
                            reliabilityAlpha: 0.7,
                            attentionPassed: true,
                            socialDesirability: 0.5,
                            disorganizedLean: false,
                            quadrant: 'mixed',
                            confidenceLabel: 'Moderate',
                          ),
                          routing: const GoalRoutingResult(
                            routeTags: {'general'},
                            primaryProfile: 'general',
                          ),
                          responses: const {},
                        ),
                      );
                    case '/personality_test':
                      return MaterialPageRoute(
                        builder: (context) => PersonalityTestScreen(
                          currentIndex: 0,
                          responses: const {},
                          onComplete: (config, scores, routing) async {
                            // Navigate to tone tutorial first (new flow)
                            Navigator.pushReplacementNamed(
                              context,
                              '/tone_tutorial',
                            );
                          },
                        ),
                      );
                    case '/personality_results':
                      final args =
                          settings.arguments as Map<String, dynamic>? ?? {};
                      return MaterialPageRoute(
                        builder: (context) => PersonalityResultsScreen(
                          config:
                              args['config'] as MergedConfig? ??
                              const MergedConfig(
                                weightModifiers: {},
                                attachmentOverrides: {},
                                guardrailsConfig: {},
                                primaryProfile: 'unknown',
                                attachmentQuadrant: 'secure',
                                confidenceLevel: 'low',
                                recommendationGating: true,
                                reliabilityScore: 0.0,
                              ),
                          scores:
                              args['scores'] as AttachmentScores? ??
                              const AttachmentScores(
                                anxiety: 0,
                                avoidance: 0,
                                reliabilityAlpha: 0.0,
                                attentionPassed: false,
                                socialDesirability: 0.0,
                                disorganizedLean: false,
                                quadrant: 'secure',
                                confidenceLabel: 'low',
                              ),
                          routing:
                              args['routing'] as GoalRoutingResult? ??
                              const GoalRoutingResult(
                                routeTags: <String>{},
                                primaryProfile: 'unknown',
                              ),
                          responses:
                              args['responses'] as Map<String, int>? ?? {},
                        ),
                      );
                    case '/premium':
                      final args = settings.arguments as List<String>?;
                      return MaterialPageRoute(
                        builder: (context) => PremiumScreenProfessional(
                          personalityTestAnswers: args,
                        ),
                      );
                    case '/keyboard_intro':
                      return MaterialPageRoute(
                        builder: (context) => KeyboardIntroScreenProfessional(
                          onSkip: () => Navigator.pushReplacementNamed(
                            context,
                            '/premium',
                          ),
                        ),
                      );
                    case '/main':
                      // Simplified main entry: direct to Insights Dashboard (holds tabs incl. Settings)
                      return MaterialPageRoute(
                        builder: (context) => const InsightsDashboardEnhanced(),
                      );
                    case '/emotional-state':
                      return MaterialPageRoute(
                        builder: (context) => const EmotionalStateScreen(),
                      );
                    // Removed '/relationship_questionnaire' and '/relationship_profile' routes - screens deleted
                    // case '/analyze_tone':
                    //   return MaterialPageRoute(builder: (context) => const AnalyzeToneScreenProfessional());
                    // case '/settings':
                    //   return MaterialPageRoute(
                    //     builder: (context) => SettingsScreenProfessional(
                    //       sensitivity: 0.5,
                    //       onSensitivityChanged: (value) {},
                    //       tone: 'Polite',
                    //       onToneChanged: (tone) {},
                    //     ),
                    //   );
                    // case '/keyboard_setup':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const KeyboardSetupScreen(),
                    //   );
                    // case '/keyboard_detection':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const KeyboardDetectionScreen(),
                    //   );
                    // case '/tone_demo':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const ToneIndicatorDemoScreen(),
                    //   );
                    // case '/tone_test':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const ToneIndicatorTestScreen(),
                    //   );
                    case '/tone_tutorial':
                      return MaterialPageRoute(
                        builder: (context) => ToneIndicatorTutorialScreen(
                          onComplete: () => Navigator.pushReplacementNamed(
                            context,
                            '/keyboard_intro',
                          ),
                        ),
                      );
                    // case '/tutorial_demo':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const TutorialDemoScreen(),
                    //   );
                    // case '/color_test':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const ColorTestScreen(),
                    //   );
                    case '/relationship_insights':
                      // Backward compatibility: redirect legacy route to new insights dashboard
                      return MaterialPageRoute(
                        builder: (context) => const InsightsDashboardEnhanced(),
                      );
                    case '/communication_coach':
                      return MaterialPageRoute(
                        builder: (context) =>
                            const RealTimeCommunicationCoach(),
                      );
                    // case '/message_templates':
                    //   return MaterialPageRoute(
                    //     builder: (context) => const SmartMessageTemplates(),
                    //   );
                    // REMOVED: duplicate '/emotional_state' route - use '/emotional-state' only
                    // REMOVED: interactive_coaching_practice route
                    case '/generate_invite_code':
                      return MaterialPageRoute(
                        builder: (context) => Scaffold(
                          appBar: AppBar(
                            title: const Text('Generate Invite Code'),
                          ),
                          body: const Center(
                            child: Text('Invite code generation coming soon'),
                          ),
                        ),
                      );
                    case '/code_generate':
                      return MaterialPageRoute(
                        builder: (context) => Scaffold(
                          appBar: AppBar(title: const Text('Code Generator')),
                          body: const Center(
                            child: Text('Code generation coming soon'),
                          ),
                        ),
                      );
                    default:
                      return MaterialPageRoute(
                        builder: (context) => const Scaffold(
                          body: Center(child: Text('404 - Page not found')),
                        ),
                      );
                  }
                },
              ),
            ),
          );

          return app;
        },
      ),
    );
  }
}

class RealTimeCommunicationCoach extends StatelessWidget {
  const RealTimeCommunicationCoach({super.key});

  @override
  Widget build(BuildContext context) {
    // Replace with your actual UI
    return Scaffold(
      appBar: AppBar(title: const Text('Real-Time Communication Coach')),
      body: const Center(child: Text('Real-Time Communication Coach Content')),
    );
  }
}

class MyNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    // Send analytics event here
    super.didPush(route, previousRoute);
  }
}
