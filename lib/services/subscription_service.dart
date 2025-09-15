import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:http/http.dart' as http;
import 'trial_service.dart';

class SubscriptionService extends ChangeNotifier {
  static final SubscriptionService _instance = SubscriptionService._internal();
  factory SubscriptionService() => _instance;
  SubscriptionService._internal();

  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _subscription; // Made nullable
  bool _initialized = false; // Track initialization state

  // Product IDs - these should match your App Store Connect/Google Play Console setup
  static const String monthlySubscriptionId = 'unsaid_monthly_subscription';
  static const Set<String> _productIds = {monthlySubscriptionId};

  List<ProductDetails> _products = [];
  final List<PurchaseDetails> _purchases = [];
  bool _isAvailable = false;
  bool _purchasePending = false;
  bool _loading = true;
  String? _queryProductError;

  // Getters
  List<ProductDetails> get products => _products;
  List<PurchaseDetails> get purchases => _purchases;
  bool get isAvailable => _isAvailable;
  bool get purchasePending => _purchasePending;
  bool get loading => _loading;
  String? get queryProductError => _queryProductError;

  /// Initialize the subscription service
  Future<void> initialize() async {
    if (_initialized) return; // Prevent double initialization
    _initialized = true;

    // Check if in-app purchase is available
    final bool available = await _inAppPurchase.isAvailable();
    if (!available) {
      _isAvailable = false;
      _loading = false;
      notifyListeners();
      return;
    }

    // Listen to purchase updates (cancel any existing subscription first)
    _subscription?.cancel();
    final Stream<List<PurchaseDetails>> purchaseUpdated =
        _inAppPurchase.purchaseStream;
    _subscription = purchaseUpdated.listen(
      _handlePurchaseUpdate,
      onDone: () => _subscription?.cancel(),
      onError: (error) {
        print('Purchase stream error: $error');
        _purchasePending = false;
        notifyListeners();
      },
    );

    // Load products and past purchases
    await _loadProducts();
    await _loadPastPurchases();

    _isAvailable = true;
    _loading = false;
    notifyListeners();
  }

  /// Load available products from the store
  Future<void> _loadProducts() async {
    try {
      final ProductDetailsResponse productDetailResponse = await _inAppPurchase
          .queryProductDetails(_productIds);

      if (productDetailResponse.error != null) {
        _queryProductError = productDetailResponse.error!.message;
        print('Error loading products: ${productDetailResponse.error}');
        return;
      }

      if (productDetailResponse.productDetails.isEmpty) {
        _queryProductError =
            'No products found. Check your product IDs in App Store Connect/Google Play Console.';
        print('Warning: No products found for IDs: $_productIds');
        return;
      }

      _products = productDetailResponse.productDetails;
      _queryProductError = null;
    } catch (e) {
      _queryProductError = 'Failed to load products: $e';
      print('Exception loading products: $e');
    }
  }

  /// Load past purchases
  Future<void> _loadPastPurchases() async {
    try {
      await _inAppPurchase.restorePurchases();
      // Note: restorePurchases() triggers the purchase stream with past purchases
      // so we don't need to handle the response directly here
    } catch (e) {
      print('Exception loading past purchases: $e');
    }
  }

  /// Handle purchase updates from the store
  Future<void> _handlePurchaseUpdate(
    List<PurchaseDetails> purchaseDetailsList,
  ) async {
    for (final purchaseDetails in purchaseDetailsList) {
      print(
        '📱 Purchase update: ${purchaseDetails.productID} - ${purchaseDetails.status}',
      );

      switch (purchaseDetails.status) {
        case PurchaseStatus.pending:
          // Purchase is in progress, show loading state
          print('⏳ Purchase pending: ${purchaseDetails.productID}');
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Verify purchase with backend before activating
          await _verifyPurchase(purchaseDetails);
          break;

        case PurchaseStatus.error:
          print('❌ Purchase error: ${purchaseDetails.error?.message}');
          break;

        case PurchaseStatus.canceled:
          // User canceled the purchase, no action needed
          print('🚫 Purchase canceled by user: ${purchaseDetails.productID}');
          break;
      }

      // Complete the purchase to prevent duplicate processing
      if (purchaseDetails.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(purchaseDetails);
      }
    }
  }

