import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpayment/cfwebcheckoutpayment.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpaymentgateway/cfpaymentgatewayservice.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfsession/cfsession.dart';
import 'package:flutter_cashfree_pg_sdk/api/cferrorresponse/cferrorresponse.dart';
import 'package:flutter_cashfree_pg_sdk/utils/cfenums.dart';
import '../../visual_widgets.dart';
import '../../customer_shop_service.dart';

class CustomerCartPage extends StatefulWidget {
  final List<Map<String, dynamic>> cartItems;
  final String shopId;
  final String shopName;

  const CustomerCartPage({
    super.key,
    required this.cartItems,
    this.shopId = '',
    this.shopName = 'Shop',
  });

  @override
  State<CustomerCartPage> createState() => _CustomerCartPageState();
}

class _CustomerCartPageState extends State<CustomerCartPage> {
  late List<Map<String, dynamic>> _items;
  bool _isPlacingOrder = false;
  bool _loadingPaymentOptions = true;
  bool _acceptCod = false;
  bool _acceptOnline = false;
  bool _awaitingPayment = false;
  String _paymentMode = 'cod';
  String? _activeOrderId;
  late final String _checkoutIdempotencyKey;
  final CFPaymentGatewayService _cashfreeGateway = CFPaymentGatewayService();

  @override
  void initState() {
    super.initState();
    _items = List<Map<String, dynamic>>.from(widget.cartItems);
    _checkoutIdempotencyKey = 'flutter-${const Uuid().v4()}';
    _cashfreeGateway.setCallback(_onCashfreeVerify, _onCashfreeError);
    _loadPaymentOptions();
  }

  Future<void> _loadPaymentOptions() async {
    try {
      final options = await CustomerShopService.fetchShopPaymentOptions(widget.shopId);
      if (!mounted) return;
      setState(() {
        _acceptCod = options['accept_cod'] == true;
        _acceptOnline = options['accept_online'] == true;
        _paymentMode = (!_acceptCod && _acceptOnline) ? 'upi' : 'cod';
        _loadingPaymentOptions = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _acceptCod = false;
        _acceptOnline = false;
        _loadingPaymentOptions = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to load shop payment options: $error')),
      );
    }
  }

  double get _totalAmount {
    return _items.fold(0.0, (sum, item) => sum + (item['price'] as num) * (item['qty'] as num));
  }

  Future<void> _placeOrder() async {
    if (_isPlacingOrder || _loadingPaymentOptions) return;
    setState(() => _isPlacingOrder = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('customer_email') ??
          prefs.getString('user_email') ??
          'customer@retailmind.local';

      if (_paymentMode == 'upi' && _activeOrderId != null) {
        await _launchCashfreeCheckout(_activeOrderId!);
        return;
      }

      final orderId = await CustomerShopService.placeOrder(
        shopId: widget.shopId,
        shopName: widget.shopName,
        customerEmail: email,
        items: _items,
        totalAmount: _totalAmount,
        paymentMethod: _paymentMode == 'upi' ? 'UPI' : 'COD',
        idempotencyKey: _checkoutIdempotencyKey,
      );
      await prefs.setString('last_online_order_id', orderId);
      if (!mounted) return;

      if (_paymentMode == 'upi') {
        _activeOrderId = orderId;
        await _launchCashfreeCheckout(orderId);
      } else {
        Navigator.pushReplacementNamed(
          context,
          '/order-tracking',
          arguments: {'orderId': orderId},
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order/payment could not be started: $error'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isPlacingOrder = false);
    }
  }

  Future<void> _launchCashfreeCheckout(String retailMindOrderId) async {
    final response = await CustomerShopService.createCashfreeCheckoutSession(
      retailMindOrderId,
    );
    final providerOrderId = response['cashfree_order_id']?.toString() ?? '';
    final paymentSessionId = response['payment_session_id']?.toString() ?? '';
    if (providerOrderId.isEmpty || paymentSessionId.isEmpty) {
      throw Exception('Cashfree did not return a valid checkout session.');
    }

    final envName = (response['environment'] ?? 'sandbox').toString().toLowerCase();
    final environment = envName == 'production'
        ? CFEnvironment.PRODUCTION
        : CFEnvironment.SANDBOX;
    final session = CFSessionBuilder()
        .setEnvironment(environment)
        .setOrderId(providerOrderId)
        .setPaymentSessionId(paymentSessionId)
        .build();
    final checkout = CFWebCheckoutPaymentBuilder()
        .setSession(session)
        .build();

    _cashfreeGateway.setCallback(_onCashfreeVerify, _onCashfreeError);
    _cashfreeGateway.doPayment(checkout);
    if (mounted) setState(() => _awaitingPayment = true);
  }

  void _onCashfreeVerify(String providerOrderId) {
    final orderId = _activeOrderId;
    if (orderId != null) _confirmCashfreePayment(orderId);
  }

  void _onCashfreeError(CFErrorResponse errorResponse, String providerOrderId) {
    final orderId = _activeOrderId;
    if (orderId == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cashfree checkout response: ${errorResponse.getMessage()}')),
      );
    }
    _confirmCashfreePayment(orderId);
  }

  Future<void> _confirmCashfreePayment(String orderId) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final status = await CustomerShopService.getCashfreePaymentStatus(orderId);
        if (status['paid'] == true) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_online_order_id', orderId);
          if (!mounted) return;
          setState(() {
            _awaitingPayment = false;
            _activeOrderId = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Payment verified. Your order is confirmed.'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pushReplacementNamed(
            context,
            '/order-tracking',
            arguments: {'orderId': orderId},
          );
          return;
        }
      } catch (_) {
        // Keep the order unpaid unless the backend confirms it.
      }
      if (attempt < 4) await Future.delayed(const Duration(seconds: 2));
    }

