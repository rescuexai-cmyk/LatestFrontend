# Firebase / Play Services — avoid R8 stripping classes used via reflection (release crashes)
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes Exceptions
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Geolocator - prevent R8 from failing on missing class references
-dontwarn com.baseflow.geolocator.GeolocatorLocationService$LocalBinder
-dontwarn com.baseflow.geolocator.GeolocatorLocationService
-dontwarn com.baseflow.geolocator.LocationServiceHandlerImpl
-dontwarn com.baseflow.geolocator.StreamHandlerImpl
-dontwarn com.baseflow.geolocator.errors.ErrorCallback
-dontwarn com.baseflow.geolocator.errors.ErrorCodes
-dontwarn com.baseflow.geolocator.errors.PermissionUndefinedException
-dontwarn com.baseflow.geolocator.location.GeolocationManager
-dontwarn com.baseflow.geolocator.location.LocationClient
-dontwarn com.baseflow.geolocator.location.LocationOptions
-dontwarn com.baseflow.geolocator.location.LocationServiceListener
-dontwarn com.baseflow.geolocator.location.PositionChangedCallback
-dontwarn com.baseflow.geolocator.permission.LocationPermission
-dontwarn com.baseflow.geolocator.permission.PermissionManager
-dontwarn com.baseflow.geolocator.permission.PermissionResultCallback
