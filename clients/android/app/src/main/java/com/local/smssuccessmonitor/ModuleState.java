package com.local.smssuccessmonitor;

import java.util.Locale;

public final class ModuleState {
    public final ModuleConfig module;
    public String status = "starting";
    public String message = "等待连接";
    public boolean hasMetrics;
    public int sampleCount;
    public int successCount;
    public int nonSuccessCount;
    public double successRate;
    public long scannedAt;
    public long nextScanAt;
    public boolean scanning;
    public int consecutiveScanFailures;
    public int captchaAutoLoginAttempts;
    public int totpAutoLoginAttempts;
    public boolean autoLoginInProgress;
    public long autoLoginCooldownUntil;
    public boolean needsImmediateScan = true;

    ModuleState(ModuleConfig module) {
        this.module = module;
    }

    ModuleState(ModuleState source) {
        module = source.module;
        status = source.status;
        message = source.message;
        hasMetrics = source.hasMetrics;
        sampleCount = source.sampleCount;
        successCount = source.successCount;
        nonSuccessCount = source.nonSuccessCount;
        successRate = source.successRate;
        scannedAt = source.scannedAt;
        nextScanAt = source.nextScanAt;
        scanning = source.scanning;
        consecutiveScanFailures = source.consecutiveScanFailures;
        captchaAutoLoginAttempts = source.captchaAutoLoginAttempts;
        totpAutoLoginAttempts = source.totpAutoLoginAttempts;
        autoLoginInProgress = source.autoLoginInProgress;
        autoLoginCooldownUntil = source.autoLoginCooldownUntil;
        needsImmediateScan = source.needsImmediateScan;
    }

    void clearMetrics() {
        hasMetrics = false;
        sampleCount = 0;
        successCount = 0;
        nonSuccessCount = 0;
        successRate = 0;
    }

    public boolean isAlert() {
        return hasMetrics && sampleCount > 0 && successRate < 0.5d;
    }

    public String percentageText() {
        if (!hasMetrics || sampleCount == 0) return "--";
        double percentage = successRate * 100d;
        if (Math.abs(percentage - Math.rint(percentage)) < 0.0001d) {
            return String.format(Locale.US, "%.0f%%", percentage);
        }
        return String.format(Locale.US, "%.1f%%", percentage);
    }
}
