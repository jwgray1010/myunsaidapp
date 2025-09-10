import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/trial_service.dart';
import './subscription_screen.dart';

class TrialGuard extends StatefulWidget {
  final Widget child;
  final bool showWarningWhenExpiring;

  const TrialGuard({
    super.key,
    required this.child,
    this.showWarningWhenExpiring = true,
  });

  @override
  State<TrialGuard> createState() => _TrialGuardState();
}

class _TrialGuardState extends State<TrialGuard> {
  DateTime? _snoozedUntil;

  bool get _isSnoozed =>
      _snoozedUntil != null && DateTime.now().isBefore(_snoozedUntil!);

  void _snooze([Duration duration = const Duration(hours: 4)]) {
    setState(() => _snoozedUntil = DateTime.now().add(duration));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child, // Main app content is always shown
        // Use Selector to avoid rebuilding entire stack on any TrialService change
        Selector<
          TrialService,
          ({bool showExpired, bool showExpiring, bool admin})
        >(
          selector: (_, trialService) => (
            showExpired:
                widget.showWarningWhenExpiring &&
                !trialService.hasAccess &&
                !trialService.isAdminMode &&
                !_isSnoozed,
            showExpiring:
                widget.showWarningWhenExpiring &&
                trialService.hasAccess &&
                !trialService.isAdminMode &&
                trialService.shouldShowSubscriptionPrompt() &&
                !_isSnoozed,
            admin: trialService.canAccessAdminMode,
          ),
          builder: (context, viewModel, _) => Stack(
            children: [
              // Show subscription prompt overlay when trial is expired (not blocking)
              if (viewModel.showExpired)
                _buildSubscriptionPromptOverlay(
                  context,
                  context.read<TrialService>(),
                  onLater: _snooze,
                ),

              // Show warning banner when trial is expiring (but not in admin mode)
              if (viewModel.showExpiring)
                _buildTrialWarningBanner(context, context.read<TrialService>()),

              // Show admin mode controls in debug mode
              if (viewModel.admin)
                _buildAdminModeControls(context, context.read<TrialService>()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrialWarningBanner(
    BuildContext context,
    TrialService trialService,
  ) {
    final theme = Theme.of(context);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.orange.shade600, Colors.deepOrange.shade600],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.timer, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      trialService.getTimeRemainingString(),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Subscribe to keep your insights',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withOpacity(0.9),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(
                      builder: (context) => SubscriptionScreen(
                        isTrialExpired: false,
                        onSubscribe: () async {
                          await trialService.activateSubscription();
                          Navigator.pop(context);
                        },
                      ),
                    ),
                  );
                },
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.white.withOpacity(0.2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                ),
                child: const Text(
                  'Subscribe',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscriptionPromptOverlay(
    BuildContext context,
    TrialService trialService, {
    VoidCallback? onLater,
  }) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.red.shade600, Colors.red.shade700],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: Colors.white, size: 32),
              const SizedBox(height: 12),
              const Text(
                'Trial Expired',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Subscribe to continue using AI features',
                style: TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed:
                          onLater, // Dismiss the overlay temporarily using callback
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.white.withOpacity(0.2),
                      ),
                      child: const Text('Later'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute(
                            builder: (context) => SubscriptionScreen(
                              isTrialExpired: true,
                              onSubscribe: () async {
                                await trialService.activateSubscription();
                                Navigator.pop(context);
                              },
                            ),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade600,
                      ),
                      child: const Text(
                        'Subscribe',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdminModeControls(
    BuildContext context,
    TrialService trialService,
  ) {
    return Positioned(
      bottom: 100,
      right: 16,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: trialService.isAdminMode ? Colors.red : Colors.grey,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'DEBUG',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => trialService.toggleAdminMode(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    trialService.isAdminMode ? 'ADMIN' : 'USER',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => trialService.resetTrial(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'RESET',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
