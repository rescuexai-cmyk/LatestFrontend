import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_routes.dart';
import '../../../../core/services/api_client.dart';
import '../../../../core/services/server_config_service.dart';
import '../../../../core/services/websocket_service.dart';
import '../../../../core/theme/app_colors.dart';

class ServerConfigScreen extends ConsumerStatefulWidget {
  /// If true, user can skip and go to login (used on first-launch).
  /// If false, acts as a settings page (user came from settings).
  final bool isInitialSetup;

  const ServerConfigScreen({super.key, this.isInitialSetup = true});

  @override
  ConsumerState<ServerConfigScreen> createState() => _ServerConfigScreenState();
}

class _ServerConfigScreenState extends ConsumerState<ServerConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiUrlController;
  late final TextEditingController _wsUrlController;
  bool _autoWs = true;
  bool _isTesting = false;
  String? _testResult;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    _apiUrlController = TextEditingController(text: ServerConfigService.apiUrl);
    _wsUrlController = TextEditingController(text: ServerConfigService.wsUrl);
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _wsUrlController.dispose();
    super.dispose();
  }

  /// Derive WS URL whenever the API URL changes.
  void _onApiUrlChanged(String value) {
    if (_autoWs && value.isNotEmpty) {
      _wsUrlController.text = ServerConfigService.deriveWsUrl(value);
    }
  }

  /// Test the connection to the backend.
  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    final apiUrl = _apiUrlController.text.trim();

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));

      // Derive health URL: the /health endpoint lives at the server root,
      // not under /api, so strip the /api suffix first.
      String healthUrl = apiUrl;
      if (healthUrl.endsWith('/api')) {
        healthUrl = healthUrl.substring(0, healthUrl.length - 4);
      }

      bool connected = false;
      String message = '';

      // Attempt 1: hit /health (root-level)
      try {
        final response = await dio.get('$healthUrl/health');
        if (response.statusCode == 200) {
          connected = true;
          message = 'Connected successfully!';
        }
      } catch (_) {}

      // Attempt 2: hit an actual API endpoint as fallback
      if (!connected) {
        try {
          // Use /auth/me as fallback - doesn't require query params
          final response = await dio.get('$apiUrl/auth/me');
          if (response.statusCode != null) {
            connected = true;
            message = 'Connected to API!';
          }
        } on DioException catch (e) {
          // Even a 401 means the server is reachable
          if (e.response != null) {
            connected = true;
            message = 'Server reachable (status ${e.response!.statusCode})';
          }
        } catch (_) {}
      }

      if (connected) {
        setState(() {
          _testSuccess = true;
          _testResult = message;
        });
      } else {
        setState(() {
          _testSuccess = false;
          _testResult = 'Cannot reach server at $apiUrl';
        });
      }
    } on DioException catch (e) {
      if (e.response != null) {
        setState(() {
          _testSuccess = true;
          _testResult = 'Server reachable (status ${e.response!.statusCode})';
        });
      } else {
        setState(() {
          _testSuccess = false;
          _testResult = 'Cannot reach server: ${e.message}';
        });
      }
    } catch (e) {
      setState(() {
        _testSuccess = false;
        _testResult = 'Error: $e';
      });
    } finally {
      setState(() => _isTesting = false);
    }
  }

  /// Save and apply the configuration.
  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) return;

    final apiUrl = _apiUrlController.text.trim();
    final wsUrl = _wsUrlController.text.trim();

    await ServerConfigService.save(apiUrl: apiUrl, wsUrl: wsUrl);

    // Reinitialize ApiClient with new URL
    apiClient.reconfigure();

    // Reconnect WebSocket
    webSocketService.disconnect();
    // WebSocket will reconnect when needed (e.g. on login)

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server configuration saved!'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );

      if (widget.isInitialSetup) {
        context.go(AppRoutes.login);
      } else {
        context.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: widget.isInitialSetup
          ? null
          : AppBar(
              title: const Text('Server Configuration'),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.isInitialSetup) ...[
                  const SizedBox(height: 32),
                  // Logo / branding
                  Center(
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.settings_ethernet, color: Colors.white, size: 40),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Center(
                    child: Text(
                      'Connect to Backend',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Enter your microservices backend URL\nto get started',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],

                // --- API URL ---
                const Text(
                  'API Gateway URL',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _apiUrlController,
                  keyboardType: TextInputType.url,
                  onChanged: _onApiUrlChanged,
                  decoration: InputDecoration(
                    hintText: 'http://192.168.1.x:3000/api',
                    prefixIcon: const Icon(Icons.cloud, size: 20),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter the API URL';
                    }
                    final uri = Uri.tryParse(value.trim());
                    if (uri == null || !uri.hasScheme) {
                      return 'Enter a valid URL (e.g. http://192.168.1.5:3000/api)';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 20),

                // --- WebSocket URL ---
                Row(
                  children: [
                    const Text(
                      'WebSocket URL',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Auto', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                        const SizedBox(width: 4),
                        SizedBox(
                          height: 24,
                          child: Switch(
                            value: _autoWs,
                            onChanged: (v) {
                              setState(() => _autoWs = v);
                              if (v) _onApiUrlChanged(_apiUrlController.text);
                            },
                            activeTrackColor: AppColors.success.withAlpha(120),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _wsUrlController,
                  keyboardType: TextInputType.url,
                  enabled: !_autoWs,
                  decoration: InputDecoration(
                    hintText: 'ws://192.168.1.x:4004',
                    prefixIcon: const Icon(Icons.sync_alt, size: 20),
                    filled: true,
                    fillColor: _autoWs ? Colors.grey[100] : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey[300]!),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter the WebSocket URL';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 24),

                // --- Test Connection ---
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: _isTesting ? null : _testConnection,
                    icon: _isTesting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find, size: 20),
                    label: Text(_isTesting ? 'Testing...' : 'Test Connection'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.info,
                      side: const BorderSide(color: AppColors.info),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),

                // Test result
                if (_testResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _testSuccess
                          ? AppColors.success.withAlpha(20)
                          : AppColors.error.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _testSuccess ? AppColors.success : AppColors.error,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _testSuccess ? Icons.check_circle : Icons.error,
                          color: _testSuccess ? AppColors.success : AppColors.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _testResult!,
                            style: TextStyle(
                              color: _testSuccess ? AppColors.success : AppColors.error,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 32),

                // --- Save button ---
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _saveConfig,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Save & Continue',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),

                // --- Quick presets ---
                const SizedBox(height: 24),
                const Text(
                  'Quick Presets',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildPresetChip('Emulator', 'http://10.0.2.2:3000/api'),
                    _buildPresetChip('Localhost', 'http://localhost:3000/api'),
                    _buildPresetChip('LAN (192.168.x)', 'http://192.168.1.:3000/api'),
                  ],
                ),

                if (widget.isInitialSetup) ...[
                  const SizedBox(height: 32),
                  Center(
                    child: TextButton(
                      onPressed: () => context.go(AppRoutes.login),
                      child: Text(
                        'Skip for now (use default)',
                        style: TextStyle(color: Colors.grey[500], fontSize: 14),
                      ),
                    ),
                  ),
                ],

                // Info box
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.info.withAlpha(15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.info.withAlpha(50)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.info_outline, size: 16, color: AppColors.info),
                          SizedBox(width: 6),
                          Text(
                            'Microservices Ports',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.info),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'API Gateway: 3000  |  Auth: 4001\n'
                        'Ride: 4002  |  Driver: 4003  |  WebSocket: 4004',
                        style: TextStyle(fontSize: 12, color: Colors.grey[700], height: 1.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label, String url) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      avatar: const Icon(Icons.bolt, size: 16),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.border),
      ),
      onPressed: () {
        _apiUrlController.text = url;
        _onApiUrlChanged(url);
      },
    );
  }
}