  /// Verify purchase with backend (CRITICAL for trial guard compatibility)
  Future<void> _verifyPurchase(PurchaseDetails purchaseDetails) async {
    try {
      // Get the verification data from the purchase
      final verificationData = purchaseDetails.verificationData;

      // Prepare the payload for your backend
      final payload = {
        'receiptData': verificationData.serverVerificationData,
        'productId': purchaseDetails.productID,
        'transactionId': purchaseDetails.purchaseID,
        'platform': defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
        'userId': 'current_user_id', // TODO: Get from your auth service
      };

      // Send to your backend for verification
      final response = await http.post(
        Uri.parse('https://your-api-endpoint.com/verify-receipt'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer your-api-key', // TODO: Add proper auth
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        // Backend confirmed the purchase - now activate locally
        await _activateSubscription(purchaseDetails);
        print('✅ Purchase verified with backend: ${purchaseDetails.productID}');
      } else {
        print(
          '❌ Backend verification failed: ${response.statusCode} - ${response.body}',
        );
        // TODO: Handle verification failure (retry, alert user, etc.)
      }
    } catch (e) {
      print('❌ Exception during purchase verification: $e');
      // For now, activate locally as fallback, but this should be improved
      await _activateSubscription(purchaseDetails);
    }
  }

  /// Activate subscription locally and sync with TrialService
  Future<void> _activateSubscription(PurchaseDetails purchaseDetails) async {
    try {
      // Sync with TrialService to ensure backend compatibility
      await TrialService().activateSubscription();

      // TODO: Save subscription status to secure storage
      // TODO: Update any other local state as needed

      print('✅ Subscription activated locally: ${purchaseDetails.productID}');
    } catch (e) {
      print('❌ Error activating subscription: $e');
    }
  }

  /// Start a subscription purchase
  Future<bool> purchaseSubscription() async {
    if (_products.isEmpty) {
      print('No products available for purchase');
      return false;
    }

    // Find the monthly subscription product specifically
    final ProductDetails? productDetails = _products
        .where((product) => product.id == monthlySubscriptionId)
        .cast<ProductDetails?>()
        .firstWhere((product) => true, orElse: () => null);

    if (productDetails == null) {
      print('Monthly subscription product not found');
      return false;
    }

    final PurchaseParam purchaseParam = PurchaseParam(
      productDetails: productDetails,
    );

    try {
      _purchasePending = true;
      notifyListeners();

      final bool success = await _inAppPurchase.buyNonConsumable(
        purchaseParam: purchaseParam,
      );

      if (!success) {
        _purchasePending = false;
        notifyListeners();
      }

      return success;
    } catch (e) {
      print('Error purchasing subscription: $e');
      _purchasePending = false;
      notifyListeners();
      return false;
    }
  }

  /// Restore purchases
  Future<void> restorePurchases() async {
    try {
      await _inAppPurchase.restorePurchases();
    } catch (e) {
      print('Error restoring purchases: $e');
    }
  }

  /// Check if user has active subscription
  bool get hasActiveSubscription {
    return _purchases.any(
      (purchase) =>
          purchase.productID == monthlySubscriptionId &&
          (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored),
    );
  }

  /// Get subscription product details
  ProductDetails? get subscriptionProduct {
    return _products
        .where((product) => product.id == monthlySubscriptionId)
        .cast<ProductDetails?>()
        .firstWhere((product) => true, orElse: () => null);
  }

  /// Get formatted price
  String get subscriptionPrice {
    final product = subscriptionProduct;
    return product?.price ?? 'Price unavailable';
  }

  /// Dispose resources
  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
