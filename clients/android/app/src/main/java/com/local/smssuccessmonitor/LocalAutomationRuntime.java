package com.local.smssuccessmonitor;

import android.annotation.SuppressLint;
import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebResourceResponse;

import org.json.JSONObject;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

final class LocalAutomationRuntime {
    interface Callback {
        void complete(String value, String error);
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Map<String, Callback> callbacks = new HashMap<>();
    private final WebView webView;
    private final long createdAt = System.currentTimeMillis();
    private boolean pageReady;
    private boolean destroyed;
    private String loadError = "";

    @SuppressLint({"SetJavaScriptEnabled", "JavascriptInterface"})
    LocalAutomationRuntime(Context context) {
        webView = new WebView(context);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(false);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        webView.addJavascriptInterface(new RuntimeBridge(), "LocalAutomationBridge");
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public android.webkit.WebResourceResponse shouldInterceptRequest(
                    WebView view,
                    android.webkit.WebResourceRequest request
            ) {
                return localAssetResponse(context, request.getUrl());
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                pageReady = true;
            }

            @Override
            public void onReceivedError(
                    WebView view,
                    android.webkit.WebResourceRequest request,
                    android.webkit.WebResourceError error
            ) {
                if (!request.isForMainFrame()) return;
                loadError = String.valueOf(error.getDescription());
                failAll(loadError);
            }
        });
        webView.loadUrl("https://smsmonitor.local/runtime.html");
    }

    private WebResourceResponse localAssetResponse(Context context, Uri uri) {
        if (uri == null || !"smsmonitor.local".equals(uri.getHost())) return null;
        String assetPath = uri.getPath() == null ? "" : uri.getPath().replaceFirst("^/", "");
        if (assetPath.isEmpty() || assetPath.contains("..")) return null;
        try {
            String lower = assetPath.toLowerCase();
            String mime = lower.endsWith(".html") ? "text/html"
                    : lower.endsWith(".js") || lower.endsWith(".mjs")
                            ? "text/javascript"
                    : lower.endsWith(".wasm") ? "application/wasm"
                    : lower.endsWith(".jpg") || lower.endsWith(".jpeg")
                            ? "image/jpeg"
                    : "application/octet-stream";
            String encoding = mime.startsWith("text/") ? "UTF-8" : null;
            return new WebResourceResponse(
                    mime,
                    encoding,
                    context.getAssets().open("auto-login/" + assetPath)
            );
        } catch (Exception ignored) {
            return null;
        }
    }

    void recognize(String dataUrl, Callback callback) {
        call("recognize", new String[]{dataUrl}, callback);
    }

    void generateTotp(String secret, Callback callback) {
        call("generateTotp", new String[]{secret}, callback);
    }

    void generateTotp(String secret, long timestamp, Callback callback) {
        call("generateTotp", new String[]{secret, String.valueOf(timestamp)}, callback);
    }

    void destroy() {
        destroyed = true;
        handler.removeCallbacksAndMessages(null);
        failAll("本地自动登录组件已停止");
        webView.destroy();
    }

    private void call(String method, String[] arguments, Callback callback) {
        if (destroyed) {
            callback.complete("", "本地自动登录组件已停止");
            return;
        }
        if (!loadError.isEmpty()) {
            callback.complete("", loadError);
            return;
        }
        if (!pageReady) {
            if (System.currentTimeMillis() - createdAt > 30_000L) {
                callback.complete("", "本地自动登录组件加载超过 30 秒");
                return;
            }
            handler.postDelayed(() -> call(method, arguments, callback), 200L);
            return;
        }
        String requestId = UUID.randomUUID().toString();
        callbacks.put(requestId, callback);
        handler.postDelayed(() -> {
            Callback pending = callbacks.remove(requestId);
            if (pending != null) pending.complete("", "本地自动登录操作超过 45 秒");
        }, 45_000L);
        StringBuilder args = new StringBuilder();
        for (int index = 0; index < arguments.length; index += 1) {
            if (index > 0) args.append(',');
            args.append(JSONObject.quote(arguments[index]));
        }
        String script = "Promise.resolve(globalThis.localAutomationRuntime["
                + JSONObject.quote(method) + "](" + args + "))"
                + ".then(function(value){LocalAutomationBridge.complete("
                + JSONObject.quote(requestId) + ",String(value||''),'');})"
                + ".catch(function(error){LocalAutomationBridge.complete("
                + JSONObject.quote(requestId) + ",'',String(error&&error.message||error));});";
        webView.evaluateJavascript(script, null);
    }

    private void failAll(String message) {
        for (Callback callback : callbacks.values()) callback.complete("", message);
        callbacks.clear();
    }

    private final class RuntimeBridge {
        @JavascriptInterface
        public void complete(String requestId, String value, String error) {
            handler.post(() -> {
                Callback callback = callbacks.remove(requestId);
                if (callback != null) callback.complete(value, error);
            });
        }
    }
}
