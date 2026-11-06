import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'api_client.dart';
import 'secure_token_storage.dart';
import 'online_order_service.dart';

/// Loads products for a customer's selected online shop.
class CustomerShopService {
  /// Fetch in-stock products with price > 0.
  static Future<List<Map<String, dynamic>>> fetchProducts(String shopId) async {
    if (shopId.isEmpty) return [];

    List<Map<String, dynamic>> products = [];

    try {
      final res = await ApiClient.getJson(
        '/api/inventory/products?shop_id=$shopId',
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        final List raw = body is List ? body : (body['products'] as List? ?? []);
        if (raw.isNotEmpty) {
          products = raw.map((p) => _normalizeProduct(p as Map)).toList();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerShopService API: $e');
    }

    if (products.isEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('products')
            .where('available', isEqualTo: true)
            .get();

        if (snap.docs.isNotEmpty) {
          products = snap.docs.map((d) {
            final data = d.data();
            return _normalizeProduct({
              'id': d.id,
              'product_name': data['name'] ?? data['product_name'],
              'price': data['price'],
              'stock': data['stock'] ?? data['quantity'],
              'image_url': data['image_url'],
              'category': data['category'],
            });
          }).toList();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('CustomerShopService Firestore: $e');
      }
    }

    return _filterInStock(products);
  }

  static List<Map<String, dynamic>> _filterInStock(List<Map<String, dynamic>> list) {
    return list.where((p) {
      final price = (p['price'] as num?)?.toDouble() ?? 0;
      final stock = (p['stock'] as num?)?.toInt() ?? 0;
      return price > 0 && stock > 0;
    }).toList();
  }

  static Future<String> fetchShopName(String shopId) async {
    if (shopId.isEmpty) return 'Shop';
    try {
      final doc = await FirebaseFirestore.instance.collection('shops').doc(shopId).get();
      if (doc.exists) {
        return doc.data()?['shop_name']?.toString() ?? 'Shop';
      }
    } catch (_) {}
    return 'Shop';
  }

  static Map<String, dynamic> _normalizeProduct(Map raw) {
    final name = (raw['product_name'] ?? raw['name'] ?? raw['product'] ?? 'Item').toString();
    final price = double.tryParse(raw['price']?.toString() ?? raw['selling_price']?.toString() ?? '0') ?? 0;
    final stock = int.tryParse(raw['stock']?.toString() ?? raw['quantity']?.toString() ?? '0') ?? 0;
    final id = (raw['id'] ?? raw['product_id'] ?? name).toString();
    final imageUrl = (raw['image_url'] ?? raw['imageUrl'] ?? raw['photo'] ?? '').toString();
    return {
      'id': id,
      'name': name,
      'price': price,
      'stock': stock,
      'category': raw['category']?.toString() ?? 'General',
      'image_url': imageUrl,
    };
  }

  /// Create the canonical customer order in FastAPI/PostgreSQL.
  /// Never fall back to a Firestore-only order: Cashfree callbacks must map
  /// to the same server-side order and payment ledger.
  static Future<String> placeOrder({
    required String shopId,
    required String shopName,
    required String customerEmail,
    required List<Map<String, dynamic>> items,
    required double totalAmount,
    required String paymentMethod,
    required String idempotencyKey,
    String paymentStatus = 'pending',
  }) async {
    final token = await SecureTokenStorage.getCustomerToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Customer session expired. Please sign in again.');
    }

    final response = await http.post(
      Uri.parse('${ApiClient.baseUrl}/store/order'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'shop_id': int.tryParse(shopId) ?? 0,
        'items': items.map((item) => {
          'product_id': int.tryParse(item['id'].toString()) ?? 0,
          'quantity': int.tryParse(item['qty']?.toString() ?? '1') ?? 1,
        }).toList(),
        'delivery_address': 'Store Pickup',
        'payment_method': paymentMethod.toUpperCase() == 'UPI' ? 'UPI' : 'COD',
        'idempotency_key': idempotencyKey,
      }),
    ).timeout(const Duration(seconds: 30));

    final body = _decodeResponse(response.body);
    if (response.statusCode != 200 && response.statusCode != 201) {
      final detail = body['detail'] ?? body['message'];
      throw Exception(detail?.toString() ?? 'Unable to create the online order.');
    }
    final orderId = body['order_id']?.toString();
    if (orderId == null || orderId.isEmpty || orderId == 'ORDER_OK') {
      throw Exception('The backend did not return a valid order ID.');
    }
    return orderId;
  }