    if (!mounted) return;
    setState(() => _awaitingPayment = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Payment is not confirmed yet. Your order remains unpaid; retry secure payment or check Order Tracking.'),
        duration: Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDark,
      appBar: AppBar(
        title: const Text('Your Cart', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _items.isEmpty
          ? const Center(child: Text('Your cart is empty', style: TextStyle(color: Colors.white)))
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      ..._items.map((item) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: GlassContainer(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                _productThumb(item['image_url']?.toString()),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['name'],
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '₹${item['price']} x ${item['qty']}',
                                        style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '₹${(item['price'] as num) * (item['qty'] as num)}',
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 8),
                      const Text('Payment method', style: TextStyle(color: Colors.white70, fontSize: 14)),
                      const SizedBox(height: 8),
                      if (_loadingPaymentOptions)
                        const LinearProgressIndicator()
                      else if (!_acceptCod && !_acceptOnline)
                        const Text(
                          'This shop has not enabled online checkout payments yet.',
                          style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                        )
                      else
                        Row(
                          children: [
                            if (_acceptOnline)
                              Expanded(
                                child: ChoiceChip(
                                  label: const Text('Secure online payment'),
                                  selected: _paymentMode == 'upi',
                                  onSelected: (_) => setState(() => _paymentMode = 'upi'),
                                  selectedColor: AppColors.primary,
                                ),
                              ),
                            if (_acceptOnline && _acceptCod) const SizedBox(width: 8),
                            if (_acceptCod)
                              Expanded(
                                child: ChoiceChip(
                                  label: const Text('Cash on delivery'),
                                  selected: _paymentMode == 'cod',
                                  onSelected: (_) => setState(() => _paymentMode = 'cod'),
                                  selectedColor: AppColors.primary,
                                ),
                              ),
                          ],
                        ),
                      if (_paymentMode == 'upi' && _acceptOnline) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.verified_user_outlined, color: AppColors.primary),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Secure checkout powered by Cashfree. Choose an available payment method in the hosted checkout. Retail Mind confirms payment with the server before showing it as paid.',
                                  style: TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_activeOrderId != null && _awaitingPayment) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Payment is pending for order #$_activeOrderId. You can retry without placing another order.',
                          style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total', style: TextStyle(color: Colors.white, fontSize: 18)),
                          Text(
                            '₹${_totalAmount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (_isPlacingOrder || _loadingPaymentOptions || (!_acceptCod && !_acceptOnline)) ? null : _placeOrder,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: _isPlacingOrder
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : Text(
                                  _paymentMode == 'upi'
                                      ? (_activeOrderId == null ? 'Place order & pay securely' : 'Retry secure payment')
                                      : 'Place order (COD)',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _productThumb(String? url) {
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderIcon(),
        ),
      );
    }
    return _placeholderIcon();
  }

  Widget _placeholderIcon() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.shopping_bag, color: AppColors.primary),
    );
  }
}
