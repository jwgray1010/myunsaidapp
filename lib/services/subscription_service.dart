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
  Timer? _pendingPurchaseTimer; // Timer to clear stuck pending state

  // Product IDs - these should match your App Store Connect/Google Play Console setup
  static const String monthlySubscriptionId = 'unsaid_monthly_subscription';
  static const Set<String> _productIds = {monthlySubscriptionId};

  List<ProductDetails> _products = [];
  final List<PurchaseDetails> _purchases = [];
  bool _isStoreAvailable = false;
  bool _areProductsLoaded = false;
  bool _purchasePending = false;
  bool _loading = true;
  String? _queryProductError;

  // Getters
  List<ProductDetails> get products => _products;
  List<PurchaseDetails> get purchases => _purchases;
  bool get isStoreAvailable => _isStoreAvailable;
  bool get areProductsLoaded => _areProductsLoaded;
  bool get isAvailable =>
      _isStoreAvailable && _areProductsLoaded; // Overall availability
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
      _isStoreAvailable = false;
      _areProductsLoaded = false;
      _loading = false;
      notifyListeners();
      return;
    }

    _isStoreAvailable = true;

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

    _areProductsLoaded = true;
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
        _areProductsLoaded = false;
        print('Error loading products: ${productDetailResponse.error}');
        return;
      }

      if (productDetailResponse.productDetails.isEmpty) {
        _queryProductError =
            'No products found. Check your product IDs in App Store Connect/Google Play Console.';
        _areProductsLoaded = false;
        print('Warning: No products found for IDs: $_productIds');
        return;
      }

      _products = productDetailResponse.productDetails;
      _queryProductError = null;
      _areProductsLoaded = true;
    } catch (e) {
      _queryProductError = 'Failed to load products: $e';
      _areProductsLoaded = false;
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
    // First, deduplicate purchases by purchaseID
    final Map<String, PurchaseDetails> deduplicatedPurchases = {};
    for (final purchase in purchaseDetailsList) {
      final purchaseId = purchase.purchaseID;
      if (purchaseId == null) continue; // Skip purchases without ID

      final existing = deduplicatedPurchases[purchaseId];
      if (existing == null || purchase.status != PurchaseStatus.pending) {
        // Keep the most recent non-pending status, or any pending if no other exists
        deduplicatedPurchases[purchaseId] = purchase;
      }
    }

    // Update the purchases list with deduplicated data
    _purchases.clear();
    _purchases.addAll(deduplicatedPurchases.values);

    // Process each unique purchase
    for (final purchaseDetails in deduplicatedPurchases.values) {
      print(
        '📱 Purchase update: ${purchaseDetails.productID} - ${purchaseDetails.status}',
      );

      switch (purchaseDetails.status) {
        case PurchaseStatus.pending:
          // Purchase is in progress, show loading state
          _purchasePending = true;
          print('⏳ Purchase pending: ${purchaseDetails.productID}');
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Verify purchase with backend before activating
          _purchasePending = false;
          await _verifyPurchase(purchaseDetails);
          break;

        case PurchaseStatus.error:
          _purchasePending = false;
          print('❌ Purchase error: ${purchaseDetails.error?.message}');
          break;

        case PurchaseStatus.canceled:
          // User canceled the purchase, clear pending state
          _purchasePending = false;
          print('🚫 Purchase canceled by user: ${purchaseDetails.productID}');
          break;
      }

      // Complete the purchase to prevent duplicate processing
      if (purchaseDetails.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(purchaseDetails);
      }
    }

    notifyListeners();
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
      };

      // Get the API base URL from environment or use default
      final apiBaseUrl =
          'https://your-api-endpoint.com'; // TODO: Get from environment
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/v1/verify-receipt'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer your-api-key', // TODO: Add proper auth
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData['success'] == true) {
          // Backend confirmed the purchase - now activate locally
          await _activateSubscription(purchaseDetails);
          print(
            '✅ Purchase verified with backend: ${purchaseDetails.productID}',
          );
        } else {
          print('❌ Backend verification failed: ${responseData['message']}');
          // TODO: Handle verification failure (retry, alert user, etc.)
        }
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

      // Set a timeout to clear pending state if purchase doesn't complete
      _pendingPurchaseTimer?.cancel();
      _pendingPurchaseTimer = Timer(const Duration(seconds: 60), () {
        if (_purchasePending) {
          print('⚠️ Purchase timeout - clearing pending state');
          _purchasePending = false;
          notifyListeners();
        }
      });

      final bool success = await _inAppPurchase.buyNonConsumable(
        purchaseParam: purchaseParam,
      );

      // Cancel the timeout timer since purchase completed
      _pendingPurchaseTimer?.cancel();
      _pendingPurchaseTimer = null;

      if (!success) {
        _purchasePending = false;
        notifyListeners();
      }

      return success;
    } catch (e) {
      // Cancel the timeout timer on error
      _pendingPurchaseTimer?.cancel();
      _pendingPurchaseTimer = null;

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
    _pendingPurchaseTimer?.cancel();
    super.dispose();
  }
}