  /// Read the public shop configuration before showing payment methods.
  static Future<Map<String, bool>> fetchShopPaymentOptions(String shopId) async {
    final response = await http.get(
      Uri.parse('${ApiClient.baseUrl}/store/shops/$shopId/products?limit=1'),
    ).timeout(const Duration(seconds: 15));
    final body = _decodeResponse(response.body);
    if (response.statusCode != 200) {
      throw Exception('Unable to load this shop’s payment options.');
    }
    return {
      'accept_cod': body['accept_cod'] == true,
      'accept_online': body['accept_online'] == true,
    };
  }

  /// Ask the backend to create/reuse the Cashfree session for this saved order.
  static Future<Map<String, dynamic>> createCashfreeCheckoutSession(
    String orderId,
  ) async {
    final token = await SecureTokenStorage.getCustomerToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Customer session expired. Please sign in again.');
    }
    final response = await http.post(
      Uri.parse('${ApiClient.baseUrl}/store/order/$orderId/cashfree/session'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    ).timeout(const Duration(seconds: 30));
    final body = _decodeResponse(response.body);
    if (response.statusCode != 200 || body['success'] != true) {
      throw Exception(body['detail']?.toString() ?? 'Unable to start secure checkout.');
    }
    return body;
  }

  /// Confirm SDK callbacks against the backend/provider APIs.
  static Future<Map<String, dynamic>> getCashfreePaymentStatus(
    String orderId,
  ) async {
    final token = await SecureTokenStorage.getCustomerToken();
    if (token == null || token.trim().isEmpty) {
      throw Exception('Customer session expired. Please sign in again.');
    }
    final response = await http.get(
      Uri.parse('${ApiClient.baseUrl}/store/order/$orderId/cashfree/status'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 20));
    final body = _decodeResponse(response.body);
    if (response.statusCode != 200) {
      throw Exception(body['detail']?.toString() ?? 'Unable to verify payment status.');
    }
    return body;
  }

  static Map<String, dynamic> _decodeResponse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Do not expose arbitrary HTML/error payloads to the customer.
    }
    return <String, dynamic>{};
  }

  /// Push owner inventory row to Firestore (stock + image for storefront).
  static Future<void> upsertProductToFirestore({
    required String shopId,
    required String productId,
    required String name,
    required double price,
    required int stock,
    String? imageUrl,
    String category = 'General',
  }) async {
    if (shopId.isEmpty) return;
    final available = stock > 0 && price > 0;
    await FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('products')
        .doc(productId)
        .set({
      'name': name,
      'price': price,
      'stock': stock,
      'available': available,
      'image_url': imageUrl ?? '',
      'category': category,
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> syncInventoryToFirestore(
    String shopId,
    List<Map<String, dynamic>> inventory,
  ) async {
    if (shopId.isEmpty) return;
    for (final item in inventory) {
      final name = (item['product_name'] ?? item['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final id = (item['id'] ?? name).toString().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
      final stock = int.tryParse(item['stock']?.toString() ?? item['quantity']?.toString() ?? '0') ?? 0;
      final imageUrl = (item['image_url'] ?? item['imageUrl'] ?? '').toString();
      await upsertProductToFirestore(
        shopId: shopId,
        productId: id,
        name: name,
        price: price,
        stock: stock,
        imageUrl: imageUrl.isEmpty ? null : imageUrl,
      );
    }
    await OnlineOrderService.syncShopUpiToFirestore(shopId);
  }
}
