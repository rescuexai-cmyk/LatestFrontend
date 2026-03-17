import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/app_config.dart';

class ApiClient {
  late Dio _dio;
  String? _authToken;
  String? _refreshToken;
  bool _isRefreshing = false;
  void Function()? _onAuthError;

  ApiClient() {
    _initDio(AppConfig.apiUrl);
  }
  
  /// Set callback for auth errors (401 after refresh fails, 403 deactivated)
  void setOnAuthError(void Function()? callback) {
    _onAuthError = callback;
  }
  
  /// Set refresh token for automatic token refresh
  void setRefreshToken(String? token) {
    _refreshToken = token;
  }
  
  /// Attempt to refresh the access token
  Future<bool> _attemptTokenRefresh() async {
    if (_refreshToken == null) return false;
    
    try {
      // Create a new Dio instance to avoid interceptor loop
      final refreshDio = Dio(BaseOptions(
        baseUrl: _dio.options.baseUrl,
        headers: {'Content-Type': 'application/json'},
      ));
      
      final response = await refreshDio.post('/auth/refresh', data: {
        'refreshToken': _refreshToken,
      });
      
      final data = response.data as Map<String, dynamic>?;
      if (data?['success'] == true) {
        final newAccessToken = data?['data']?['accessToken'] as String?;
        final newRefreshToken = data?['data']?['refreshToken'] as String?;
        
        if (newAccessToken != null) {
          _authToken = newAccessToken;
          if (newRefreshToken != null) {
            _refreshToken = newRefreshToken;
          }
          debugPrint('🔄 Token refreshed successfully');
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('🔄 Token refresh error: $e');
      return false;
    }
  }

  void _initDio(String baseUrl) {
    debugPrint('ApiClient initializing with baseUrl: $baseUrl');
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        debugPrint('🌐 API Request: ${options.method} ${options.uri}');
        if (_authToken != null) {
          options.headers['Authorization'] = 'Bearer $_authToken';
          final tokenPreview = _authToken!.length > 30 
              ? '${_authToken!.substring(0, 30)}...' 
              : _authToken;
          debugPrint('🔑 Auth header: Bearer $tokenPreview');
          if (!_authToken!.startsWith('eyJ')) {
            debugPrint('⚠️ WARNING: Token does not look like a valid JWT (should start with "eyJ")');
          }
        }
        return handler.next(options);
      },
      onResponse: (response, handler) {
        debugPrint('✅ API Response: ${response.statusCode} ${response.requestOptions.uri}');
        return handler.next(response);
      },
      onError: (error, handler) async {
        debugPrint('❌ API Error: ${error.response?.statusCode} ${error.requestOptions.uri}');
        debugPrint('   Error: ${error.message}');
        
        final statusCode = error.response?.statusCode;
        
        // Handle 401 Unauthorized - attempt token refresh
        if (statusCode == 401 && _refreshToken != null && !_isRefreshing) {
          _isRefreshing = true;
          try {
            final refreshResult = await _attemptTokenRefresh();
            _isRefreshing = false;
            
            if (refreshResult) {
              // Retry the original request with new token
              final opts = error.requestOptions;
              opts.headers['Authorization'] = 'Bearer $_authToken';
              final response = await _dio.fetch(opts);
              return handler.resolve(response);
            }
          } catch (e) {
            _isRefreshing = false;
            debugPrint('Token refresh failed: $e');
          }
          // Refresh failed - trigger logout via callback
          _onAuthError?.call();
        }
        
        // Handle 403 Forbidden - user may be deactivated or lack permissions
        if (statusCode == 403) {
          final message = error.response?.data?['message']?.toString() ?? '';
          if (message.contains('deactivated') || message.contains('isActive')) {
            _onAuthError?.call();
          }
        }
        
        return handler.next(error);
      },
    ));
  }

  /// Reinitialize Dio with a new base URL (called after server config changes).
  void reconfigure() {
    final token = _authToken;
    _initDio(AppConfig.apiUrl);
    _authToken = token;
  }

  void setAuthToken(String? token) {
    _authToken = token;
    if (token != null) {
      final preview = token.length > 30 ? '${token.substring(0, 30)}...' : token;
      debugPrint('🔐 setAuthToken called with: $preview');
      if (!token.startsWith('eyJ')) {
        debugPrint('⚠️ WARNING: Token set is NOT a valid JWT format!');
      }
    } else {
      debugPrint('🔐 setAuthToken cleared (null)');
    }
  }

  // Generic HTTP methods for flexible API calls
  Future<Response> get(String path, {Map<String, dynamic>? queryParameters}) async {
    return await _dio.get(path, queryParameters: queryParameters);
  }

  Future<Response> post(String path, {dynamic data, Map<String, dynamic>? queryParameters}) async {
    return await _dio.post(path, data: data, queryParameters: queryParameters);
  }

  Future<Response> put(String path, {dynamic data, Map<String, dynamic>? queryParameters}) async {
    return await _dio.put(path, data: data, queryParameters: queryParameters);
  }

  Future<Response> patch(String path, {dynamic data, Map<String, dynamic>? queryParameters}) async {
    return await _dio.patch(path, data: data, queryParameters: queryParameters);
  }

  Future<Response> delete(String path, {Map<String, dynamic>? queryParameters}) async {
    return await _dio.delete(path, queryParameters: queryParameters);
  }

  // ─────────────────────────────────────────────
  // AUTHENTICATION  (Backend: auth-service via gateway /api/auth/*)
  // ─────────────────────────────────────────────

  /// Request OTP for phone number.
  /// Backend: POST /api/auth/send-otp  body: { phone, countryCode? }
  /// Returns: { success: bool, message: string }
  Future<Map<String, dynamic>> requestOTP(String phone, {String countryCode = '+91'}) async {
    try {
      final response = await _dio.post('/auth/send-otp', data: {
        'phone': phone,
        'countryCode': countryCode,
      });
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      debugPrint('requestOTP error: ${e.response?.data}');
      rethrow;
    }
  }

  /// Verify OTP and get auth tokens.
  /// Backend: POST /api/auth/verify-otp  body: { phone, otp, countryCode? }
  /// Returns: { success, message, data: { user, tokens: { accessToken, refreshToken, expiresIn } } }
  Future<Map<String, dynamic>> verifyOTP(
    String phone,
    String otp, {
    String countryCode = '+91',
  }) async {
    try {
      final response = await _dio.post('/auth/verify-otp', data: {
        'phone': phone,
        'otp': otp,
        'countryCode': countryCode,
      });
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      debugPrint('verifyOTP error: ${e.response?.data}');
      if (e.response?.data != null && e.response?.data is Map) {
        return e.response!.data as Map<String, dynamic>;
      }
      return {
        'success': false,
        'message': e.response?.statusMessage ?? 'OTP verification failed',
      };
    }
  }

  /// Authenticate with Firebase ID token.
  /// Backend: POST /api/auth/firebase-phone  body: { firebaseIdToken }
  /// Returns: { success, message, data: { user, tokens: { accessToken, refreshToken, expiresIn } } }
  Future<Map<String, dynamic>> authenticateWithFirebase(String idToken) async {
    try {
      debugPrint('🔥 Sending Firebase ID token to backend...');
      final response = await _dio.post('/auth/firebase-phone', data: {
        'firebaseIdToken': idToken,
      });
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      debugPrint('🔥 Firebase auth error: ${e.response?.data}');
      if (e.response?.data != null && e.response?.data is Map) {
        return e.response!.data as Map<String, dynamic>;
      }
      return {
        'success': false,
        'message': e.response?.statusMessage ?? 'Firebase authentication failed',
      };
    }
  }

  /// Authenticate with verified phone number (after external OTP verification).
  /// Backend: POST /api/auth/phone  body: { phone }
  /// Returns: { success, message, data: { user, tokens: { accessToken, refreshToken, expiresIn }, isNewUser } }
  Future<Map<String, dynamic>> authenticateWithPhone(String phone) async {
    try {
      debugPrint('📱 Authenticating with verified phone: $phone');
      final response = await _dio.post('/auth/phone', data: {
        'phone': phone,
      });
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      debugPrint('📱 Phone auth error: ${e.response?.data}');
      if (e.response?.data != null && e.response?.data is Map) {
        return e.response!.data as Map<String, dynamic>;
      }
      return {
        'success': false,
        'message': e.response?.statusMessage ?? 'Phone authentication failed',
      };
    }
  }

  /// Sign out (invalidate refresh token).
  /// Backend: POST /api/auth/logout  body: { refreshToken }
  Future<void> signOut({String? refreshToken}) async {
    try {
      await _dio.post('/auth/logout', data: {
        if (refreshToken != null) 'refreshToken': refreshToken,
      });
      _authToken = null;
    } catch (e) {
      debugPrint('signOut error: $e');
      _authToken = null;
    }
  }

  /// Get current authenticated user profile.
  /// Backend: GET /api/auth/me
  /// Returns: { success, data: { user: { id, email, phone, firstName, lastName, ... } } }
  Future<Map<String, dynamic>> getCurrentUser() async {
    final response = await _dio.get('/auth/me');
    return response.data as Map<String, dynamic>;
  }

  /// Update user profile.
  /// Backend: PUT /api/auth/profile  body: { firstName?, lastName?, email?, profileImage? }
  Future<Map<String, dynamic>> updateUser(Map<String, dynamic> userData) async {
    final response = await _dio.put('/auth/profile', data: userData);
    return response.data as Map<String, dynamic>;
  }

  /// Refresh access token.
  /// Backend: POST /api/auth/refresh  body: { refreshToken }
  Future<Map<String, dynamic>> refreshToken(String refreshToken) async {
    final response = await _dio.post('/auth/refresh', data: {
      'refreshToken': refreshToken,
    });
    return response.data as Map<String, dynamic>;
  }

  // ─────────────────────────────────────────────
  // RIDES  (Backend: ride-service via gateway /api/rides/*)
  // ─────────────────────────────────────────────

  /// Create a ride.
  /// Backend: POST /api/rides  body: { pickupLat, pickupLng, dropLat, dropLng,
  ///   pickupAddress, dropAddress, paymentMethod, waypoints?, scheduledTime?, vehicleType? }
  /// waypoints: optional list of {lat, lng, address} for multi-stop trips (Ola/Uber/Rapido style)
  Future<Map<String, dynamic>> createRide({
    required double pickupLat,
    required double pickupLng,
    required double dropLat,
    required double dropLng,
    required String pickupAddress,
    required String dropAddress,
    required String paymentMethod,
    List<Map<String, dynamic>>? waypoints,
    String? scheduledTime,
    String? vehicleType,
  }) async {
    final data = <String, dynamic>{
      'pickupLat': pickupLat,
      'pickupLng': pickupLng,
      'dropLat': dropLat,
      'dropLng': dropLng,
      'pickupAddress': pickupAddress,
      'dropAddress': dropAddress,
      'paymentMethod': paymentMethod,
      if (scheduledTime != null) 'scheduledTime': scheduledTime,
      if (vehicleType != null) 'vehicleType': vehicleType,
    };
    if (waypoints != null && waypoints.isNotEmpty) {
      data['waypoints'] = waypoints;
    }
    final response = await _dio.post('/rides', data: data);
    return response.data as Map<String, dynamic>;
  }

  /// Get user's ride history (authenticated).
  /// Backend: GET /api/rides?page=&limit=
  Future<Map<String, dynamic>> getUserRides({int page = 1, int limit = 20}) async {
    final response = await _dio.get('/rides', queryParameters: {
      'page': page,
      'limit': limit,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Get a single ride by ID.
  /// Backend: GET /api/rides/:id
  Future<Map<String, dynamic>> getRide(String rideId) async {
    final response = await _dio.get('/rides/$rideId');
    return response.data as Map<String, dynamic>;
  }

  /// Get available rides for driver.
  /// Backend: GET /api/rides/available?lat=&lng=&radius=
  Future<Map<String, dynamic>> getAvailableRides({
    required double lat,
    required double lng,
    int radius = 10,
  }) async {
    final response = await _dio.get('/rides/available', queryParameters: {
      'lat': lat,
      'lng': lng,
      'radius': radius,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Update ride status.
  /// Backend: PUT /api/rides/:id/status  body: { status, cancellationReason?, tolls?, waitingMinutes?, parkingFees?, extraStopsCount?, discountPercent? }
  /// Valid statuses: CONFIRMED, DRIVER_ARRIVED, RIDE_STARTED, RIDE_COMPLETED, CANCELLED
  Future<Map<String, dynamic>> updateRideStatus(
    String rideId,
    String status, {
    String? reason,
    double? tolls,
    int? waitingMinutes,
    double? parkingFees,
    int? extraStopsCount,
    double? discountPercent,
  }) async {
    final data = <String, dynamic>{
      'status': status,
      if (reason != null) 'cancellationReason': reason,
      if (tolls != null) 'tolls': tolls,
      if (waitingMinutes != null) 'waitingMinutes': waitingMinutes,
      if (parkingFees != null) 'parkingFees': parkingFees,
      if (extraStopsCount != null) 'extraStopsCount': extraStopsCount,
      if (discountPercent != null) 'discountPercent': discountPercent,
    };
    final response = await _dio.put('/rides/$rideId/status', data: data);
    return response.data as Map<String, dynamic>;
  }
  
  /// Start ride with OTP verification.
  /// Backend: POST /api/rides/:id/start  body: { otp }
  /// Driver must provide the OTP that passenger received during ride creation.
  /// Returns: { success, data: { ride } } or error if OTP is invalid
  Future<Map<String, dynamic>> startRide(String rideId, String otp) async {
    try {
      final response = await _dio.post('/rides/$rideId/start', data: {
        'otp': otp,
      });
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      // Handle 400 Bad Request - Invalid OTP
      if (e.response?.statusCode == 400) {
        final message = e.response?.data?['message'] ?? 'Invalid OTP';
        return {
          'success': false,
          'message': message,
          'code': 'INVALID_OTP',
        };
      }
      // Handle 403 Forbidden - Not authorized
      if (e.response?.statusCode == 403) {
        return {
          'success': false,
          'message': e.response?.data?['message'] ?? 'Not authorized to start this ride',
          'code': 'FORBIDDEN',
        };
      }
      // Handle 404 Not Found - Ride not found
      if (e.response?.statusCode == 404) {
        return {
          'success': false,
          'message': 'Ride not found',
          'code': 'NOT_FOUND',
        };
      }
      rethrow;
    }
  }

  /// Assign driver to ride (admin/system use).
  /// Backend: POST /api/rides/:id/assign-driver  body: { driverId }
  Future<Map<String, dynamic>> assignDriverToRide(String rideId, String driverId) async {
    final response = await _dio.post('/rides/$rideId/assign-driver', data: {
      'driverId': driverId,
    });
    return response.data as Map<String, dynamic>;
  }
  
  /// Driver accepts a ride (driver self-accept).
  /// Backend: POST /api/rides/:id/accept
  /// Returns: { success, data: { ride } } or 409 if already taken
  Future<Map<String, dynamic>> acceptRide(String rideId) async {
    try {
      final response = await _dio.post('/rides/$rideId/accept');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      // Handle 409 Conflict - ride already taken
      if (e.response?.statusCode == 409) {
        return {
          'success': false,
          'message': 'This ride has already been accepted by another driver',
          'code': 'RIDE_ALREADY_TAKEN',
        };
      }
      // Handle 403 Forbidden - not a driver or not authorized
      if (e.response?.statusCode == 403) {
        final message = e.response?.data?['message']?.toString() ?? 'You are not authorized to accept this ride';
        return {
          'success': false,
          'message': message,
          'code': 'FORBIDDEN',
        };
      }
      rethrow;
    }
  }

  /// Cancel a ride.
  /// Backend: POST /api/rides/:id/cancel  body: { reason? }
  Future<Map<String, dynamic>> cancelRide(String rideId, {String? reason}) async {
    final response = await _dio.post('/rides/$rideId/cancel', data: {
      if (reason != null) 'reason': reason,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Submit ride rating.
  /// Backend: POST /api/rides/:id/rating  body: { rating, feedback? }
  Future<void> submitRideRating(String rideId, double rating, {String? feedback}) async {
    await _dio.post('/rides/$rideId/rating', data: {
      'rating': rating,
      if (feedback != null && feedback.isNotEmpty) 'feedback': feedback,
    });
  }

  /// Get ride receipt.
  /// Backend: GET /api/rides/:id/receipt
  Future<Map<String, dynamic>> getRideReceipt(String rideId) async {
    final response = await _dio.get('/rides/$rideId/receipt');
    return response.data as Map<String, dynamic>;
  }

  /// Update driver location for active ride (tracking).
  /// Backend: POST /api/rides/:id/track  body: { lat, lng, heading?, speed? }
  Future<void> updateRideTracking(String rideId, double lat, double lng, {double? heading, double? speed}) async {
    await _dio.post('/rides/$rideId/track', data: {
      'lat': lat,
      'lng': lng,
      if (heading != null) 'heading': heading,
      if (speed != null) 'speed': speed,
    });
  }

  /// Get chat messages for a ride.
  /// Backend: GET /api/rides/:id/messages
  Future<List<Map<String, dynamic>>> getChatMessages(String rideId) async {
    try {
      final response = await _dio.get('/rides/$rideId/messages');
      final data = response.data as Map<String, dynamic>;
      final innerData = data['data'];

      List<dynamic> rawMessages = const [];
      if (innerData is Map<String, dynamic> && innerData['messages'] is List) {
        rawMessages = innerData['messages'] as List<dynamic>;
      } else if (data['messages'] is List) {
        rawMessages = data['messages'] as List<dynamic>;
      } else if (innerData is List) {
        rawMessages = innerData;
      }

      return rawMessages.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    } catch (e) {
      debugPrint('Error fetching chat messages: $e');
      return [];
    }
  }

  /// Send a chat message.
  /// Backend: POST /api/rides/:id/messages  body: { message }
  Future<Map<String, dynamic>?> sendChatMessage(String rideId, String message, {String? clientMessageId}) async {
    try {
      final response = await _dio.post('/rides/$rideId/messages', data: {
        'message': message,
        if (clientMessageId != null && clientMessageId.isNotEmpty) 'clientMessageId': clientMessageId,
      });
      final data = response.data as Map<String, dynamic>;
      final innerData = data['data'];
      if (innerData is Map<String, dynamic>) {
        final msg = innerData['message'];
        if (msg is Map) return Map<String, dynamic>.from(msg);
      }
      if (data['message'] is Map) return Map<String, dynamic>.from(data['message'] as Map);
      if (innerData is Map && innerData['id'] != null) {
        return Map<String, dynamic>.from(innerData as Map);
      }
      return null;
    } catch (e) {
      debugPrint('Error sending chat message: $e');
      return null;
    }
  }

  /// Mark all ride chat messages as read for the current user.
  Future<Map<String, dynamic>> markRideMessagesRead(String rideId) async {
    final response = await _dio.post('/rides/$rideId/messages/read');
    return response.data as Map<String, dynamic>;
  }

  /// Get unread message count for a ride conversation.
  Future<int> getRideUnreadCount(String rideId) async {
    final response = await _dio.get('/rides/$rideId/messages/unread-count');
    final data = response.data as Map<String, dynamic>;
    final inner = data['data'] as Map<String, dynamic>? ?? const {};
    return (inner['unreadCount'] as num?)?.toInt() ?? 0;
  }

  // ─────────────────────────────────────────────
  // PRICING  (Backend: pricing-service via gateway /api/pricing/*)
  // ─────────────────────────────────────────────

  /// Calculate fare estimate.
  /// Backend: POST /api/pricing/calculate  body: { pickupLat, pickupLng, dropLat, dropLng, waypoints?, distanceKm?, durationMin?, vehicleType?, scheduledTime? }
  /// waypoints: optional list of {lat, lng} for multi-stop trips (Ola/Uber/Rapido style)
  Future<Map<String, dynamic>> getRidePricing({
    required double pickupLat,
    required double pickupLng,
    required double dropLat,
    required double dropLng,
    List<Map<String, double>>? waypoints,
    double? distanceKm,
    int? durationMin,
    String? vehicleType,
    String? scheduledTime,
  }) async {
    final data = <String, dynamic>{
      'pickupLat': pickupLat,
      'pickupLng': pickupLng,
      'dropLat': dropLat,
      'dropLng': dropLng,
      if (vehicleType != null) 'vehicleType': vehicleType,
      if (scheduledTime != null) 'scheduledTime': scheduledTime,
    };
    if (waypoints != null && waypoints.isNotEmpty) {
      data['waypoints'] = waypoints;
    }
    if (distanceKm != null) data['distanceKm'] = distanceKm;
    if (durationMin != null) data['durationMin'] = durationMin;
    final response = await _dio.post('/pricing/calculate', data: data);
    return response.data as Map<String, dynamic>;
  }

  /// Get nearby drivers.
  /// Backend: GET /api/pricing/nearby-drivers?lat=&lng=&radius=
  Future<Map<String, dynamic>> getNearbyDrivers(double lat, double lng, {double radius = 5}) async {
    final response = await _dio.get('/pricing/nearby-drivers', queryParameters: {
      'lat': lat,
      'lng': lng,
      'radius': radius,
    });
    return response.data as Map<String, dynamic>;
  }

  // ─────────────────────────────────────────────
  // DRIVER  (Backend: driver-service via gateway /api/driver/*)
  // ─────────────────────────────────────────────

  /// Get driver profile (authenticated).
  /// Backend: GET /api/driver/profile
  Future<Map<String, dynamic>> getDriverProfile() async {
    final response = await _dio.get('/driver/profile');
    return response.data as Map<String, dynamic>;
  }

  /// Update driver online/offline status.
  /// Backend: PATCH /api/driver/status  body: { online: bool, location?: { latitude, longitude } }
  Future<Map<String, dynamic>> updateDriverStatus(bool online, {double? lat, double? lng}) async {
    final response = await _dio.patch('/driver/status', data: {
      'online': online,
      if (lat != null && lng != null) 'location': {
        'latitude': lat,
        'longitude': lng,
      },
    });
    return response.data as Map<String, dynamic>;
  }

  /// Get driver earnings.
  /// Backend: GET /api/driver/earnings
  Future<Map<String, dynamic>> getDriverEarnings() async {
    final response = await _dio.get('/driver/earnings');
    return response.data as Map<String, dynamic>;
  }

  /// Get driver trip history.
  /// Backend: GET /api/driver/trips?page=&limit=
  Future<Map<String, dynamic>> getDriverTrips({int page = 1, int limit = 10}) async {
    final response = await _dio.get('/driver/trips', queryParameters: {
      'page': page,
      'limit': limit,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Start driver onboarding.
  /// Backend: POST /api/driver/onboarding/start
  Future<Map<String, dynamic>> startDriverOnboarding() async {
    final response = await _dio.post('/driver/onboarding/start');
    return response.data as Map<String, dynamic>;
  }

  /// Get driver onboarding status (single source of truth for verification).
  /// Backend: GET /api/driver/onboarding/status
  /// Returns: { success, data: { onboarding_status, can_start_rides, message? } }
  Future<Map<String, dynamic>> getDriverOnboardingStatus() async {
    final response = await _dio.get('/driver/onboarding/status');
    return response.data as Map<String, dynamic>;
  }

  /// Upload a single driver document.
  /// Backend: POST /api/driver/onboarding/document/upload?documentType=TYPE  (multipart)
  /// documentType must be: LICENSE, RC, INSURANCE, PAN_CARD, AADHAAR_CARD, PROFILE_PHOTO
  Future<Map<String, dynamic>> uploadDriverDocument({
    required String documentType,
    required String filePath,
    String? documentNumber,
    bool isFront = true,
  }) async {
    try {
      // Map frontend document types to backend expected types
      final backendDocType = _mapDocumentType(documentType);
      
      final formData = FormData.fromMap({
        // Backend expects 'document' as the file field name
        'document': await MultipartFile.fromFile(
          filePath, 
          filename: '${backendDocType.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ),
      });
      // documentType goes as query parameter, not in form body
      final response = await _dio.post(
        '/driver/onboarding/document/upload',
        queryParameters: {'documentType': backendDocType},
        data: formData,
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final responseData = e.response?.data;
      String errorMsg = 'Upload failed';
      
      if (responseData is Map && responseData['message'] != null) {
        errorMsg = responseData['message'];
      } else if (statusCode == 401) {
        if (_authToken == 'dev_mock_token_123456') {
          errorMsg = 'You\'re logged in with dev bypass (OTP 123456). Document upload needs a real login. Log out and sign in with a real OTP, or ask backend to accept 123456.';
        } else {
          errorMsg = 'Session expired. Please login again.';
        }
      } else if (statusCode == 400) {
        errorMsg = 'Invalid document format or missing data.';
      } else if (statusCode == 502 || statusCode == 503) {
        errorMsg = 'Server is temporarily unavailable. Please try again later.';
      } else if (e.type == DioExceptionType.connectionTimeout || 
                 e.type == DioExceptionType.receiveTimeout) {
        errorMsg = 'Connection timed out. Check your internet connection.';
      } else if (e.type == DioExceptionType.connectionError) {
        errorMsg = 'Cannot connect to server. Check your internet.';
      }
      
      throw Exception(errorMsg);
    }
  }
  
  /// Map frontend document type names to backend expected values
  String _mapDocumentType(String frontendType) {
    switch (frontendType.toLowerCase()) {
      case 'driving_license':
      case 'license':
        return 'LICENSE';
      case 'vehicle_rc':
      case 'rc':
        return 'RC';
      case 'vehicle_insurance':
      case 'insurance':
        return 'INSURANCE';
      case 'aadhaar':
      case 'aadhaar_card':
        return 'AADHAAR_CARD';
      case 'pan':
      case 'pan_card':
        return 'PAN_CARD';
      case 'profile_photo':
      case 'photo':
        return 'PROFILE_PHOTO';
      default:
        return frontendType.toUpperCase();
    }
  }
  
  /// Update driver email.
  /// Backend: PUT /api/driver/onboarding/email
  Future<Map<String, dynamic>> updateDriverEmail(String email) async {
    final response = await _dio.put('/driver/onboarding/email', data: {
      'email': email,
    });
    return response.data as Map<String, dynamic>;
  }
  
  /// Update driver language preference.
  /// Backend: PUT /api/driver/onboarding/language
  Future<Map<String, dynamic>> updateDriverLanguage(String language) async {
    final response = await _dio.put('/driver/onboarding/language', data: {
      'language': language,
    });
    return response.data as Map<String, dynamic>;
  }
  
  /// Update driver vehicle information.
  /// Backend: PUT /api/driver/onboarding/vehicle
  Future<Map<String, dynamic>> updateDriverVehicle({
    required String vehicleType,
    List<String>? serviceTypes,
  }) async {
    final response = await _dio.put('/driver/onboarding/vehicle', data: {
      'vehicleType': vehicleType,
      if (serviceTypes != null) 'serviceTypes': serviceTypes,
    });
    return response.data as Map<String, dynamic>;
  }
  
  /// Update driver personal information.
  /// Backend: PUT /api/driver/onboarding/personal-info
  Future<Map<String, dynamic>> updateDriverPersonalInfo({
    String? fullName,
    String? email,
    String? aadhaarNumber,
    String? panNumber,
    String? vehicleNumber,
    String? vehicleModel,
  }) async {
    final response = await _dio.put('/driver/onboarding/personal-info', data: {
      if (fullName != null) 'fullName': fullName,
      if (email != null) 'email': email,
      if (aadhaarNumber != null) 'aadhaarNumber': aadhaarNumber,
      if (panNumber != null) 'panNumber': panNumber,
      // Backend canonical key for registration number.
      if (vehicleNumber != null) 'vehicleRegistrationNumber': vehicleNumber,
      // Backward-compat key for older deployments.
      if (vehicleNumber != null) 'vehicleNumber': vehicleNumber,
      if (vehicleModel != null) 'vehicleModel': vehicleModel,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Submit all uploaded documents for verification.
  /// Backend: POST /api/driver/onboarding/documents/submit
  Future<Map<String, dynamic>> submitDriverDocuments() async {
    final response = await _dio.post('/driver/onboarding/documents/submit');
    return response.data as Map<String, dynamic>;
  }

  /// Submit driver support request.
  /// Backend: POST /api/driver/support  body: { issue_type, description, priority? }
  Future<Map<String, dynamic>> submitDriverSupport({
    required String issueType,
    required String description,
    String priority = 'medium',
  }) async {
    final response = await _dio.post('/driver/support', data: {
      'issue_type': issueType,
      'description': description,
      'priority': priority,
    });
    return response.data as Map<String, dynamic>;
  }

  // ─────────────────────────────────────────────
  // REALTIME  (Backend: realtime-service via gateway /api/realtime/*)
  // ─────────────────────────────────────────────

  /// Get real-time stats (online drivers, active rides, etc.)
  /// Backend: GET /api/realtime/stats
  Future<Map<String, dynamic>> getRealtimeStats() async {
    final response = await _dio.get('/realtime/stats');
    return response.data as Map<String, dynamic>;
  }

  /// Update driver location via REST (fallback when socket is down).
  /// Backend: POST /api/realtime/update-driver-location
  Future<void> updateDriverLocation(String driverId, double lat, double lng, {double? heading, double? speed}) async {
    await _dio.post('/realtime/update-driver-location', data: {
      'driverId': driverId,
      'lat': lat,
      'lng': lng,
      if (heading != null) 'heading': heading,
      if (speed != null) 'speed': speed,
    });
  }

  // ─────────────────────────────────────────────
  // NOTIFICATIONS  (Backend: notification-service via gateway /api/notifications/*)
  // ─────────────────────────────────────────────

  /// Get notifications for current user.
  /// Backend: GET /api/notifications
  Future<Map<String, dynamic>> getNotifications() async {
    final response = await _dio.get('/notifications');
    return response.data as Map<String, dynamic>;
  }

  // ─────────────────────────────────────────────
  // DRIVER WALLET & PAYOUTS
  // ─────────────────────────────────────────────

  /// Get driver wallet balance and details.
  /// Backend: GET /api/driver/wallet
  Future<Map<String, dynamic>> getDriverWallet() async {
    final response = await _dio.get('/driver/wallet');
    return response.data as Map<String, dynamic>;
  }

  /// Get driver payout accounts (bank/UPI).
  /// Backend: GET /api/driver/payout-accounts
  Future<Map<String, dynamic>> getPayoutAccounts() async {
    final response = await _dio.get('/driver/payout-accounts');
    return response.data as Map<String, dynamic>;
  }

  /// Add a new payout account.
  /// Backend: POST /api/driver/payout-accounts
  Future<Map<String, dynamic>> addPayoutAccount({
    required String accountType, // 'BANK_ACCOUNT' or 'UPI'
    String? bankName,
    String? accountNumber,
    String? ifscCode,
    String? accountHolderName,
    String? upiId,
  }) async {
    final response = await _dio.post('/driver/payout-accounts', data: {
      'accountType': accountType,
      if (bankName != null) 'bankName': bankName,
      if (accountNumber != null) 'accountNumber': accountNumber,
      if (ifscCode != null) 'ifscCode': ifscCode,
      if (accountHolderName != null) 'accountHolderName': accountHolderName,
      if (upiId != null) 'upiId': upiId,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Set a payout account as primary.
  /// Backend: PUT /api/driver/payout-accounts/:id/primary
  Future<Map<String, dynamic>> setPrimaryPayoutAccount(String accountId) async {
    final response = await _dio.put('/driver/payout-accounts/$accountId/primary');
    return response.data as Map<String, dynamic>;
  }

  /// Delete a payout account.
  /// Backend: DELETE /api/driver/payout-accounts/:id
  Future<Map<String, dynamic>> deletePayoutAccount(String accountId) async {
    final response = await _dio.delete('/driver/payout-accounts/$accountId');
    return response.data as Map<String, dynamic>;
  }

  /// Request a withdrawal from wallet.
  /// Backend: POST /api/driver/wallet/withdraw
  Future<Map<String, dynamic>> requestWithdrawal({
    required double amount,
    String? payoutAccountId,
  }) async {
    final response = await _dio.post('/driver/wallet/withdraw', data: {
      'amount': amount,
      if (payoutAccountId != null) 'payoutAccountId': payoutAccountId,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Get wallet transaction history.
  /// Backend: GET /api/driver/wallet/transactions
  Future<Map<String, dynamic>> getWalletTransactions({int page = 1, int limit = 20}) async {
    final response = await _dio.get('/driver/wallet/transactions', queryParameters: {
      'page': page,
      'limit': limit,
    });
    return response.data as Map<String, dynamic>;
  }

  /// Get payout history.
  /// Backend: GET /api/driver/wallet/payouts
  Future<Map<String, dynamic>> getPayoutHistory({int page = 1, int limit = 20}) async {
    final response = await _dio.get('/driver/wallet/payouts', queryParameters: {
      'page': page,
      'limit': limit,
    });
    return response.data as Map<String, dynamic>;
  }
}

// Singleton instance
final apiClient = ApiClient();

// Provider for dependency injection
final apiClientProvider = Provider<ApiClient>((ref) => apiClient);
