package com.local.smssuccessmonitor;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;
import android.view.animation.AccelerateDecelerateInterpolator;

public final class GaugeView extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private ModuleState focus;
    private int alertCount;
    private int authenticationCount;
    private float pulse;
    private ValueAnimator pulseAnimator;

    public GaugeView(Context context) {
        super(context);
        setLayerType(LAYER_TYPE_SOFTWARE, null);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    public void setMonitorState(ModuleState state, int alerts, int authentication) {
        focus = state == null ? null : new ModuleState(state);
        alertCount = alerts;
        authenticationCount = authentication;
        boolean shouldPulse = focus != null && focus.isAlert();
        if (shouldPulse && pulseAnimator == null) startPulse();
        if (!shouldPulse && pulseAnimator != null) stopPulse();
        updateDescription();
        invalidate();
    }

    @Override
    public boolean performClick() {
        super.performClick();
        return true;
    }

    private void startPulse() {
        pulseAnimator = ValueAnimator.ofFloat(0f, 1f);
        pulseAnimator.setDuration(620L);
        pulseAnimator.setRepeatCount(ValueAnimator.INFINITE);
        pulseAnimator.setRepeatMode(ValueAnimator.REVERSE);
        pulseAnimator.setInterpolator(new AccelerateDecelerateInterpolator());
        pulseAnimator.addUpdateListener(animation -> {
            pulse = (float) animation.getAnimatedValue();
            invalidate();
        });
        pulseAnimator.start();
    }

    private void stopPulse() {
        pulseAnimator.cancel();
        pulseAnimator = null;
        pulse = 0f;
    }

    private void updateDescription() {
        if (focus == null) {
            setContentDescription("短信成功率监控，等待连接");
            return;
        }
        String value = focus.hasMetrics ? focus.percentageText() : statusLabel(focus);
        setContentDescription(focus.module.name + "，" + value + "，点击打开监控详情");
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float width = getWidth();
        float height = getHeight();
        float inset = dp(5);
        int accent = accentColor();

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.rgb(20, 23, 30));
        paint.setShadowLayer(dp(9), 0, dp(3), 0x66000000);
        rect.set(inset, inset, width - inset, height - inset);
        canvas.drawRoundRect(rect, dp(7), dp(7), paint);
        paint.clearShadowLayer();

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(dp(focus != null && focus.isAlert() ? 2.2f + pulse : 1.2f));
        paint.setColor(withAlpha(accent, focus != null && focus.isAlert() ? (int) (155 + 100 * pulse) : 135));
        canvas.drawRoundRect(rect, dp(7), dp(7), paint);

        drawHeader(canvas, width, accent);
        drawGauge(canvas, width, accent);
        drawStatusBand(canvas, width, height, accent);
    }

    private void drawHeader(Canvas canvas, float width, int accent) {
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(accent);
        canvas.drawCircle(dp(20), dp(24), dp(3.3f), paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(dp(1.8f));
        rect.set(dp(13), dp(17), dp(27), dp(31));
        canvas.drawArc(rect, -55, 110, false, paint);
        rect.set(dp(9), dp(13), dp(31), dp(35));
        canvas.drawArc(rect, -48, 96, false, paint);

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.WHITE);
        paint.setTextSize(dp(15));
        paint.setFakeBoldText(true);
        String name = focus == null ? "短信监控" : fitText(focus.module.name, width - dp(100));
        canvas.drawText(name, dp(39), dp(29), paint);

        String badge;
        if (alertCount > 0) badge = "报警 " + alertCount;
        else if (authenticationCount > 0 && (focus == null || !focus.hasMetrics)) badge = "待登录 " + authenticationCount;
        else badge = "监控中";
        paint.setTextSize(dp(10));
        float badgeWidth = paint.measureText(badge) + dp(16);
        rect.set(width - badgeWidth - dp(13), dp(14), width - dp(13), dp(35));
        paint.setColor(withAlpha(accent, 55));
        canvas.drawRoundRect(rect, dp(5), dp(5), paint);
        paint.setColor(accent);
        canvas.drawText(badge, rect.left + dp(8), dp(28.5f), paint);
        paint.setFakeBoldText(false);
    }

    private void drawGauge(Canvas canvas, float width, int accent) {
        float centerX = width / 2f;
        float centerY = dp(119);
        float radius = dp(65);

        if (focus != null && focus.isAlert()) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(8 + pulse * 4));
            paint.setColor(withAlpha(accent, (int) (35 + pulse * 70)));
            canvas.drawCircle(centerX, centerY, radius + dp(2), paint);
        }

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(dp(10));
        paint.setColor(Color.rgb(53, 57, 66));
        canvas.drawCircle(centerX, centerY, radius, paint);

        if (focus != null && focus.hasMetrics) {
            rect.set(centerX - radius, centerY - radius, centerX + radius, centerY + radius);
            paint.setColor(accent);
            canvas.drawArc(rect, -90, Math.max(3f, (float) (360d * focus.successRate)), false, paint);
        }
        paint.setStrokeCap(Paint.Cap.BUTT);

        paint.setStyle(Paint.Style.FILL);
        paint.setTextAlign(Paint.Align.CENTER);
        paint.setColor(Color.WHITE);
        paint.setFakeBoldText(true);
        String primary = focus == null ? "等待" : focus.hasMetrics ? focus.percentageText() : statusLabel(focus);
        paint.setTextSize(dp(primary.length() > 5 ? 24 : 32));
        canvas.drawText(primary, centerX, centerY + dp(5), paint);

        paint.setFakeBoldText(false);
        paint.setColor(Color.rgb(193, 198, 208));
        paint.setTextSize(dp(13));
        String secondary;
        if (focus == null) secondary = "正在连接后台";
        else if (focus.hasMetrics) secondary = "样本 " + focus.sampleCount;
        else secondary = focus.message;
        secondary = fitText(secondary, radius * 1.65f);
        canvas.drawText(secondary, centerX, centerY + dp(32), paint);
        paint.setTextAlign(Paint.Align.LEFT);
    }

    private void drawStatusBand(Canvas canvas, float width, float height, int accent) {
        rect.set(dp(15), height - dp(42), width - dp(15), height - dp(14));
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(withAlpha(accent, 42));
        canvas.drawRoundRect(rect, dp(5), dp(5), paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(dp(1));
        paint.setColor(withAlpha(accent, 170));
        canvas.drawRoundRect(rect, dp(5), dp(5), paint);

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(accent);
        paint.setTextAlign(Paint.Align.CENTER);
        paint.setFakeBoldText(true);
        paint.setTextSize(dp(11));
        String status;
        if (focus == null) status = "等待后台连接";
        else if (focus.isAlert()) status = "低于 50% · 成功 " + focus.successCount + "/" + focus.sampleCount;
        else if (focus.hasMetrics) status = "成功率正常 · 成功 " + focus.successCount + "/" + focus.sampleCount;
        else status = focus.message;
        canvas.drawText(fitText(status, rect.width() - dp(14)), width / 2f, height - dp(23), paint);
        paint.setTextAlign(Paint.Align.LEFT);
        paint.setFakeBoldText(false);
    }

    private String statusLabel(ModuleState state) {
        if ("auth".equals(state.status)) return "需登录";
        if ("error".equals(state.status)) return "异常";
        if ("scanning".equals(state.status)) return "扫描中";
        return "连接中";
    }

    private int accentColor() {
        if (focus == null) return Color.rgb(64, 143, 238);
        if (focus.isAlert()) return Color.rgb(255, 77, 103);
        if (focus.hasMetrics) return Color.rgb(0, 197, 127);
        if ("auth".equals(focus.status)) return Color.rgb(230, 162, 32);
        if ("error".equals(focus.status)) return Color.rgb(158, 166, 180);
        return Color.rgb(64, 143, 238);
    }

    private String fitText(String value, float maxWidth) {
        if (value == null) return "";
        if (paint.measureText(value) <= maxWidth) return value;
        String ellipsis = "...";
        int end = value.length();
        while (end > 1 && paint.measureText(value.substring(0, end) + ellipsis) > maxWidth) end -= 1;
        return value.substring(0, end) + ellipsis;
    }

    private int withAlpha(int color, int alpha) {
        return Color.argb(Math.max(0, Math.min(255, alpha)), Color.red(color), Color.green(color), Color.blue(color));
    }

    private float dp(float value) {
        return value * getResources().getDisplayMetrics().density;
    }
}
