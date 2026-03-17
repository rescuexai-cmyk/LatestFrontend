# Raahi Ride-Hailing App — Complete Feature Documentation

**Version:** 1.0.0  
**Platform:** Flutter (iOS & Android)  
**Last Updated:** March 2025

---

## Table of Contents

1. [Authentication](#1-authentication)
2. [Home & Navigation](#2-home--navigation)
3. [Ride Booking (Rider)](#3-ride-booking-rider)
4. [Driver Features](#4-driver-features)
5. [Profile & Account](#5-profile--account)
6. [Ride History](#6-ride-history)
7. [Settings & Configuration](#7-settings--configuration)
8. [Real-Time & Integrations](#8-real-time--integrations)
9. [Push Notifications](#9-push-notifications)
10. [Localization & Theming](#10-localization--theming)
11. [Technical Integrations](#11-technical-integrations)
12. [App Routes Reference](#12-app-routes-reference)

---

## 1. Authentication

### 1.1 Login Screen
- **Phone OTP Login** — Primary login method
- **Truecaller OTP** — Coming soon
- **Google Sign-In** — Coming soon
- Indian phone number format (+91, 10 digits, 6–9 prefix validation)
- Navigate to signup for new users

### 1.2 Signup Screen
- Phone number input with country code (+91)
- OTP request via backend API
- Validation for Indian mobile numbers

### 1.3 OTP Verification
- 6-digit OTP input
- Auto-verify on completion
- Resend OTP with 30-second cooldown
- Dev mode: Static OTP `123456` when backend is unreachable

### 1.4 New User Onboarding
- **Name Entry** — First name and last name (letters only)
- **Terms Screen** — Terms of service acceptance before app access

### 1.5 Auth Provider & Session
- JWT access token + refresh token
- Secure token storage (Flutter Secure Storage)
- Automatic token refresh on 401
- Auto-logout on 403 or deactivated user
- Mock session when backend is down (development)
- Socket.io connection after successful login
- FCM token registration after login

### 1.6 Multi-Account Support
- **Switch Account** — Up to 2 saved accounts
- Switch between accounts without re-login
- Saved accounts stored securely

---

## 2. Home & Navigation

### 2.1 Home Screen
- Raahi logo and mandala-style background
- **Find a Ride Now!** — Navigate to Services
- **Open Drivers' App** — Navigate to Driver onboarding/home
- **Switch Account?** — Quick access to account switcher
- User avatar with name display
- **Active Ride Banner** — Persistent banner at bottom when ride is in progress

### 2.2 Services Screen
- **Pickup Location** — Current location (Geolocator + geocoding) or manual search
- **Home Address** — Set and save home address
- **Recent Locations** — Last used destinations
- **Schedule Ride** — Now or schedule for later (date + time, minimum 15 minutes ahead)
- **Vehicle Types** — Cab Mini, Auto, Cab XL, Rescue, Premium, Driver Rental
- **Action Cards** — Get Rescued, Hire a Driver, Plan a Trip
- **Places Near You** — Nearby places via Google Places API
- **30% Cashback** promo banner
- Pull-to-refresh for location and places

---

## 3. Ride Booking (Rider)

### 3.1 Find Trip Screen
- Address search for pickup and destination
- Interactive map with markers and route polyline
- Fare estimate display
- Vehicle type selection
- Optional waypoints
- Auto-open search via query parameter
- Map with pickup/drop markers and route visualization

### 3.2 Payment Screen
- **Payment Methods:**
  - Cash
  - Raahi Wallet
  - UPI (Paytm, GPay, PhonePe, BHIM)
  - Scan to Pay
  - Credit/Debit Card
  - Net Banking
- **Vouchers** — FIRST50, RAAHI20, WELCOME10
- **Linked UPI** — Add UPI ID, link, remove
- **Ride PIN** — 4-digit OTP from backend for driver verification
- **Intercity** — Blocked for rides > 50 km (coming soon)
- Create ride via POST `/api/rides` with pickup, drop, payment, vehicle type

### 3.3 Searching Drivers Screen
- Map with pickup marker and search radius
- Pulse animation while searching for drivers
- **Real-time** — SSE + Socket.io for driver assignment
- **Fallback** — Poll every 10 seconds if real-time fails
- Cancel search (API + realtime cancel)
- Auto-navigate to Driver Assigned when driver found

### 3.4 Driver Assigned Screen
- **Phases:** Driver en route → Ride in progress → Completed
- **OTP PIN** — 4-digit PIN from backend (Uber-style verification)
- **Map** — Driver → pickup → destination polylines
- **Driver Info** — Name, vehicle, rating, call button
- **Chat** — Rider–driver chat (REST + WebSocket)
- **Actions:** Call, Chat, Safety, Share trip, Cancel (before ride start)
- **Rating** — 5-star + feedback after completion
- **Driver Cancel** — Auto re-search for new driver

### 3.5 Ride Tracking Screen
- Full-screen map with route polyline
- **Vehicle icon** — Uber/Rapido-style cab icon for driver
- **Camera follow** — Map follows driver location in real time
- Driver location updates via SSE
- Status chip (Finding driver, Driver on the way, etc.)
- Call / Message buttons
- Cancel (before ride start)
- Rating bottom sheet on completion

### 3.6 Ride Details Screen
- Status banner
- Pickup and drop addresses
- Trip details (vehicle, distance, duration, payment)
- **Fare Breakdown** — Base, distance, time, surge, tolls, GST, etc.
- Driver info (if available)
- Rate ride (if completed)
- Get Help, Receipt (share)

---

## 4. Driver Features

### 4.1 Driver Onboarding (5 Steps)
1. **Language + Email** — Email, language selection (English, Hindi, Punjabi, Tamil, Telugu, Bengali, Marathi, Gujarati)
2. **Vehicle Type** — Auto, Commercial Car, Motorbike; region (Delhi NCR); referral code
3. **Personal Info** — Full name, vehicle registration (Indian format), Aadhaar
4. **Documents** — Driving License, RC, Insurance, PAN, Aadhaar, Profile Photo (camera/gallery)
5. **Verification** — Submit for verification, progress bar, poll status

### 4.2 Driver Welcome Screen
- Verification progress display
- Document status (verified, rejected, under review)
- Re-upload rejected documents
- **Start Driving** — When verified

### 4.3 Driver Home Screen
- **Go Online/Offline** — Toggle driver availability
- **Real-time Ride Offers** — SSE + Socket.io for new ride requests
- **Ride Offer Cards** — Pickup, drop, fare, ETA, countdown timer
- Accept/Decline ride offers
- Earnings badge
- Navigate to active ride
- Session persistence (24-hour session, platform fee)
- Verification status banner

### 4.4 Driver Active Ride Screen
- **Map Features:**
  - Route polyline (pickup → drop)
  - **Vehicle icon** — Cab icon that follows GPS
  - **Camera follow** — Map follows vehicle with bearing and tilt
  - Follow/recenter button
- **OTP Verification** — 4-digit OTP from rider, backend validation
- **Phases:** En route to pickup → Pickup confirmed → Navigate to drop → Complete
- **Navigation** — Open Google Maps for turn-by-turn
- **Chat** — Rider–driver chat
- **Cash Payment** — QR for UPI, tolls/parking/extra stops input
- **Complete Ride** — Fare adjustments, backend completion
- **Earnings** — Today's earnings from API
- **Location Stream** — Continuous GPS updates to backend for rider tracking

---

## 5. Profile & Account

### 5.1 Profile Screen
- Avatar, name, email, phone
- **Stats** — Total rides, rating, saved places
- **Saved Places** — Home, Work, favorites
- **Notifications** — Toggle on/off
- **Promotions** — Toggle on/off
- **Help & Support** — Call, email, message
- **About** — App information
- **Logout**
- **Server Configuration** link (for dev/staging)

### 5.2 Saved Places
- Add new place (search or map picker)
- Save as Home, Work, or Other
- Delete saved places
- Sync with saved locations provider

---

## 6. Ride History

### 6.1 History Screen
- Ride list (newest first)
- **Ride Cards** — Date, status, pickup, drop, vehicle, distance, fare
- Tap to open Ride Details
- Pull-to-refresh
- Empty state when no rides

---

## 7. Settings & Configuration

### 7.1 Server Configuration Screen
- API Gateway URL input
- WebSocket URL (auto-derived or manual)
- Test connection
- Save & apply
- Presets: Emulator, Localhost, LAN
- Shown on first launch or accessible from settings

### 7.2 Connection Error Screen
- Displayed when backend is unreachable
- Retry connection
- Edit URL
- Navigate to Server Config

---

## 8. Real-Time & Integrations

### 8.1 Realtime Service (SSE + Socket.io)
- **Driver Events** — New ride offers, ride taken, ride cancelled
- **Ride Events** — Status updates, driver location, driver assigned, cancelled
- Connection confirmation before going online
- Auto-reconnect with exponential backoff
- 25-second timeout for mobile networks

### 8.2 WebSocket Service (Socket.io)
- Connect with JWT
- **Events:** new-ride-request, ride-status-update, driver-assigned, ride-cancelled, ride-message, chat-history
- **Driver:** join-driver, driver-online, driver-offline, accept-ride-request
- **Ride:** join-ride, leave-ride
- Reconnect and rejoin rooms on restore

### 8.3 API Client
- Dio HTTP client
- Auth: send OTP, verify OTP, refresh token, sign out
- User: get current user, update user
- Rides: create, get, cancel, update status, start (OTP), rating, receipt, chat
- Driver: earnings, location, driver rides, status
- Token refresh on 401

### 8.4 Maps & Location
- **Directions Service** — Google Directions API for routes
- **Places Service** — Google Places search
- **Maps Service** — Polyline decode, map utilities
- **Geolocator** — GPS, permissions, position stream
- **Geocoding** — Address ↔ coordinates

---

## 9. Push Notifications

- FCM (Firebase Cloud Messaging) initialization
- Background message handler
- Notification tap handling — Navigate by type (RIDE_UPDATE, PAYMENT)
- **Events:** NEW_RIDE_REQUEST, DRIVER_ASSIGNED, RIDE_STARTED, RIDE_COMPLETED, RIDE_CANCELLED
- Profile settings: Notifications, Promotions toggles
- Permission request and "Open Settings" when denied
- Flutter Local Notifications for foreground display

---

## 10. Localization & Theming

### 10.1 Languages
- English (India)
- Hindi
- Tamil
- Telugu
- Kannada
- Malayalam
- Bengali

### 10.2 Theme
- Light mode
- Dark mode
- Settings: Language, dark mode toggles

---

## 11. Technical Integrations

| Integration | Purpose |
|-------------|---------|
| **Firebase** | Core, Auth, Messaging, Analytics, Storage, Firestore, App Check |
| **Google Maps** | Map display, directions, geocoding, Places |
| **Socket.io** | Real-time ride and driver events |
| **Razorpay** | Payment SDK (in dependencies) |
| **Geolocator** | GPS, permissions, position stream |
| **Geocoding** | Address ↔ coordinates |
| **Image Picker** | Driver document uploads |
| **Flutter Local Notifications** | Foreground FCM display |
| **Share Plus** | Receipt sharing |
| **URL Launcher** | Call, SMS, email, maps |
| **Vibration** | Haptic feedback for new ride offers |

---

## 12. App Routes Reference

| Route | Screen |
|-------|--------|
| `/` | Home |
| `/login` | Login |
| `/signup` | Signup |
| `/otp-verification` | OTP Verification |
| `/otp-verification/name` | Name Entry (new user) |
| `/otp-verification/terms` | Terms Acceptance |
| `/phone-number` | Phone Number |
| `/services` | Services |
| `/history` | Ride History |
| `/profile` | Profile |
| `/booking/find-trip` | Find Trip |
| `/booking/payment` | Payment |
| `/booking/searching` | Searching Drivers |
| `/booking/driver-assigned` | Driver Assigned |
| `/ride/:rideId` | Ride Details |
| `/ride/:rideId/tracking` | Ride Tracking |
| `/driver` | Driver Home |
| `/driver/onboarding` | Driver Onboarding |
| `/driver/welcome` | Driver Welcome |
| `/driver/profile` | Driver Profile |
| `/driver/active-ride` | Driver Active Ride |
| `/payment` | Payment |
| `/payment/methods` | Payment Methods |
| `/settings` | Settings |
| `/settings/notifications` | Notifications |
| `/settings/server` | Server Configuration |

---

## User Flows Summary

### Rider Flow
1. Login (phone OTP) → Home  
2. Find Ride → Services → Pick vehicle → Find Trip (addresses) → Payment → Confirm  
3. Searching Drivers → Driver Assigned (OTP, call, chat) → Ride in progress → Complete → Rate  
4. History → Ride Details → Receipt, Help  

### Driver Flow
1. Login → Home → Open Drivers' App  
2. Onboarding (if new): Email, vehicle, personal info, documents, verification  
3. Driver Welcome → Start Driving (when verified)  
4. Driver Home → Go Online → Receive offers → Accept  
5. Active Ride → OTP → Pickup → Drop → Complete → Cash/QR if needed  

### Auth Flow
1. Login → Signup (phone) → OTP → Name (new user) → Terms → Home  
2. Switch Account: Home → Switch Account → Choose saved account  

---

*This document is a comprehensive list of all features in the Raahi Flutter application. No code was modified during its creation.*
