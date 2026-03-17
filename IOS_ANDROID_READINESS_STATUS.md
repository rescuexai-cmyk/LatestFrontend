# Raahi App – iOS & Android Readiness Status

## Architecture Overview

| Layer | Technology |
|-------|------------|
| **Frontend** | Flutter (SDK ≥3.0), Riverpod, go_router |
| **Backend** | REST API + Socket.io + SSE |
| **Auth** | Firebase Phone Auth → Backend JWT |
| **Maps** | Google Maps, Places API |
| **Push** | Firebase Cloud Messaging + flutter_local_notifications |

### Backend Integration
- **API Base:** `http://139.59.34.68/api` (configurable via Server Config screen)
- **Realtime:** Socket.io at `http://139.59.34.68/realtime`
- **Health Check:** `/health` and `/api/auth/me` fallback

---

## iOS Status

### ✅ Configured
| Item | Status |
|------|--------|
| Firebase | `GoogleService-Info.plist` with bundle ID `com.rhi.raahi` |
| Google Maps | `GMSServices.provideAPIKey` in AppDelegate, embedded views enabled |
| Location | `NSLocationWhenInUse`, `NSLocationAlwaysAndWhenInUse`, `NSLocationAlways` |
| Background Modes | fetch, location, remote-notification |
| App Transport Security | Allows HTTP for backend (139.59.34.68, localhost) |
| Camera & Photo | **Added** – `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` |
| Display Name | **Updated** – `Raahi` (was RideApp) |

### ⚠️ Manual Steps Required (Xcode)
| Item | Action |
|------|--------|
| **Push Notifications** | In Xcode: Runner target → Signing & Capabilities → Add "Push Notifications" |
| **Provisioning** | Ensure bundle ID `com.rhi.raahi` is registered in Apple Developer Portal |
| **APNs** | Upload APNs key to Firebase Console for push notifications |

### Known iOS Issues (Blank Screen)
- **Possible causes:** Init blocking (push permission, server health check), provider crash, or rendering issue
- **Debug:** Run `flutter run -d iphone` and watch terminal for `debugPrint` output
- **Workaround:** See `BLANK_SCREEN_TROUBLESHOOTING.md`

---

## Android Status

### ✅ Configured
| Item | Status |
|------|--------|
| Firebase | `google-services.json`, bundle ID `com.rhi.raahi` |
| Google Maps | API key in manifest |
| Permissions | Internet, location, background location, vibrate, POST_NOTIFICATIONS |
| Cleartext | `usesCleartextTraffic="true"` for HTTP backend |
| Build | multiDex, core library desugaring |

### ⚠️ Notes
- Maps API key is in manifest; can override via `--dart-define` in build.gradle if needed

---

## App Startup Flow

```
main()
├── WidgetsFlutterBinding.ensureInitialized()
├── Firebase.initializeApp()          ← Must complete first
├── runApp(_AppInitializer)

_AppInitializer._initialize()
├── FirebaseMessaging.onBackgroundMessage()
├── pushNotificationService.initialize()   ← Can block on iOS permission dialog
├── ServerConfigService.init()             ← HTTP health check (up to ~6s if unreachable)
├── SystemChrome.setPreferredOrientations()
└── setState(_ready = true)

→ RideHailingApp
   ├── !ServerConfigService.isHealthy → _ConnectionErrorScreen
   └── GoRouter (login / services / driver / etc.)
```

---

## Backend API Endpoints (Summary)

| Category | Endpoints |
|----------|-----------|
| Auth | `/auth/send-otp`, `verify-otp`, `me`, `logout`, `refresh` |
| Rides | `/rides`, `/rides/:id`, `accept`, `cancel`, `rating`, `track` |
| Driver | `/driver/profile`, `earnings`, `trips`, `wallet`, onboarding |
| Realtime | Socket.io events, SSE for ride/driver updates |
| Notifications | `POST /notifications/device`, `DELETE /notifications/device` |

---

## Fixes Applied in This Session

1. **iOS Info.plist**
   - Added `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` (prevents crash when driver uses image picker)
   - Updated `CFBundleDisplayName` and `CFBundleName` to `Raahi`

2. **Firebase initialization**
   - `Firebase.initializeApp()` moved to start of `main()` before `runApp()`
   - Lazy getters for `FirebaseMessaging` and `FirebaseAuth` in services

3. **Push notifications**
   - `criticalAlert: false` to avoid iOS crash without entitlement

4. **Firebase config**
   - Bundle ID aligned to `com.rhi.raahi` with `GoogleService-Info.plist`

---

## Checklist Before Release

- [ ] Add Push Notifications capability in Xcode
- [ ] Upload APNs key to Firebase Console
- [ ] Test on physical iPhone (release build)
- [ ] Verify backend `139.59.34.68` is reachable from device network
- [ ] Enable Firebase App Check for production (currently disabled)
- [ ] Consider HTTPS for production API
