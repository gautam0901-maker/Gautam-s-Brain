# Stage M ProGuard rules for release builds. R8 strips unused classes
# but uses reflection extensively for serialization — Firebase / Firestore
# rely on this so we keep their packages whole.

# Firebase Core / Auth / Firestore
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Firestore uses generic types for its POJO serialization
-keepclasseswithmembers class * {
    @com.google.firebase.firestore.PropertyName <fields>;
}
-keepclassmembers class * {
    @com.google.firebase.firestore.PropertyName *;
}

# Google Sign In
-keep class com.google.android.gms.auth.** { *; }

# Geolocator / Geocoding (native channels)
-keep class com.baseflow.geolocator.** { *; }
-keep class com.baseflow.geocoding.** { *; }

# OkHttp / http (used by Firebase + our http calls)
-dontwarn okhttp3.**
-dontwarn okio.**

# Generic Flutter rule — keep MethodChannel handlers reachable
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep model classes used as Firestore documents (POJOs go via reflection)
# Our Dart side handles this — no Java/Kotlin models needed for now.
