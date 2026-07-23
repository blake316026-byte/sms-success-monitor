package com.local.smssuccessmonitor;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.MutableContextWrapper;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.graphics.Color;
import android.net.Uri;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

public final class MonitorService extends Service {
    public interface Listener {
        void onMonitorSnapshot(MonitorSnapshot snapshot);
    }

    public static final class MonitorSnapshot {
        public final List<ModuleState> modules;
        public final ModuleState focus;
        public final int alertCount;
        public final int healthyCount;
        public final int authenticationCount;
        public final int errorCount;
        public final int sampleLimit;
        public final int minimumSampleLimit;
        public final int maximumSampleLimit;

        MonitorSnapshot(List<ModuleState> modules, ModuleState focus, int alertCount,
                        int healthyCount, int authenticationCount, int errorCount,
                        int sampleLimit, int minimumSampleLimit, int maximumSampleLimit) {
            this.modules = Collections.unmodifiableList(modules);
            this.focus = focus;
            this.alertCount = alertCount;
            this.healthyCount = healthyCount;
            this.authenticationCount = authenticationCount;
            this.errorCount = errorCount;
            this.sampleLimit = sampleLimit;
            this.minimumSampleLimit = minimumSampleLimit;
            this.maximumSampleLimit = maximumSampleLimit;
        }

        public ModuleState find(String id) {
            for (ModuleState state : modules) {
                if (state.module.id.equals(id)) return state;
            }
            return null;
        }
    }

    public final class LocalBinder extends Binder {
        public MonitorService getService() {
            return MonitorService.this;
        }
    }

    private static final String MONITOR_CHANNEL_ID = "sms-monitor-running";
    private static final String ALERT_CHANNEL_ID = "sms-monitor-alerts";
    private static final int FOREGROUND_NOTIFICATION_ID = 4101;
    private static final int ALERT_NOTIFICATION_BASE = 4200;
    private static final int DEFAULT_SAMPLE_LIMIT = 200;
    private static final int MIN_SAMPLE_LIMIT = 10;
    private static final int MAX_SAMPLE_LIMIT = 500;
    private static final long SCAN_INTERVAL_MS = 60_000L;
    private static final long SCAN_POLL_MS = 400L;
    private static final int MAX_SCAN_POLLS = 140;
    private static final int SCAN_FAILURE_RELOAD_THRESHOLD = 2;
    private static final long AUTO_LOGIN_POLL_MS = 300L;
    private static final int MAX_AUTO_LOGIN_POLLS = 80;
    private static final int MAX_CAPTCHA_ATTEMPTS = 10;
    private static final int MAX_TOTP_ATTEMPTS = 5;
    private static final long AUTO_LOGIN_COOLDOWN_MS = 5 * 60_000L;

    private final IBinder binder = new LocalBinder();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final LinkedHashMap<String, ManagedPage> pages = new LinkedHashMap<>();
    private final Set<Listener> listeners = new LinkedHashSet<>();
    private final Map<String, String> alertSignatures = new HashMap<>();
    private final Runnable periodicScan = new Runnable() {
        @Override
        public void run() {
            scanAll();
            mainHandler.postDelayed(this, SCAN_INTERVAL_MS);
        }
    };

    private NotificationManager notificationManager;
    private SharedPreferences preferences;
    private String scanSource;
    private String loginAutomationSource;
    private LocalCredentialStore credentialStore;
    private LocalAutomationRuntime automationRuntime;
    private WindowManager windowManager;
    private GaugeView overlayView;
    private WindowManager.LayoutParams overlayParams;
    private boolean overlayEnabled;
    private int sampleLimit;

    private static final class ManagedPage {
        final ModuleState state;
        final MutableContextWrapper context;
        final WebView webView;
        String scanToken;
        int scanSampleLimit;
        int pollCount;
        String pageAutomationToken;
        int pageAutomationPollCount;
        String autoLoginStage = "";
        Runnable autoLoginOutcome;

        ManagedPage(ModuleState state, MutableContextWrapper context, WebView webView) {
            this.state = state;
            this.context = context;
            this.webView = webView;
        }
    }

    private interface PageAutomationCallback {
        void complete(Object value, String error);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        notificationManager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);
        preferences = getSharedPreferences("monitor-preferences", MODE_PRIVATE);
        credentialStore = new LocalCredentialStore(this);
        automationRuntime = new LocalAutomationRuntime(this);
        overlayEnabled = preferences.getBoolean("overlay-enabled", true);
        sampleLimit = normalizeSampleLimit(
                preferences.getInt("sample-limit", DEFAULT_SAMPLE_LIMIT)
        );
        createNotificationChannels();
        startForegroundMonitor(buildForegroundNotification(null));

        try {
            scanSource = readAsset("scan.js");
            loginAutomationSource = readAsset("auto-login/login-page.js");
            for (ModuleConfig module : ModuleConfig.load(this)) createPage(module);
            refreshOutputs();
            mainHandler.postDelayed(periodicScan, 5_000L);
        } catch (Exception error) {
            notificationManager.notify(
                    FOREGROUND_NOTIFICATION_ID,
                    buildForegroundNotification("初始化失败：" + error.getMessage())
            );
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public void onDestroy() {
        removeOverlay();
        if (automationRuntime != null) automationRuntime.destroy();
        mainHandler.removeCallbacksAndMessages(null);
        for (ManagedPage page : pages.values()) page.webView.destroy();
        pages.clear();
        super.onDestroy();
    }

    @SuppressLint("SetJavaScriptEnabled")
    private void createPage(ModuleConfig module) {
        ModuleState state = new ModuleState(module);
        MutableContextWrapper wrapper = new MutableContextWrapper(this);
        WebView webView = new WebView(wrapper);
        ManagedPage page = new ManagedPage(state, wrapper, webView);
        pages.put(module.id, page);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setBuiltInZoomControls(true);
        settings.setDisplayZoomControls(false);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);

        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(webView, true);
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG);

