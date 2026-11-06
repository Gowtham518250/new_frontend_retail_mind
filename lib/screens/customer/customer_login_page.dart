import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../secure_token_storage.dart';
import 'nearby_shops_page.dart';

class CustomerLoginPage extends StatefulWidget {
  const CustomerLoginPage({super.key});

  @override
  State<CustomerLoginPage> createState() => _CustomerLoginPageState();
}

class _CustomerLoginPageState extends State<CustomerLoginPage> {
  bool _isLogin = true;
  bool _isLoading = false;
  
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _submit() async {
    setState(() => _isLoading = true);
    
    try {
      final endpoint = _isLogin ? '/store/customer/login' : '/store/customer/register';
      
      final body = _isLogin 
        ? {
            'email': _emailController.text.trim(),
            'password': _passwordController.text,
          }
        : {
            'name': _nameController.text.trim(),
            'email': _emailController.text.trim(),
            'phone': _phoneController.text.trim(),
            'password': _passwordController.text,
          };

      // Both use JSON payload
      final response = await ApiClient.postJson(endpoint, body);
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        if (_isLogin) {
          final tokenValue = data['access_token'] ?? data['token'];
          final refreshTokenValue = data['refresh_token'];
          final prefs = await SharedPreferences.getInstance();
          if (tokenValue != null) {
            final customerToken = tokenValue.toString();
            await prefs.setString('auth_token', customerToken);
            await prefs.setString('role', 'customer');
            final customerId = int.tryParse(data['customer_id']?.toString() ?? '');
            if (customerId != null && customerId > 0) {
              await prefs.setInt('current_scoped_user_id', customerId);
            }
            await SecureTokenStorage.saveCustomerToken(customerToken);
          }
          if (refreshTokenValue != null) {
            await prefs.setString('refresh_token', refreshTokenValue.toString());
          }
          await prefs.setString('user_id', data['customer_id'].toString());
          await prefs.setString('user_type', 'CUSTOMER');
          await prefs.setString('user_name', data['name'] ?? data['user_name'] ?? '');
          await prefs.setString('user_email', _emailController.text.trim());
          await prefs.setString('customer_email', _emailController.text.trim());
          if (_phoneController.text.trim().isNotEmpty) {
            await prefs.setString('customer_phone', _phoneController.text.trim());
          }
          
          if (mounted) {
            Navigator.pushReplacement(
              context, 
              MaterialPageRoute(builder: (_) => const NearbyShopsPage())
            );
          }
        } else {
          // Registered successfully, now login
          setState(() => _isLogin = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Registration successful! Please login.'), backgroundColor: Colors.green),
          );
        }
      } else {
        throw Exception(json.decode(response.body)['detail'] ?? 'Authentication failed');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.teal.shade50,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shopping_bag_rounded, size: 80, color: Colors.teal.shade600),
                const SizedBox(height: 16),
                Text('Retail Mind Market', style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.teal.shade900)),
                Text(_isLogin ? 'Welcome back, shopper!' : 'Create your account', style: GoogleFonts.poppins(color: Colors.teal.shade700)),
                const SizedBox(height: 40),
                
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        if (!_isLogin) ...[
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(labelText: 'Full Name', prefixIcon: Icon(Icons.person_outline)),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Phone (10 digits)', prefixIcon: Icon(Icons.phone_outlined)),
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email Address', prefixIcon: Icon(Icons.email_outlined)),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal.shade600,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _isLoading ? null : _submit,
                            child: _isLoading 
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white))
                              : Text(_isLogin ? 'Login' : 'Register', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => setState(() => _isLogin = !_isLogin),
                          child: Text(_isLogin ? 'Need an account? Register' : 'Already have an account? Login', style: TextStyle(color: Colors.teal.shade700)),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('Back to Home', style: TextStyle(color: Colors.grey.shade600)),
                        )
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
