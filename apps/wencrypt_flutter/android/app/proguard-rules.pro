# Keep JNI bridge methods backed by libwencrypt_core.so (crates/wencrypt-core/src/android_bridge.rs).
-keep class org.wencrypt.wencrypt.NativeVaultBridge {
    native <methods>;
}