        webView.setBackgroundColor(Color.WHITE);
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                handlePageFinished(page, url);
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return false;
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame()) return;
                finishScanError(page, "页面加载失败：" + error.getDescription());
            }
        });
        webView.loadUrl(module.url);
    }

    private void handlePageFinished(ManagedPage page, String url) {
        if (isAuthenticationUrl(url)) {
            handleAuthenticationRequired(page, "平台需要重新登录。");
            return;
        }
        if (!sameOrigin(page.state.module.url, url)) {
            refreshOutputs();
            return;
        }
        resetAutoLogin(page);
        persistCurrentToken(page);
        refreshOutputs();
        if (page.state.needsImmediateScan) {
            page.state.needsImmediateScan = false;
            mainHandler.postDelayed(() -> scan(page.state.module.id), 900L);
        }
    }

    public void addListener(Listener listener) {
        listeners.add(listener);
        listener.onMonitorSnapshot(buildSnapshot());
    }

    public void removeListener(Listener listener) {
        listeners.remove(listener);
    }

    public List<ModuleState> getModules() {
        return buildSnapshot().modules;
    }

    public MonitorSnapshot getSnapshot() {
        return buildSnapshot();
    }

    public int getSampleLimit() {
        return sampleLimit;
    }

    public String setSampleLimit(int value) {
        if (value < MIN_SAMPLE_LIMIT || value > MAX_SAMPLE_LIMIT) {
            return "样本条数必须在 " + MIN_SAMPLE_LIMIT + "–" + MAX_SAMPLE_LIMIT + " 之间";
        }
        if (value == sampleLimit) return "";
        sampleLimit = value;
        preferences.edit().putInt("sample-limit", sampleLimit).apply();
        for (ManagedPage page : pages.values()) {
            page.state.clearMetrics();
            page.state.needsImmediateScan = true;
            page.state.status = page.state.scanning ? "scanning" : "starting";
            page.state.message = "样本已改为 " + sampleLimit + " 条，正在重新扫描";
            alertSignatures.remove(page.state.module.id);
        }
        refreshOutputs();
        scanAll();
        return "";
    }

    private static int normalizeSampleLimit(int value) {
        return Math.min(MAX_SAMPLE_LIMIT, Math.max(MIN_SAMPLE_LIMIT, value));
    }

    public WebView attachPage(String id, Activity activity, ViewGroup container) {
        ManagedPage selected = pages.get(id);
        if (selected == null) return null;

        for (ManagedPage page : pages.values()) {
            ViewParent parent = page.webView.getParent();
            if (parent instanceof ViewGroup) ((ViewGroup) parent).removeView(page.webView);
            if (page != selected) page.context.setBaseContext(this);
        }
        selected.context.setBaseContext(activity);
        container.removeAllViews();
        container.addView(selected.webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));
        selected.webView.requestFocus(View.FOCUS_DOWN);
        return selected.webView;
    }

    public void detachPages(ViewGroup container) {
        if (container != null) container.removeAllViews();
        for (ManagedPage page : pages.values()) page.context.setBaseContext(this);
    }

    public String currentUrl(String id) {
        ManagedPage page = pages.get(id);
        return page == null ? "" : page.webView.getUrl();
    }

    public boolean canGoBack(String id) {
        ManagedPage page = pages.get(id);
        return page != null && page.webView.canGoBack();
    }

    public boolean canGoForward(String id) {
        ManagedPage page = pages.get(id);
        return page != null && page.webView.canGoForward();
    }

    public void goBack(String id) {
        ManagedPage page = pages.get(id);
        if (page != null && page.webView.canGoBack()) page.webView.goBack();
    }

    public void goForward(String id) {
        ManagedPage page = pages.get(id);
        if (page != null && page.webView.canGoForward()) page.webView.goForward();
    }

    public void reload(String id) {
        ManagedPage page = pages.get(id);
        if (page != null) page.webView.reload();
    }

    public void navigate(String id, String rawUrl) {
        ManagedPage page = pages.get(id);
        if (page == null || rawUrl == null) return;
        String value = rawUrl.trim();
        if (value.isEmpty()) return;
        if (!value.contains("://")) value = "https://" + value;
        Uri uri = Uri.parse(value);
        if ("https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme())) {
            page.webView.loadUrl(uri.toString());
        }
    }

    public LocalCredentialStore.Summary credentialSummary(String id) {
        return credentialStore.summary(id);
    }

    public String saveCredentials(
            String id,
            String username,
            String passwordInput,
            String totpInput,
            boolean clearTotp,
            boolean autoLoginEnabled
    ) {
        ManagedPage page = pages.get(id);
        if (page == null) return "当前后台不存在";
        LocalCredentialStore.Profile existing = credentialStore.get(id);
        String normalizedUsername = username == null ? "" : username.trim();
        String password = passwordInput == null || passwordInput.isEmpty()
                ? existing == null ? "" : existing.password
                : passwordInput;
        if (normalizedUsername.isEmpty() || password.isEmpty()) return "账号和密码不能为空";
        String totpSecret = clearTotp
                ? ""
                : totpInput == null || totpInput.trim().isEmpty()
                        ? existing == null ? "" : existing.totpSecret
                        : totpInput.trim();
        String token = existing == null ? "" : existing.token;
        boolean saved = credentialStore.save(id, new LocalCredentialStore.Profile(
                normalizedUsername,
                password,
                totpSecret,
                token,
                autoLoginEnabled
        ));
        if (!saved) return "无法写入 Android 本地安全存储";
        resetAutoLogin(page);
        persistCurrentToken(page);
        if (isAuthenticationUrl(page.webView.getUrl())) {
            handleAuthenticationRequired(page, "自动登录配置已更新。");
        }
        return "";
    }

    public void removeCredentials(String id) {
        credentialStore.remove(id);
        ManagedPage page = pages.get(id);
        if (page == null) return;
        resetAutoLogin(page);
        if (isAuthenticationUrl(page.webView.getUrl())) {
            handleAuthenticationRequired(page, "自动登录配置已删除。");
        }
    }

    public void scanAll() {
        for (ManagedPage page : pages.values()) scan(page.state.module.id);
    }

    public void scan(String id) {
        ManagedPage page = pages.get(id);
        if (page == null || page.state.scanning) return;
        String currentUrl = page.webView.getUrl();
        if (currentUrl == null || currentUrl.isEmpty()) return;
        if (isAuthenticationUrl(currentUrl)) {
            handleAuthenticationRequired(page, "平台登录已失效。");
            return;
        }
        if (!sameOrigin(page.state.module.url, currentUrl)) {
            page.state.status = "starting";
            page.state.message = "正在返回后台入口";
            page.state.nextScanAt = System.currentTimeMillis() + 10_000L;
            page.webView.loadUrl(page.state.module.url);
            refreshOutputs();
            return;
        }

        page.state.scanning = true;
        int activeSampleLimit = sampleLimit;
        page.scanSampleLimit = activeSampleLimit;
        page.state.status = "scanning";
        page.state.message = "正在读取最新 " + activeSampleLimit + " 条";
        page.state.nextScanAt = System.currentTimeMillis() + SCAN_INTERVAL_MS;
        page.scanToken = UUID.randomUUID().toString();
        page.pollCount = 0;
        refreshOutputs();

        String token = JSONObject.quote(page.scanToken);
        String script = "(function(){try{" + scanSource
                + "window.__smsMonitorScanResult=null;"
                + "Promise.resolve(globalThis.smsMonitorScan(" + activeSampleLimit + ")).then(function(result){"
                + "window.__smsMonitorScanResult=JSON.stringify({token:" + token + ",result:result});"
                + "}).catch(function(error){window.__smsMonitorScanResult=JSON.stringify({token:" + token
                + ",result:{kind:'error',message:String(error&&error.message||error)}});});"
                + "return true;}catch(error){window.__smsMonitorScanResult=JSON.stringify({token:" + token
                + ",result:{kind:'error',message:String(error&&error.message||error)}});return false;}})()";

        page.webView.evaluateJavascript(script, ignored -> mainHandler.postDelayed(
                () -> pollScanResult(page), SCAN_POLL_MS
        ));
    }

    private void pollScanResult(ManagedPage page) {
        if (!page.state.scanning || page.scanToken == null) return;
        page.pollCount += 1;
        if (page.pollCount > MAX_SCAN_POLLS) {
            finishScanError(page, "扫描超过 56 秒，请检查网络后重试");
            return;
        }

        page.webView.evaluateJavascript("window.__smsMonitorScanResult || null", value -> {
            try {
                String payload = decodeJavascriptString(value);
                if (payload == null || payload.isEmpty()) {
                    mainHandler.postDelayed(() -> pollScanResult(page), SCAN_POLL_MS);
                    return;
                }
                JSONObject envelope = new JSONObject(payload);
                if (!page.scanToken.equals(envelope.optString("token"))) {
                    mainHandler.postDelayed(() -> pollScanResult(page), SCAN_POLL_MS);
                    return;
                }
                page.webView.evaluateJavascript("window.__smsMonitorScanResult=null", null);
                applyScanResult(page, envelope.getJSONObject("result"));
            } catch (Exception error) {
                finishScanError(page, "扫描结果无法识别：" + error.getMessage());
            }
        });
    }

    private void applyScanResult(ManagedPage page, JSONObject result) {
        page.state.scanning = false;
        page.scanToken = null;
        long now = System.currentTimeMillis();
        String kind = result.optString("kind", "error");

        if ("auth".equals(kind)) {
            page.state.consecutiveScanFailures = 0;
            handleAuthenticationRequired(page, result.optString("message", "平台登录已失效。"));
            return;
        }
        if (page.scanSampleLimit != sampleLimit) {
            page.scanSampleLimit = 0;
            page.state.needsImmediateScan = false;
            mainHandler.post(() -> scan(page.state.module.id));
            return;
        }
        if (!"ok".equals(kind)) {
            finishScanError(page, result.optString("message", "短信记录接口扫描失败"));
            return;
        }

        JSONArray statuses = result.optJSONArray("statuses");
        int sampleCount = statuses == null ? 0 : Math.min(statuses.length(), page.scanSampleLimit);
        int successCount = 0;
        for (int index = 0; index < sampleCount; index += 1) {
            if ("SUCCESS".equals(statuses.optString(index).trim().toUpperCase(Locale.ROOT))) {
                successCount += 1;
            }
        }
        if (sampleCount == 0) {
            finishScanError(page, "短信记录接口未返回可统计记录");
            return;
        }

        page.state.hasMetrics = true;
        page.state.consecutiveScanFailures = 0;
        page.state.sampleCount = sampleCount;
        page.state.successCount = successCount;
        page.state.nonSuccessCount = sampleCount - successCount;
        page.state.successRate = (double) successCount / (double) sampleCount;
        page.state.status = page.state.isAlert() ? "alert" : "healthy";
        page.state.message = page.state.isAlert() ? "成功率低于 50%" : "成功率正常";
        page.state.scannedAt = now;
        page.state.nextScanAt = now + SCAN_INTERVAL_MS;
        page.scanSampleLimit = 0;
        refreshOutputs();
        notifyAlertIfNeeded(page.state);
    }

    private void finishScanError(ManagedPage page, String message) {
        if (page.state.scanning && page.scanSampleLimit != 0
                && page.scanSampleLimit != sampleLimit) {
            page.state.scanning = false;
            page.scanToken = null;
            page.scanSampleLimit = 0;
            page.state.needsImmediateScan = false;
            mainHandler.post(() -> scan(page.state.module.id));
            return;
        }
        page.state.scanning = false;
        page.scanToken = null;
        page.scanSampleLimit = 0;
        page.state.consecutiveScanFailures += 1;
        page.state.status = "error";
        page.state.message = message;
        page.state.scannedAt = System.currentTimeMillis();
        page.state.nextScanAt = page.state.scannedAt + SCAN_INTERVAL_MS;
        boolean shouldReload = page.state.consecutiveScanFailures >= SCAN_FAILURE_RELOAD_THRESHOLD;
        if (shouldReload) {
            page.state.consecutiveScanFailures = 0;
            page.state.needsImmediateScan = true;
            page.state.message = message + "；正在自动重载后台连接。";
        }
        alertSignatures.remove(page.state.module.id);
        refreshOutputs();
        if (shouldReload) mainHandler.post(page.webView::reload);
    }

    private void handleAuthenticationRequired(ManagedPage page, String message) {
        page.state.scanning = false;
        page.scanToken = null;
        page.scanSampleLimit = 0;
        page.state.consecutiveScanFailures = 0;
        page.state.clearMetrics();
        page.state.needsImmediateScan = true;
        page.state.nextScanAt = System.currentTimeMillis() + SCAN_INTERVAL_MS;
        alertSignatures.remove(page.state.module.id);

        LocalCredentialStore.Profile profile = credentialStore.get(page.state.module.id);
        if (profile == null || !profile.canAutoLogin()) {
            page.state.status = "auth";
            page.state.message = message + " 请打开对应后台标签完成登录。";
            refreshOutputs();
            return;
        }
        long now = System.currentTimeMillis();
        if (page.state.autoLoginCooldownUntil > 0 && page.state.autoLoginCooldownUntil <= now) {
            page.state.captchaAutoLoginAttempts = 0;
            page.state.totpAutoLoginAttempts = 0;
            page.state.autoLoginCooldownUntil = 0;
        }
        if (page.state.autoLoginCooldownUntil > now) {
            page.state.status = "auth";
            page.state.message = "自动登录连续失败，已暂停至 "
                    + formatTime(page.state.autoLoginCooldownUntil) + "。";
            refreshOutputs();
            return;
        }

        page.state.status = "starting";
        page.state.message = "Token 已失效，正在自动登录";
        refreshOutputs();
        String currentUrl = page.webView.getUrl();
        if (isAuthenticationUrl(currentUrl)) attemptAutoLogin(page, currentUrl);
        else page.webView.loadUrl(loginUrl(page.state.module.url));
    }

    private void attemptAutoLogin(ManagedPage page, String currentUrl) {
        LocalCredentialStore.Profile profile = credentialStore.get(page.state.module.id);
        if (profile == null || !profile.canAutoLogin() || page.state.autoLoginInProgress) return;
        long now = System.currentTimeMillis();
        if (page.state.autoLoginCooldownUntil > now) return;
        String path = currentUrl == null ? "" : Uri.parse(currentUrl).getPath();
        if ("/unlock-ip".equals(path)) {
            page.state.status = "auth";
            page.state.message = "平台要求人工完成 IP 解锁，自动登录已暂停。";
            refreshOutputs();
            return;
        }

        boolean isTotp = "/ga-auth".equals(path);
        int attempts = isTotp
                ? page.state.totpAutoLoginAttempts
                : page.state.captchaAutoLoginAttempts;
        int maximumAttempts = isTotp ? MAX_TOTP_ATTEMPTS : MAX_CAPTCHA_ATTEMPTS;
        String phaseName = isTotp ? "Google 验证码" : "图片验证码";
        if (attempts >= maximumAttempts) {
            pauseAutoLogin(page, phaseName, maximumAttempts, "");
            return;
        }

        page.state.autoLoginInProgress = true;
        page.state.status = "starting";
        page.state.message = "正在自动登录（" + phaseName + " " + (attempts + 1)
                + "/" + maximumAttempts + "）";
        refreshOutputs();
        runPageAutomation(page, "globalThis.smsLoginAutomation.snapshot()", (value, error) -> {
            if (!error.isEmpty()) {
                retryAutoLogin(page, "无法读取登录页面：" + error);
                return;
            }
            if (!(value instanceof JSONObject)) {
                retryAutoLogin(page, "登录页面状态无法识别");
                return;
            }
            JSONObject snapshot = (JSONObject) value;
            String token = snapshot.optString("token");
            if (!token.isEmpty()) credentialStore.updateToken(page.state.module.id, token);
            String kind = snapshot.optString("kind");
            if ("login".equals(kind)) {
                solveCaptchaAndSubmit(page, profile, snapshot.optString("captchaDataUrl"));
            } else if ("totp".equals(kind)) {
                generateAndSubmitTotp(page, profile);
            } else if ("authenticated".equals(kind)) {
                completeAutoLogin(page, token);
            } else {
                page.state.autoLoginInProgress = false;
                page.state.status = "auth";
                page.state.message = "平台要求人工完成 IP 解锁，自动登录已暂停。";
                refreshOutputs();
            }
        });
    }

    private void solveCaptchaAndSubmit(
            ManagedPage page,
            LocalCredentialStore.Profile profile,
            String dataUrl
    ) {
        if (dataUrl == null || dataUrl.isEmpty()) {
            retryAutoLogin(page, "验证码图片尚未加载");
            return;
        }
        automationRuntime.recognize(dataUrl, (captcha, error) -> {
            if (!error.isEmpty()) {
                retryAutoLogin(page, "本地验证码识别失败：" + error);
                return;
            }
            if (captcha == null || !captcha.matches("^[0-9A-Za-z]{4,8}$")) {
                refreshCaptcha(page);
                retryAutoLogin(page, "本地验证码识别结果无效");
                return;
            }
            try {
                JSONObject input = new JSONObject();
                input.put("username", profile.username);
                input.put("password", profile.password);
                input.put("captcha", captcha);
                runPageAutomation(
                        page,
                        "globalThis.smsLoginAutomation.submitLogin(" + input + ")",
                        (value, submitError) -> {
                            if (!submitError.isEmpty() || !(value instanceof JSONObject)
                                    || !((JSONObject) value).optBoolean("submitted")) {
                                String detail = value instanceof JSONObject
                                        ? ((JSONObject) value).optString("message") : submitError;
                                retryAutoLogin(page, detail.isEmpty()
                                        ? "登录表单尚未准备完成" : detail);
                                return;
                            }
                            page.autoLoginStage = "login";
                            scheduleAutoLoginOutcomeCheck(page);
                        }
                );
            } catch (Exception exception) {
                retryAutoLogin(page, "登录参数无法处理");
            }
        });
    }

    private void generateAndSubmitTotp(
            ManagedPage page,
            LocalCredentialStore.Profile profile
    ) {
        String secret = profile.totpSecret.trim();
        if (secret.isEmpty()) {
            page.state.autoLoginInProgress = false;
            page.state.status = "auth";
            page.state.message = "账号密码已通过，但本地未配置 Google 密钥，请人工完成二次验证。";
            refreshOutputs();
            return;
        }
        int[] offsets = new int[]{0, -210, 210, -180, 180};
        int offset = offsets[Math.min(page.state.totpAutoLoginAttempts, offsets.length - 1)];
        long adjustedSeconds = System.currentTimeMillis() / 1000L + offset;
        long delayMs = Math.floorMod(adjustedSeconds, 30L) > 24L ? 6_500L : 0L;
        mainHandler.postDelayed(() -> generateAndSubmitTotpCode(page, secret, offset), delayMs);
    }

    private void generateAndSubmitTotpCode(ManagedPage page, String secret, int offset) {
        if (!page.state.autoLoginInProgress) return;
        automationRuntime.generateTotp(secret, System.currentTimeMillis() + offset * 1000L, (code, error) -> {
            if (!error.isEmpty()) {
                retryAutoLogin(page, "Google 动态码生成失败：" + error);
                return;
            }
            try {
                JSONObject input = new JSONObject();
                input.put("code", code);
                runPageAutomation(
                        page,
                        "globalThis.smsLoginAutomation.submitTotp(" + input + ")",
                        (value, submitError) -> {
                            if (!submitError.isEmpty() || !(value instanceof JSONObject)
                                    || !((JSONObject) value).optBoolean("submitted")) {
                                String detail = value instanceof JSONObject
                                        ? ((JSONObject) value).optString("message") : submitError;
                                retryAutoLogin(page, detail.isEmpty()
                                        ? "Google 验证页面尚未准备完成" : detail);
                                return;
                            }
                            page.autoLoginStage = "totp";
                            scheduleAutoLoginOutcomeCheck(page);
                        }
                );
            } catch (Exception exception) {
                retryAutoLogin(page, "Google 验证参数无法处理");
            }
        });
    }

    private void scheduleAutoLoginOutcomeCheck(ManagedPage page) {
        if (page.autoLoginOutcome != null) mainHandler.removeCallbacks(page.autoLoginOutcome);
        page.autoLoginOutcome = () -> {
            page.state.autoLoginInProgress = false;
            String currentUrl = page.webView.getUrl();
            if (isAuthenticationUrl(currentUrl)) {
                if ("/ga-auth".equals(Uri.parse(currentUrl).getPath())
                        && !"totp".equals(page.autoLoginStage)) {
                    page.autoLoginStage = "";
                    attemptAutoLogin(page, currentUrl);
                } else if ("/ga-auth".equals(Uri.parse(currentUrl).getPath())) {
                    retryAutoLogin(page, "Google 验证未通过，正在尝试备用时间窗口");
                } else {
                    refreshCaptcha(page);
                    retryAutoLogin(page, "登录尚未通过，正在更换验证码重试");
                }
                return;
            }
            completeAutoLogin(page, "");
        };
        mainHandler.postDelayed(page.autoLoginOutcome, 7_000L);
    }

    private void retryAutoLogin(ManagedPage page, String message) {
        page.state.autoLoginInProgress = false;
        page.autoLoginStage = "";
        String currentUrl = page.webView.getUrl();
        boolean isTotp = currentUrl != null
                && "/ga-auth".equals(Uri.parse(currentUrl).getPath());
        String phaseName = isTotp ? "Google 验证码" : "图片验证码";
        int maximumAttempts = isTotp ? MAX_TOTP_ATTEMPTS : MAX_CAPTCHA_ATTEMPTS;
        if (isTotp) {
            page.state.totpAutoLoginAttempts += 1;
        } else {
            page.state.captchaAutoLoginAttempts += 1;
        }
        int attempts = isTotp
                ? page.state.totpAutoLoginAttempts
                : page.state.captchaAutoLoginAttempts;
        if (attempts >= maximumAttempts) {
            pauseAutoLogin(page, phaseName, maximumAttempts, message);
            return;
        }
        page.state.status = "starting";
        page.state.message = message + "，将继续尝试" + phaseName + "（"
                + (attempts + 1) + "/" + maximumAttempts + "）";
        refreshOutputs();
        mainHandler.postDelayed(() -> attemptAutoLogin(page, page.webView.getUrl()), 1_500L);
    }

    private void pauseAutoLogin(
            ManagedPage page,
            String phaseName,
            int maximumAttempts,
            String detail
    ) {
        page.state.autoLoginInProgress = false;
        page.autoLoginStage = "";
        page.state.autoLoginCooldownUntil = System.currentTimeMillis() + AUTO_LOGIN_COOLDOWN_MS;
        page.state.status = "auth";
        page.state.message = phaseName + "已连续失败 " + maximumAttempts + " 次"
                + (detail == null || detail.isEmpty() ? "" : "（" + detail + "）")
                + "，请人工处理；自动登录暂停至 "
                + formatTime(page.state.autoLoginCooldownUntil) + "。";
        refreshOutputs();
    }

    private void completeAutoLogin(ManagedPage page, String token) {
        resetAutoLogin(page);
        page.state.needsImmediateScan = true;
        if (token != null && !token.isEmpty()) {
            credentialStore.updateToken(page.state.module.id, token);
        }
        persistCurrentToken(page);
        page.state.status = "starting";
        page.state.message = "自动登录成功，正在恢复监控";
        refreshOutputs();
        String currentUrl = page.webView.getUrl();
        if (!sameOrigin(page.state.module.url, currentUrl)) {
            page.webView.loadUrl(page.state.module.url);
            return;
        }
        mainHandler.postDelayed(() -> scan(page.state.module.id), 900L);
    }

    private void resetAutoLogin(ManagedPage page) {
        page.state.captchaAutoLoginAttempts = 0;
        page.state.totpAutoLoginAttempts = 0;
        page.state.autoLoginInProgress = false;
        page.autoLoginStage = "";
        page.state.autoLoginCooldownUntil = 0;
        if (page.autoLoginOutcome != null) mainHandler.removeCallbacks(page.autoLoginOutcome);
        page.autoLoginOutcome = null;
    }

    private void refreshCaptcha(ManagedPage page) {
        runPageAutomation(
                page,
                "globalThis.smsLoginAutomation.refreshCaptcha()",
                (value, error) -> { }
        );
    }

    private void persistCurrentToken(ManagedPage page) {
        if (credentialStore.get(page.state.module.id) == null) return;
        runPageAutomation(
                page,
                "globalThis.smsLoginAutomation.extractToken()",
                (value, error) -> {
                    String token = error.isEmpty() && value instanceof String ? (String) value : "";
                    if (!token.isEmpty()) {
                        credentialStore.updateToken(page.state.module.id, token);
                    } else {
                        persistCookieToken(page);
                    }
                }
        );
    }

    private void persistCookieToken(ManagedPage page) {
        String currentUrl = page.webView.getUrl();
        if (currentUrl == null || currentUrl.isEmpty()) return;
        String header = CookieManager.getInstance().getCookie(currentUrl);
        if (header == null || header.isEmpty()) return;
        for (String item : header.split(";")) {
            String[] parts = item.trim().split("=", 2);
            if (parts.length == 2 && "token".equalsIgnoreCase(parts[0].trim())
                    && parts[1].trim().length() > 12) {
                credentialStore.updateToken(page.state.module.id, parts[1].trim());
                return;
            }
        }
    }

    private void runPageAutomation(
            ManagedPage page,
            String expression,
            PageAutomationCallback callback
    ) {
        page.pageAutomationToken = UUID.randomUUID().toString();
        page.pageAutomationPollCount = 0;
        String token = JSONObject.quote(page.pageAutomationToken);
        String script = "(function(){try{" + loginAutomationSource
                + "window.__smsAutoLoginResult=null;"
                + "Promise.resolve(" + expression + ").then(function(result){"
                + "window.__smsAutoLoginResult=JSON.stringify({token:" + token + ",result:result});"
                + "}).catch(function(error){window.__smsAutoLoginResult=JSON.stringify({token:" + token
                + ",error:String(error&&error.message||error)});});"
                + "return true;}catch(error){window.__smsAutoLoginResult=JSON.stringify({token:" + token
                + ",error:String(error&&error.message||error)});return false;}})()";
        page.webView.evaluateJavascript(script, ignored -> mainHandler.postDelayed(
                () -> pollPageAutomation(page, callback),
                AUTO_LOGIN_POLL_MS
        ));
    }

    private void pollPageAutomation(ManagedPage page, PageAutomationCallback callback) {
        String expectedToken = page.pageAutomationToken;
        if (expectedToken == null) return;
        page.pageAutomationPollCount += 1;
        if (page.pageAutomationPollCount > MAX_AUTO_LOGIN_POLLS) {
            page.pageAutomationToken = null;
            callback.complete(null, "登录页面操作超过 24 秒");
            return;
        }
        page.webView.evaluateJavascript("window.__smsAutoLoginResult || null", value -> {
            try {
                String payload = decodeJavascriptString(value);
                if (payload == null || payload.isEmpty()) {
                    mainHandler.postDelayed(
                            () -> pollPageAutomation(page, callback),
                            AUTO_LOGIN_POLL_MS
                    );
                    return;
                }
                JSONObject envelope = new JSONObject(payload);
                if (!expectedToken.equals(envelope.optString("token"))) {
                    mainHandler.postDelayed(
                            () -> pollPageAutomation(page, callback),
                            AUTO_LOGIN_POLL_MS
                    );
                    return;
                }
                page.pageAutomationToken = null;
                page.webView.evaluateJavascript("window.__smsAutoLoginResult=null", null);
                String error = envelope.optString("error");
                Object result = envelope.opt("result");
                if (result == JSONObject.NULL) result = null;
                callback.complete(result, error);
            } catch (Exception exception) {
                page.pageAutomationToken = null;
                callback.complete(null, "登录页面结果无法识别：" + exception.getMessage());
            }
        });
    }

    private String loginUrl(String value) {
        Uri uri = Uri.parse(value);
        return uri.buildUpon().path("/login").clearQuery().build().toString();
    }

    private MonitorSnapshot buildSnapshot() {
        List<ModuleState> states = new ArrayList<>(pages.size());
        int alerts = 0;
        int healthy = 0;
        int authentication = 0;
        int errors = 0;
        for (ManagedPage page : pages.values()) {
            ModuleState copy = new ModuleState(page.state);
            states.add(copy);
            if (copy.isAlert()) alerts += 1;
            if ("healthy".equals(copy.status)) healthy += 1;
            if ("auth".equals(copy.status)) authentication += 1;
            if ("error".equals(copy.status)) errors += 1;
        }
        ModuleState focus = selectFocus(states);
        return new MonitorSnapshot(
                states,
                focus,
                alerts,
                healthy,
                authentication,
                errors,
                sampleLimit,
                MIN_SAMPLE_LIMIT,
                MAX_SAMPLE_LIMIT
        );
    }

    private ModuleState selectFocus(List<ModuleState> states) {
        ModuleState bestAlert = null;
        ModuleState bestMetric = null;
        ModuleState authentication = null;
        ModuleState error = null;
        for (ModuleState state : states) {
            if (state.hasMetrics && state.sampleCount > 0) {
                if (bestMetric == null || compareMetric(state, bestMetric) < 0) bestMetric = state;
                if (state.isAlert() && (bestAlert == null || compareMetric(state, bestAlert) < 0)) {
                    bestAlert = state;
                }
            } else if (authentication == null && "auth".equals(state.status)) {
                authentication = state;
            } else if (error == null && "error".equals(state.status)) {
                error = state;
            }
        }
        if (bestAlert != null) return bestAlert;
        if (bestMetric != null) return bestMetric;
        if (authentication != null) return authentication;
        if (error != null) return error;
        return states.isEmpty() ? null : states.get(0);
    }

    private int compareMetric(ModuleState left, ModuleState right) {
        int rate = Double.compare(left.successRate, right.successRate);
        return rate != 0 ? rate : left.module.id.compareTo(right.module.id);
    }

    private void refreshOutputs() {
        MonitorSnapshot snapshot = buildSnapshot();
        for (Listener listener : new ArrayList<>(listeners)) {
            listener.onMonitorSnapshot(snapshot);
        }
        notificationManager.notify(
                FOREGROUND_NOTIFICATION_ID,
                buildForegroundNotification(snapshot.focus == null ? null : foregroundText(snapshot.focus))
        );
        updateOverlay(snapshot);
    }

    private String foregroundText(ModuleState focus) {
        if (focus.hasMetrics) {
            return focus.module.name + " " + focus.percentageText()
                    + " · 成功 " + focus.successCount + "/" + focus.sampleCount;
        }
        return focus.module.name + " · " + focus.message;
    }

    private void notifyAlertIfNeeded(ModuleState state) {
        if (!state.isAlert()) {
            alertSignatures.remove(state.module.id);
            return;
        }
        String signature = state.successCount + "/" + state.sampleCount;
        if (signature.equals(alertSignatures.get(state.module.id))) return;
        alertSignatures.put(state.module.id, signature);

        Intent openIntent = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("module-id", state.module.id)
                .putExtra("show-overview", true);
        PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                state.module.id.hashCode(),
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
        Notification notification = new Notification.Builder(this, ALERT_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_monitor)
                .setColor(getColor(R.color.alert_red))
                .setContentTitle(state.module.name + " 短信成功率报警")
                .setContentText("最新 " + state.sampleCount + " 条成功 " + state.successCount
                        + " 条，成功率 " + state.percentageText() + "，低于 50%。")
                .setStyle(new Notification.BigTextStyle().bigText(
                        state.module.name + "：最新 " + state.sampleCount + " 条短信中成功 "
                                + state.successCount + " 条，未成功 " + state.nonSuccessCount
                                + " 条，成功率 " + state.percentageText() + "，低于 50%。"
                ))
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_ALARM)
                .build();
        try {
            notificationManager.notify(ALERT_NOTIFICATION_BASE + Math.abs(state.module.id.hashCode() % 500), notification);
        } catch (SecurityException ignored) {
            // Android 13+ may have notifications disabled while the overlay remains active.
        }
    }

    private void createNotificationChannels() {
        NotificationChannel monitorChannel = new NotificationChannel(
                MONITOR_CHANNEL_ID,
                getString(R.string.monitor_channel),
                NotificationManager.IMPORTANCE_LOW
        );
        monitorChannel.setDescription("保持每分钟短信成功率扫描持续运行");
        monitorChannel.setShowBadge(false);

        NotificationChannel alertChannel = new NotificationChannel(
                ALERT_CHANNEL_ID,
                getString(R.string.alert_channel),
                NotificationManager.IMPORTANCE_HIGH
        );
        alertChannel.setDescription("成功率低于 50% 时报警");
        alertChannel.enableVibration(true);
        notificationManager.createNotificationChannel(monitorChannel);
        notificationManager.createNotificationChannel(alertChannel);
    }

    private Notification buildForegroundNotification(String text) {
        Intent intent = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                1,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
        return new Notification.Builder(this, MONITOR_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_monitor)
                .setColor(getColor(R.color.brand_green))
                .setContentTitle("短信成功率监控运行中")
                .setContentText(text == null ? "扫描最新 " + sampleLimit + " 条 · 每 1 分钟" : text)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build();
    }

    private void startForegroundMonitor(Notification notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                    FOREGROUND_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            );
        } else {
            startForeground(FOREGROUND_NOTIFICATION_ID, notification);
        }
    }

    public boolean isOverlayEnabled() {
        return overlayEnabled;
    }

    public void setOverlayEnabled(boolean enabled) {
        overlayEnabled = enabled;
        preferences.edit().putBoolean("overlay-enabled", enabled).apply();
        updateOverlay(buildSnapshot());
    }

    private void updateOverlay(MonitorSnapshot snapshot) {
        if (!overlayEnabled || !Settings.canDrawOverlays(this)) {
            removeOverlay();
            return;
        }
        if (overlayView == null) createOverlay();
        if (overlayView != null) {
            overlayView.setMonitorState(
                    snapshot.focus,
                    snapshot.alertCount,
                    snapshot.authenticationCount
            );
        }
    }

    private void createOverlay() {
        overlayView = new GaugeView(this);
        overlayParams = new WindowManager.LayoutParams(
                dp(228),
                dp(236),
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                android.graphics.PixelFormat.TRANSLUCENT
        );
        overlayParams.gravity = Gravity.TOP | Gravity.START;
        overlayParams.x = preferences.getInt("overlay-x", dp(12));
        overlayParams.y = preferences.getInt("overlay-y", dp(96));
        configureOverlayTouch();
        try {
            windowManager.addView(overlayView, overlayParams);
        } catch (RuntimeException error) {
            overlayView = null;
            overlayParams = null;
        }
    }

    private void configureOverlayTouch() {
        final float[] startTouch = new float[2];
        final int[] startPosition = new int[2];
        final boolean[] dragged = new boolean[1];
        overlayView.setOnTouchListener((view, event) -> {
            if (overlayParams == null) return false;
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                startTouch[0] = event.getRawX();
                startTouch[1] = event.getRawY();
                startPosition[0] = overlayParams.x;
                startPosition[1] = overlayParams.y;
                dragged[0] = false;
                return true;
            }
            if (event.getAction() == MotionEvent.ACTION_MOVE) {
                float deltaX = event.getRawX() - startTouch[0];
                float deltaY = event.getRawY() - startTouch[1];
                if (Math.abs(deltaX) > dp(5) || Math.abs(deltaY) > dp(5)) dragged[0] = true;
                overlayParams.x = Math.max(0, startPosition[0] + Math.round(deltaX));
                overlayParams.y = Math.max(0, startPosition[1] + Math.round(deltaY));
                windowManager.updateViewLayout(overlayView, overlayParams);
                return true;
            }
            if (event.getAction() == MotionEvent.ACTION_UP) {
                preferences.edit()
                        .putInt("overlay-x", overlayParams.x)
                        .putInt("overlay-y", overlayParams.y)
                        .apply();
                if (!dragged[0]) {
                    view.performClick();
                    openDashboard();
                }
                return true;
            }
            return false;
        });
    }

    private void openDashboard() {
        Intent intent = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                .putExtra("show-overview", true);
        startActivity(intent);
    }

    private void removeOverlay() {
        if (overlayView == null) return;
        try {
            windowManager.removeView(overlayView);
        } catch (RuntimeException ignored) {
        }
        overlayView = null;
        overlayParams = null;
    }

    private boolean isAuthenticationUrl(String value) {
        if (value == null) return false;
        String path = Uri.parse(value).getPath();
        return "/login".equals(path) || "/ga-auth".equals(path) || "/unlock-ip".equals(path);
    }

    private boolean sameOrigin(String expected, String actual) {
        if (expected == null || actual == null) return false;
        Uri left = Uri.parse(expected);
        Uri right = Uri.parse(actual);
        return equal(left.getScheme(), right.getScheme())
                && equal(left.getHost(), right.getHost())
                && left.getPort() == right.getPort();
    }

    private boolean equal(String left, String right) {
        return left == null ? right == null : left.equalsIgnoreCase(right);
    }

    private String readAsset(String name) throws Exception {
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                getAssets().open(name), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) output.append(line).append('\n');
        }
        return output.toString();
    }

    private String decodeJavascriptString(String value) throws Exception {
        if (value == null || "null".equals(value)) return null;
        Object decoded = new JSONTokener(value).nextValue();
        if (decoded == null || decoded == JSONObject.NULL) return null;
        return decoded instanceof String ? (String) decoded : String.valueOf(decoded);
    }

    public String formatTime(long value) {
        if (value <= 0) return "--";
        return new SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(new Date(value));
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
