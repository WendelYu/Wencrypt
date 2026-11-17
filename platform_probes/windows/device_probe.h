#pragma once
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <flutter/encodable_value.h>
#include <algorithm>
#include <array>
#include <string>
#include <vector>

// P0 demonstrates TPM != Windows Hello authorization binding. Never enables unlock.
inline flutter::EncodableValue WindowsDeviceProbe(const std::string& method) {
  using V = flutter::EncodableValue;
  using M = flutter::EncodableMap;
  NCRYPT_PROV_HANDLE provider = 0;
  SECURITY_STATUS status = NCryptOpenStorageProvider(&provider, MS_PLATFORM_CRYPTO_PROVIDER, 0);
  bool hardware = false;
  if (status == ERROR_SUCCESS) {
    DWORD impl = 0, length = 0;
    hardware = NCryptGetProperty(provider, NCRYPT_IMPL_TYPE_PROPERTY,
        reinterpret_cast<PBYTE>(&impl), sizeof(impl), &length, 0) == ERROR_SUCCESS &&
        (impl & NCRYPT_IMPL_HARDWARE_FLAG) != 0;
  }
  if (method == "capabilities") {
    if (provider) NCryptFreeObject(provider);
    return V(M{{V("platform"),V("windows")}, {V("hardwareAvailable"),V(hardware)},
      {V("strictUnlockEnabled"),V(false)}, {V("authenticationBound"),V(false)},
      {V("status"),V("TPM probe only; Windows Hello-bound unwrap NOT established")}});
  }
  if (method != "createProbe" || !hardware) {
    if (provider) NCryptFreeObject(provider);
    return V(M{{V("status"),V("not_passed")}, {V("stage"),V("hello_bound_unwrap_unimplemented")},
      {V("strictUnlockEnabled"),V(false)}});
  }
  NCRYPT_KEY_HANDLE key = 0;
  // Unnamed ephemeral TPM key: no user keys are replaced or deleted.
  status = NCryptCreatePersistedKey(provider, &key, NCRYPT_RSA_ALGORITHM, nullptr, 0, 0);
  DWORD bits = 2048;
  if (status == ERROR_SUCCESS)
    status = NCryptSetProperty(key,NCRYPT_LENGTH_PROPERTY,reinterpret_cast<PBYTE>(&bits),sizeof(bits),0);
  if (status == ERROR_SUCCESS) status = NCryptFinalizeKey(key,0);
  std::array<BYTE,32> marker{};
  marker.fill(0xA5); // Public test marker, never a real DEK.
  BCRYPT_OAEP_PADDING_INFO padding{BCRYPT_SHA256_ALGORITHM,nullptr,0};
  DWORD encrypted_length = 0, decrypted_length = 0;
  std::vector<BYTE> encrypted, decrypted;
  if (status == ERROR_SUCCESS)
    status=NCryptEncrypt(key,marker.data(),static_cast<DWORD>(marker.size()),&padding,nullptr,0,&encrypted_length,NCRYPT_PAD_OAEP_FLAG);
  if (status == ERROR_SUCCESS && encrypted_length <= 4096) {
    encrypted.resize(encrypted_length);
    status=NCryptEncrypt(key,marker.data(),static_cast<DWORD>(marker.size()),&padding,encrypted.data(),encrypted_length,&encrypted_length,NCRYPT_PAD_OAEP_FLAG);
  } else if (status == ERROR_SUCCESS) status=NTE_BAD_DATA;
  if (status == ERROR_SUCCESS)
    status=NCryptDecrypt(key,encrypted.data(),encrypted_length,&padding,nullptr,0,&decrypted_length,NCRYPT_PAD_OAEP_FLAG);
  if (status == ERROR_SUCCESS && decrypted_length <= 4096) {
    decrypted.resize(decrypted_length);
    status=NCryptDecrypt(key,encrypted.data(),encrypted_length,&padding,decrypted.data(),decrypted_length,&decrypted_length,NCRYPT_PAD_OAEP_FLAG);
  } else if (status == ERROR_SUCCESS) status=NTE_BAD_DATA;
  bool matches=status==ERROR_SUCCESS && decrypted_length==marker.size() &&
      std::equal(marker.begin(),marker.end(),decrypted.begin());
  if (!decrypted.empty()) SecureZeroMemory(decrypted.data(),decrypted.size());
  if (key) NCryptFreeObject(key);
  if (provider) NCryptFreeObject(provider);
  return V(M{{V("status"),V(matches ? "tpm_roundtrip_only" : "not_passed")},
    {V("hardwareBacked"),V(hardware)}, {V("authenticationBound"),V(false)},
    {V("strictUnlockEnabled"),V(false)}, {V("osStatus"),V(static_cast<int64_t>(status))},
    {V("remaining"),V("Hello-bound private key operation, persistence, cancel and reboot verification")}});
}
