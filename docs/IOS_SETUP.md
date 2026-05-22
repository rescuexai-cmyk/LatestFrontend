# iOS Setup Guide

This guide covers setting up both the **Flutter frontend** and **backend** for iOS.

---

## Frontend (Flutter)

### Prerequisites

1. **macOS** with Xcode installed
2. **Xcode** (full installation from App Store or developer.apple.com)
3. **CocoaPods** (`sudo gem install cocoapods`)
4. **Flutter** SDK with iOS enabled

### Initial Setup (Already Done)

- ✅ iOS project regenerated (`ios/Runner.xcodeproj`, `Podfile`)
- ✅ App Transport Security (ATS) for HTTP backend (139.59.34.68, localhost)
- ✅ Google Maps API key in `AppDelegate.swift`
- ✅ Location and background mode permissions in `Info.plist`
- ✅ Firebase (`GoogleService-Info.plist`)

### Complete Xcode Setup

If you see "Application not configured for iOS" or "Xcode installation is incomplete":

```bash
# Point to Xcode
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

# First launch
sudo xcodebuild -runFirstLaunch

# Accept license if prompted
sudo xcodebuild -license accept

# Install iOS platform
xcodebuild -downloadPlatform iOS
```

### Build & Run

```bash
# Without device/simulator (no codesign)
flutter build ios --no-codesign

# Run on simulator
flutter run -d ios

# Run on physical device (requires Apple Developer account)
flutter run -d <device-id>
```

### Google Maps

- The default API key in `AppDelegate.swift` matches `lib/core/config/app_config.dart`
- For production: create an iOS-specific key in [Google Cloud Console](https://console.cloud.google.com/) → APIs → Maps SDK for iOS
- Replace the key in both `AppDelegate.swift` and `app_config.dart` (or use `--dart-define` for builds)

### Firebase

- `ios/Runner/GoogleService-Info.plist` must match your Firebase iOS app
- Add an iOS app in Firebase Console if needed and download the plist

---

## Backend (For iOS Clients)

The backend is **shared** for Android and iOS. For iOS to work:

### 1. HTTPS (Recommended)

- iOS **App Transport Security** requires HTTPS by default
- This project has ATS exceptions for HTTP (139.59.34.68, localhost) for dev/staging
- **Production**: Use HTTPS and remove HTTP exceptions from `ios/Runner/Info.plist`

### 2. CORS

- If the backend serves web clients, ensure CORS allows your domains
- Native iOS (Dio, Socket.io) does **not** use CORS—only browser-based requests do

### 3. WebSocket / Socket.io

- The app uses `http://` for Socket.io (socket_io_client uses HTTP transport)
- Backend must accept connections on the configured port (e.g. 5007)
- Ensure firewall/proxy allows iOS clients

### 4. Push Notifications (FCM)

- Backend uses FCM for push; iOS needs an APNs key/cert in Firebase
- In Firebase Console → Project Settings → Cloud Messaging → Apple app configuration

### 5. No iOS-Specific APIs

- Same REST API (`/api/rides`, `/api/auth`, etc.) for both platforms
- Same WebSocket events (`ride_message`, `chat_history`, etc.)

---

## Checklist

| Item | Status |
|------|--------|
| Xcode installed & configured | Run `flutter doctor -v` to verify |
| CocoaPods | `pod --version` |
| `flutter build ios --no-codesign` | Should succeed |
| Backend reachable (HTTP or HTTPS) | Test from Settings → Server Config |
| Google Maps key for iOS | Optional: separate key in Cloud Console |
| Firebase iOS app & plist | Match `GoogleService-Info.plist` |
