# Backend Real-Time Analysis for Raahi

Analysis of the Backend-deployment realtime service (`/Users/sarthakmishra/updated_backend_19feb/Backend-deployment`) for driver ride request delivery. This complements the Flutter app fixes for real-time ride requests.

---

## Architecture Overview

The backend uses a **hybrid transport** system:
- **SSE** (primary) – Server-Sent Events for server→client push
- **Socket.io** – Bidirectional, used in parallel and as fallback
- **EventBus** – In-process pub/sub that fans out to SSE, Socket.io, MQTT
- **H3** – Geospatial indexing for ride–driver matching

---

## Critical Flow: New Ride Request → Driver

1. **Ride service** creates ride → calls `broadcastRideRequest(rideId, rideData, driverIds)` via HTTP POST to realtime-service
2. **Realtime service** `broadcastRideRequest()`:
   - Emits to Socket.io rooms: `driver-{id}` and `available-drivers`
   - Publishes to EventBus channels: `available-drivers`, `driver:{id}`, `h3:{cell}`
3. **SSE** and **Socket.io** receive from EventBus and deliver to connected clients

---

## Findings & Recommendations

### 1. Driver Registration Order (Potential Race)

**Current flow (Flutter):**
1. `connectDriver()` – SSE + Socket.io connect, emit `join-driver` + `driver-online`
2. `updateDriverStatus(true)` – PATCH /api/driver/status

**Backend behavior:** `registerDriver()` checks `dbDriver.isOnline`. If false, it sends `state-warning` but still allows registration.

**Recommendation:** Backend is tolerant. For consistency, consider updating driver status (PATCH) before or in parallel with realtime connect. The Flutter app could call `updateDriverStatus` first, then `connectDriver`, to avoid the warning.

---

### 2. Driver ID Resolution (userId vs driverId)

**Backend:** `resolveDriverId()` supports both `userId` (JWT) and `driverId`. It looks up in DB and caches the mapping.

**Flutter:** Sends `_driverId` from `currentUserProvider` – this is the **user ID**, not the driver ID.

**Status:** Backend handles this correctly. No change needed.

---

### 3. SSE Path Mismatch (Gateway vs Direct)

**Flutter expects:**
- SSE: `GET {apiUrl}/api/realtime/sse/driver/{driverId}?lat=X&lng=Y`
- API base: `http://139.59.34.68/api` → so full URL is `http://139.59.34.68/api/realtime/sse/driver/...`

**Gateway:** Proxies `/api/realtime/sse` and `/api/realtime` to realtime-service (port 5007).

**Status:** Paths align when using the gateway. Ensure production nginx (if used) proxies `/api` to the gateway.

---

### 4. Socket.io Path for Production

**Flutter connects to:** `http://139.59.34.68/realtime` with path `/realtime/socket.io/`

**Implication:** The app expects nginx to proxy `/realtime` directly to the realtime service (port 5007), not via the gateway. The gateway only exposes `/socket.io` at `http://host/socket.io`.

**Recommendation:** Confirm nginx (or reverse proxy) configuration:

```nginx
# Option A: /realtime goes directly to realtime service
location /realtime/ {
    proxy_pass http://realtime:5007/;  # Strip /realtime, forward /socket.io/ to backend
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_cache_bypass $http_upgrade;
}
```

If the app uses `http://host/api` as base and the gateway handles everything, the Flutter `wsUrl` derivation may need to use `/api/realtime` or `/socket.io` depending on how the gateway is exposed.

---

### 5. Ping/Pong Timeouts (Mobile Networks)

**Backend (index.ts):**
```typescript
pingTimeout: 60000,   // 60s
pingInterval: 25000, // 25s
```

**Status:** Reasonable for mobile. Socket.io may still report "timeout" if the initial connection (polling handshake) is slow.

**Recommendation:** If timeouts persist on real devices, consider:
- `pingTimeout: 90000` (90s)
- `pingInterval: 20000` (20s)

---

### 6. SSE `connected` Event

**Backend (sseManager.ts):** Sends `connected` immediately when a driver SSE connection is established:

```typescript
this.sendEvent(client, 'connected', {
  clientId, channels, protocol: 'sse', h3Index, serverTime, reconnectMs
});
```

**Flutter:** Treats any SSE event as a connection signal (not only `connected`). This is robust.

