import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/unsaid_theme.dart';
import '../ui/unsaid_widgets.dart';

/// Screen shown when trial expires or user wants to subscribe
class SubscriptionScreen extends StatefulWidget {
  final bool isTrialExpired;
  final VoidCallback onSubscribe;

  const SubscriptionScreen({
    super.key,
    required this.isTrialExpired,
    required this.onSubscribe,
  });

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _fadeController, curve: Curves.easeOut));

    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UnsaidGradientScaffold(
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Lock icon
                UnsaidCard(
                  padding: const EdgeInsets.all(24),
                  child: Icon(
                    widget.isTrialExpired
                        ? Icons.lock_outline
                        : Icons.star_outline,
                    size: 80,
                    color: UnsaidPalette.blush,
                  ),
                ),

                const SizedBox(height: 32),

                // Title
                Text(
                  widget.isTrialExpired
                      ? 'Your Trial Has Ended'
                      : 'Unlock Premium Features',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: UnsaidPalette.ink,
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 16),

                // Subtitle
                Text(
                  widget.isTrialExpired
                      ? 'Continue your relationship journey with unlimited access'
                      : 'Get unlimited insights and personalized coaching',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: UnsaidPalette.softInk,
                      ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 32),

                // Features List
                UnsaidCard(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Premium Features',
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: UnsaidPalette.ink,
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Everything you need for better communication',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: UnsaidPalette.softInk,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '\$9.99/month after trial',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: UnsaidPalette.softInk,
                            ),
                      ),
                      const SizedBox(height: 20),
                      _buildFeaturesList(),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Subscribe Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _handleSubscribe,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: UnsaidPalette.blush,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.star, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          'Start Premium Subscription',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Restore Purchases Button
                TextButton(
                  onPressed: _handleRestorePurchases,
                  child: Text(
                    'Restore Purchases',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: UnsaidPalette.softInk,
                        ),
                  ),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeaturesList() {
    final features = [
      'Unlimited relationship insights',
      'Advanced communication analysis',
      'Personalized coaching suggestions',
      'Priority support',
    ];

    return Column(
      children: features.map((feature) {
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(
                Icons.check_circle,
                color: UnsaidPalette.success,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  feature,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: UnsaidPalette.ink,
                      ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  void _handleSubscribe() {
    HapticFeedback.mediumImpact();

    // TODO: Implement actual subscription purchase flow
    // This would typically involve:
    // 1. Showing Apple's subscription purchase flow
    // 2. Handling the purchase result
    // 3. Activating the subscription

    // For now, show a message that this would trigger the purchase flow
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Subscription Purchase'),
        content: const Text(
            'This would trigger the Apple subscription purchase flow. Once implemented, users would be charged automatically after the trial period.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    // Simulate successful subscription for demo
    widget.onSubscribe();
  }

  void _handleRestorePurchases() {
    HapticFeedback.lightImpact();

    // TODO: Implement restore purchases flow
    // This would typically involve:
    // 1. Calling Apple's restore purchases API
    // 2. Checking for valid subscriptions
    // 3. Activating subscription if found

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:
            Text('Restore purchases functionality would be implemented here'),
        backgroundColor: Colors.blue,
      ),
    );
  }
}
