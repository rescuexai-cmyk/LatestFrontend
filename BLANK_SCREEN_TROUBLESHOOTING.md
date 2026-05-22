# Blank White Screen on iOS – Troubleshooting Guide

## Potential Causes

### 1. **App stuck during initialization**
`_initialize()` runs these in sequence:
- `pushNotificationService.initialize()` – can block on iOS permission dialog
- `ServerConfigService.init()` – HTTP health check to `139.59.34.68` (up to ~6 seconds if unreachable)

If either hangs or takes too long, you stay on the splash screen.

### 2. **Firebase initialization failure**
If `Firebase.initializeApp()` in `main()` fails, the app may crash before showing anything.

### 3. **Provider/Router crash**
When `RideHailingApp` loads, it uses `appRouterProvider` and `authStateProvider`. If `AuthNotifier` or `SettingsNotifier` throws (e.g. `SharedPreferences`, `FlutterSecureStorage` on iOS), the app can crash or show a blank screen.

### 4. **Asset loading failure**
`LoginScreen` uses `Image.asset('assets/images/raahi_logo.png')` and `mandala_art.png`. Missing or invalid assets can cause build errors or blank screens.

### 5. **iOS-specific rendering**
On some iOS versions, the first Flutter frame may not render correctly, or the app may be killed before the UI appears.

---

## Manual Resolution Steps

### Step 1: Run in debug mode to see logs

```bash
cd /Users/sarthakmishra/Downloads/raahi-flutter-app
flutter run -d iphone
```

Keep the iPhone connected and watch the terminal. Look for:
- `❌ App init error:` – initialization failure
- `Failed to find snapshot` – build/engine issue
- `Firebase has not been correctly initialized`
- Any stack trace or exception

### Step 2: Bypass slow initialization (temporary test)

Edit `lib/main.dart` and temporarily skip the slow parts in `_initialize()`:

```dart
Future<void> _initialize() async {
  try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    
    // TEMPORARILY SKIP - uncomment to test
    // await pushNotificationService.initialize();
    // await ServerConfigService.init();
    
    await SystemChrome.setPreferredOrientations([...]);

    if (mounted) setState(() => _ready = true);
  } catch (e, stack) { ... }
}
```

Rebuild and run. If the app loads, the issue is in push notifications or server config.

### Step 3: Add timeout to server config

`ServerConfigService.init()` can block for several seconds. Add a timeout in `lib/core/services/server_config_service.dart`:

In `_checkHealth()`, the `HttpClient` already has `connectionTimeout` and `request.close().timeout()`. If the server is unreachable, it should fail within ~3–6 seconds. Ensure your iPhone has network access (Wi‑Fi or cellular).

### Step 4: Check Firebase configuration

1. Open [Firebase Console](https://console.firebase.google.com)
2. Select project `raahi-5f22e`
3. Project Settings → Your apps
4. Confirm iOS app with bundle ID `com.rhi.raahi` exists
5. Download a fresh `GoogleService-Info.plist` and replace `ios/Runner/GoogleService-Info.plist`

### Step 5: Verify iOS capabilities

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select Runner target → Signing & Capabilities
3. Ensure:
   - Push Notifications
   - Background Modes (Remote notifications, Background fetch)
4. Check that the bundle ID is `com.rhi.raahi`

### Step 6: Clean rebuild

```bash
cd /Users/sarthakmishra/Downloads/raahi-flutter-app
flutter clean
rm -rf ios/Pods ios/Podfile.lock ios/.symlinks
flutter pub get
cd ios && pod install && cd ..
flutter build ios --release
flutter install -d iphone
```

### Step 7: Simplify main to isolate the problem

Temporarily replace the app with a minimal test:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.orange,
        body: Center(child: Text('TEST OK', style: TextStyle(fontSize: 24))),
      ),
    ),
  );
}
```

If this shows "TEST OK", the problem is in `_AppInitializer` or `RideHailingApp`. If it still shows blank, the issue is earlier (Firebase, engine, or iOS setup).

### Step 8: Check Info.plist for ATS

In `ios/Runner/Info.plist`, ensure `NSAppTransportSecurity` allows your API host (e.g. `139.59.34.68`) if you use HTTP.

---

## Quick diagnostic checklist

- [ ] Run `flutter run -d iphone` and capture any errors in the terminal
- [ ] iPhone has internet (Wi‑Fi or cellular)
- [ ] `GoogleService-Info.plist` is in `ios/Runner/` and has correct bundle ID
- [ ] Push Notifications capability enabled in Xcode
- [ ] Try Step 2 (skip push + server init) to see if app loads
- [ ] Try Step 7 (minimal app) to see if Flutter renders at all
