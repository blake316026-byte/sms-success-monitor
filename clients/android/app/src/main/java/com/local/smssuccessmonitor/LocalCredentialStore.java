package com.local.smssuccessmonitor;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.json.JSONObject;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class LocalCredentialStore {
    static final class Profile {
        final String username;
        final String password;
        final String totpSecret;
        final String token;
        final boolean autoLoginEnabled;

        Profile(String username, String password, String totpSecret, String token,
                boolean autoLoginEnabled) {
            this.username = username == null ? "" : username;
            this.password = password == null ? "" : password;
            this.totpSecret = totpSecret == null ? "" : totpSecret;
            this.token = token == null ? "" : token;
            this.autoLoginEnabled = autoLoginEnabled;
        }

        boolean canAutoLogin() {
            return autoLoginEnabled && !username.trim().isEmpty() && !password.isEmpty();
        }
    }

    static final class Summary {
        final boolean configured;
        final String username;
        final boolean passwordConfigured;
        final boolean totpConfigured;
        final boolean tokenConfigured;
        final boolean autoLoginEnabled;

        Summary(Profile profile) {
            configured = profile != null;
            username = profile == null ? "" : profile.username;
            passwordConfigured = profile != null && !profile.password.isEmpty();
            totpConfigured = profile != null && !profile.totpSecret.isEmpty();
            tokenConfigured = profile != null && !profile.token.isEmpty();
            autoLoginEnabled = profile != null && profile.autoLoginEnabled;
        }
    }

    private static final String KEY_ALIAS = "sms-success-monitor-local-login-v1";
    private static final String STORE_NAME = "local-login-profiles";
    private static final String ANDROID_KEYSTORE = "AndroidKeyStore";

    private final SharedPreferences preferences;

    LocalCredentialStore(Context context) {
        preferences = context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE);
    }

    synchronized Profile get(String moduleId) {
        String encoded = preferences.getString(moduleId, "");
        if (encoded == null || encoded.isEmpty()) return null;
        try {
            byte[] envelope = Base64.decode(encoded, Base64.NO_WRAP);
            ByteBuffer buffer = ByteBuffer.wrap(envelope);
            int ivLength = buffer.getInt();
            if (ivLength < 12 || ivLength > 32 || buffer.remaining() <= ivLength) return null;
            byte[] iv = new byte[ivLength];
            buffer.get(iv);
            byte[] encrypted = new byte[buffer.remaining()];
            buffer.get(encrypted);

            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), new GCMParameterSpec(128, iv));
            JSONObject json = new JSONObject(new String(
                    cipher.doFinal(encrypted),
                    StandardCharsets.UTF_8
            ));
            return new Profile(
                    json.optString("username"),
                    json.optString("password"),
                    json.optString("totpSecret"),
                    json.optString("token"),
                    json.optBoolean("autoLoginEnabled", false)
            );
        } catch (Exception ignored) {
            return null;
        }
    }

    synchronized boolean save(String moduleId, Profile profile) {
        try {
            JSONObject json = new JSONObject();
            json.put("username", profile.username);
            json.put("password", profile.password);
            json.put("totpSecret", profile.totpSecret);
            json.put("token", profile.token);
            json.put("autoLoginEnabled", profile.autoLoginEnabled);

            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey());
            byte[] encrypted = cipher.doFinal(json.toString().getBytes(StandardCharsets.UTF_8));
            byte[] iv = cipher.getIV();
            ByteBuffer envelope = ByteBuffer.allocate(4 + iv.length + encrypted.length);
            envelope.putInt(iv.length);
            envelope.put(iv);
            envelope.put(encrypted);
            return preferences.edit().putString(
                    moduleId,
                    Base64.encodeToString(envelope.array(), Base64.NO_WRAP)
            ).commit();
        } catch (Exception ignored) {
            return false;
        }
    }

    synchronized void updateToken(String moduleId, String token) {
        Profile current = get(moduleId);
        String normalized = token == null ? "" : token.trim();
        if (current == null || normalized.isEmpty() || normalized.equals(current.token)) return;
        save(moduleId, new Profile(
                current.username,
                current.password,
                current.totpSecret,
                normalized,
                current.autoLoginEnabled
        ));
    }

    synchronized void remove(String moduleId) {
        preferences.edit().remove(moduleId).apply();
    }

    Summary summary(String moduleId) {
        return new Summary(get(moduleId));
    }

    private SecretKey getOrCreateKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance(ANDROID_KEYSTORE);
        keyStore.load(null);
        SecretKey existing = (SecretKey) keyStore.getKey(KEY_ALIAS, null);
        if (existing != null) return existing;

        KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                ANDROID_KEYSTORE
        );
        generator.init(new KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT
        )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return generator.generateKey();
    }
}