**Status:** No change needed.

---

### 7. Payload Format for `new-ride-request`

**Backend (realtimeService.ts) payload:**
```typescript
{
  rideId,
  pickupLocation: { lat, lng, address },
  dropLocation: { lat, lng, address },
  distance, estimatedFare, paymentMethod, vehicleType, passengerName, timestamp
}
```

**Flutter RideOffer.fromJson** expects: `rideId`, `pickupLocation`/`pickup_location`, `dropLocation`/`destination_location`, `estimatedFare`/`earning`, etc.

**Status:** Formats are compatible. Flutter handles both camelCase and snake_case.

---

### 8. Registration Success Timing

**Backend:** Emits `registration-success` after driver is fully registered (rooms joined, RAMEN updated).

**Flutter:** Waits up to 5 seconds for `registration-success`; if not received, assumes success when the socket is connected.

**Status:** Logic is sound. Backend always emits `registration-success` on success.

---

### 9. Nginx Buffering for SSE

**Backend (sseManager.ts):** Sets `X-Accel-Buffering: no` to disable nginx buffering.

**Gateway (sseProxyOptions):** Sets `x-accel-buffering: no` and `cache-control: no-cache`.

**Recommendation:** If nginx sits in front of the gateway, ensure:

```nginx
proxy_buffering off;
proxy_cache off;
```

for `/api/realtime/sse` and `/realtime` paths.

---

### 10. Socket.io Payload Format Inconsistency (EventBus vs Direct Emit)

**Direct emit (realtimeService.ts):**
```typescript
io!.to(room).emit('new-ride-request', payload);  // payload = ride data only
```

**EventBus → socketTransport (socketTransport.ts):**
```typescript
this.io.to('available-drivers').emit(event.type, event);  // event = full RideRequestEvent
```

The full event has `{ type, rideId, targetDriverIds, payload }`. The Flutter `RideOffer.fromJson` expects ride data (pickupLocation, etc.) at the top level. When receiving the full event, `pickupLocation` is nested inside `payload`.

**Recommendation:** In `socketTransport.ts`, for `new-ride-request` events, emit the payload (ride data) instead of the full event, to match the direct emit:

```typescript
} else if (channel === 'available-drivers') {
  const data = event.type === 'new-ride-request' && 'payload' in event
    ? (event as RideRequestEvent).payload
    : event;
  this.io.to('available-drivers').emit(event.type, data);
}
```

Similarly for `driver:{id}` channel when event type is `new-ride-request`.

---

### 11. Ride Service → Realtime Call Order

**Ride service** should:
1. Create ride in DB
2. Update driver status (if needed)
3. Call `broadcastRideRequest`

**Potential issue:** If `broadcastRideRequest` is called before the driver has finished Socket.io registration (join-driver, driver-online), the driver may not be in `available-drivers` yet.

**Recommendation:** The broadcast targets `driverIds` from the pricing service (nearby drivers). Those drivers should already be online. Ensure the ride-service flow does not broadcast before the ride is fully created and driver list is finalized.

---

## Summary: Backend Changes to Consider

| Priority | Change | File | Rationale |
|----------|--------|------|-----------|
| **High** | Emit `payload` (not full event) for `new-ride-request` via EventBus | `realtime-service/src/socketTransport.ts` | Flutter expects ride data at top level; EventBus path sends full event with nested payload |
| Medium | Increase `pingTimeout` to 90s | `realtime-service/src/index.ts` | Better tolerance for slow mobile networks |
| Low | Add `/realtime` proxy in gateway | `gateway/src/index.ts` | If Flutter uses wsUrl with /realtime, gateway should support it |
| Low | Verify nginx config | Deployment config | Ensure no buffering for SSE, correct Socket.io path |
| Info | Driver status before connect | Flutter (already considered) | Call PATCH /driver/status before connectDriver to avoid state-warning |

---

## Verification Checklist

- [ ] Nginx (or reverse proxy) correctly proxies `/realtime` to realtime-service:5007
- [ ] Nginx disables buffering for SSE paths
- [ ] Socket.io path `/realtime/socket.io/` resolves to realtime service’s `/socket.io`
- [ ] Ride-service `broadcastRideRequest` receives correct `rideData` (pickupLatitude, pickupAddress, etc.)
- [ ] Realtime service `/health` returns 200 when hit via production URL
