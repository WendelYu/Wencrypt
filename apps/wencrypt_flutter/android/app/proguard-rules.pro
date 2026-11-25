# Keep JNI bridge methods backed by libwencrypt_core.so (crates/wencrypt-core/src/android_bridge.rs).
-keep class org.wencrypt.wencrypt.NativeVaultBridge {
    native <methods>;
}

# Keep bundled ML Kit Chinese text recognition components during R8 shrinking.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.**
