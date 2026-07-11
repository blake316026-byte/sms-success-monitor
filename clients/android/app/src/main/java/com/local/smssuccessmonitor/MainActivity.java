package com.local.smssuccessmonitor;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.provider.Settings;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.webkit.WebView;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

@SuppressLint("SetTextI18n")
public final class MainActivity extends Activity implements MonitorService.Listener {
    private static final int COLOR_INK = Color.rgb(23, 26, 33);
    private static final int COLOR_PAPER = Color.rgb(245, 247, 250);
    private static final int COLOR_BORDER = Color.rgb(218, 223, 230);
    private static final int COLOR_BLUE = Color.rgb(25, 118, 210);
    private static final int COLOR_GREEN = Color.rgb(0, 166, 108);
    private static final int COLOR_RED = Color.rgb(230, 55, 80);
    private static final int COLOR_AMBER = Color.rgb(190, 121, 0);
    private static final int COLOR_MUTED = Color.rgb(104, 111, 124);

    private final Map<String, TextView> tabViews = new LinkedHashMap<>();
    private MonitorService monitorService;
    private boolean bound;
    private String selectedModuleId;
    private LinearLayout tabRow;
    private FrameLayout webContainer;
    private EditText addressBar;
    private ImageButton backButton;
    private ImageButton forwardButton;
    private TextView headerStatus;
    private TextView bottomStatus;
    private TextView overlayButton;
    private Dialog overviewDialog;
    private LinearLayout overviewContent;
    private MonitorService.MonitorSnapshot lastSnapshot;
    private boolean pendingOverlayEnable;
    private boolean pendingOverview;

    private final ServiceConnection serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            monitorService = ((MonitorService.LocalBinder) binder).getService();
            bound = true;
            monitorService.addListener(MainActivity.this);
            chooseInitialModule();
            attachSelectedPage();
            updateBrowserControls();
            maybePromptOverlayPermission();
            if (pendingOverlayEnable && Settings.canDrawOverlays(MainActivity.this)) {
                monitorService.setOverlayEnabled(true);
                pendingOverlayEnable = false;
            }
            if (pendingOverview) {
                pendingOverview = false;
                showOverview();
            }
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            bound = false;
            monitorService = null;
            bottomStatus.setText("监控服务连接已断开");
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        buildInterface();
        consumeIntent(getIntent());
        requestNotificationPermission();

        Intent serviceIntent = new Intent(this, MonitorService.class);
        startForegroundService(serviceIntent);
        bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        consumeIntent(intent);
        if (bound) {
            attachSelectedPage();
            if (pendingOverview) {
                pendingOverview = false;
                showOverview();
            }
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (pendingOverlayEnable && bound && Settings.canDrawOverlays(this)) {
            monitorService.setOverlayEnabled(true);
            pendingOverlayEnable = false;
            updateOverlayButton();
        }
    }

    @Override
    protected void onDestroy() {
        if (bound) {
            monitorService.detachPages(webContainer);
            monitorService.removeListener(this);
            unbindService(serviceConnection);
        }
        bound = false;
        super.onDestroy();
    }

    @Override
    public void onMonitorSnapshot(MonitorService.MonitorSnapshot snapshot) {
        runOnUiThread(() -> renderSnapshot(snapshot));
    }

    @Override
    public void onBackPressed() {
        if (overviewDialog != null && overviewDialog.isShowing()) {
            overviewDialog.dismiss();
            return;
        }
        if (bound && selectedModuleId != null && monitorService.canGoBack(selectedModuleId)) {
            monitorService.goBack(selectedModuleId);
            return;
        }
        super.onBackPressed();
    }

    private void buildInterface() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(COLOR_PAPER);
        root.addView(buildHeader(), matchWidth(dp(48)));
        root.addView(buildTabs(), matchWidth(dp(46)));
        root.addView(buildNavigationBar(), matchWidth(dp(50)));
        root.addView(buildActionBar(), matchWidth(dp(42)));

        webContainer = new FrameLayout(this);
        webContainer.setBackgroundColor(Color.WHITE);
        root.addView(webContainer, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
        ));

        bottomStatus = new TextView(this);
        bottomStatus.setGravity(Gravity.CENTER_VERTICAL);
        bottomStatus.setPadding(dp(12), 0, dp(12), 0);
        bottomStatus.setTextSize(12);
        bottomStatus.setTextColor(COLOR_MUTED);
        bottomStatus.setSingleLine(true);
        bottomStatus.setText("正在连接监控服务...");
        bottomStatus.setBackgroundColor(Color.WHITE);
        root.addView(bottomStatus, matchWidth(dp(34)));
        setContentView(root);
    }

    private View buildHeader() {
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(dp(14), 0, dp(12), 0);
        header.setBackgroundColor(COLOR_INK);

        TextView title = new TextView(this);
        title.setText("短信后台工作台");
        title.setTextSize(17);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setTextColor(Color.WHITE);
        header.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        headerStatus = new TextView(this);
        headerStatus.setText("连接中");
        headerStatus.setTextSize(12);
        headerStatus.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        headerStatus.setTextColor(Color.rgb(125, 206, 255));
        header.addView(headerStatus);
        return header;
    }

    private View buildTabs() {
        HorizontalScrollView scroller = new HorizontalScrollView(this);
        scroller.setFillViewport(false);
        scroller.setHorizontalScrollBarEnabled(false);
        scroller.setBackgroundColor(Color.WHITE);
        tabRow = new LinearLayout(this);
        tabRow.setOrientation(LinearLayout.HORIZONTAL);
        tabRow.setGravity(Gravity.CENTER_VERTICAL);
        tabRow.setPadding(dp(7), dp(5), dp(7), dp(5));
        scroller.addView(tabRow, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));
        return scroller;
    }

    private View buildNavigationBar() {
        LinearLayout navigation = new LinearLayout(this);
        navigation.setOrientation(LinearLayout.HORIZONTAL);
        navigation.setGravity(Gravity.CENTER_VERTICAL);
        navigation.setPadding(dp(6), dp(5), dp(6), dp(5));
        navigation.setBackgroundColor(Color.rgb(237, 241, 246));

        backButton = iconButton(android.R.drawable.ic_media_previous, "后退");
        backButton.setOnClickListener(view -> {
            if (bound) monitorService.goBack(selectedModuleId);
        });
        navigation.addView(backButton, square(dp(38)));

        forwardButton = iconButton(android.R.drawable.ic_media_next, "前进");
        forwardButton.setOnClickListener(view -> {
            if (bound) monitorService.goForward(selectedModuleId);
        });
        navigation.addView(forwardButton, square(dp(38)));

        ImageButton reload = iconButton(android.R.drawable.ic_popup_sync, "刷新后台页面");
        reload.setOnClickListener(view -> {
            if (bound) monitorService.reload(selectedModuleId);
        });
        navigation.addView(reload, square(dp(38)));

        addressBar = new EditText(this);
        addressBar.setSingleLine(true);
        addressBar.setTextSize(12);
        addressBar.setTextColor(COLOR_INK);
        addressBar.setHintTextColor(Color.rgb(145, 151, 162));
        addressBar.setHint("后台地址");
        addressBar.setPadding(dp(10), 0, dp(10), 0);
        addressBar.setSelectAllOnFocus(false);
        addressBar.setImeOptions(EditorInfo.IME_ACTION_GO);
        addressBar.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        addressBar.setBackground(rounded(Color.WHITE, COLOR_BORDER, 5));
        addressBar.setOnEditorActionListener((view, actionId, event) -> {
            boolean enter = event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER;
            if (actionId == EditorInfo.IME_ACTION_GO || enter) {
                if (bound) monitorService.navigate(selectedModuleId, addressBar.getText().toString());
                addressBar.clearFocus();
                return true;
            }
            return false;
        });
        LinearLayout.LayoutParams addressParams = new LinearLayout.LayoutParams(0, dp(38), 1f);
        addressParams.setMargins(dp(5), 0, 0, 0);
        navigation.addView(addressBar, addressParams);
        return navigation;
    }

    private View buildActionBar() {
        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        actions.setGravity(Gravity.CENTER_VERTICAL);
        actions.setPadding(dp(7), dp(3), dp(7), dp(3));
        actions.setBackgroundColor(Color.WHITE);

        TextView scanCurrent = actionButton("扫描当前", android.R.drawable.ic_popup_sync);
        scanCurrent.setOnClickListener(view -> {
            if (bound) monitorService.scan(selectedModuleId);
        });
        actions.addView(scanCurrent, actionParams());

        TextView scanAll = actionButton("扫描全部", android.R.drawable.ic_menu_rotate);
        scanAll.setOnClickListener(view -> {
            if (bound) monitorService.scanAll();
        });
        actions.addView(scanAll, actionParams());

        TextView overview = actionButton("监控总览", android.R.drawable.ic_menu_agenda);
        overview.setOnClickListener(view -> showOverview());
        actions.addView(overview, actionParams());

        overlayButton = actionButton("悬浮窗", android.R.drawable.ic_menu_view);
        overlayButton.setOnClickListener(view -> toggleOverlay());
        actions.addView(overlayButton, actionParams());
        return actions;
    }

    private void consumeIntent(Intent intent) {
        if (intent == null) return;
        String moduleId = intent.getStringExtra("module-id");
        if (moduleId != null && !moduleId.isEmpty()) selectedModuleId = moduleId;
        pendingOverview = pendingOverview || intent.getBooleanExtra("show-overview", false);
        intent.removeExtra("show-overview");
    }

    private void chooseInitialModule() {
        if (lastSnapshot == null || lastSnapshot.modules.isEmpty()) return;
        if (selectedModuleId == null || lastSnapshot.find(selectedModuleId) == null) {
            selectedModuleId = lastSnapshot.modules.get(0).module.id;
        }
    }

    private void selectModule(String id) {
        selectedModuleId = id;
        attachSelectedPage();
        renderSnapshot(lastSnapshot);
    }

    private void attachSelectedPage() {
        if (!bound || selectedModuleId == null) return;
        WebView webView = monitorService.attachPage(selectedModuleId, this, webContainer);
        if (webView == null) return;
        updateBrowserControls();
    }

    private void renderSnapshot(MonitorService.MonitorSnapshot snapshot) {
        if (snapshot == null) return;
        lastSnapshot = snapshot;
        chooseInitialModule();
        renderTabs(snapshot);

        ModuleState selected = snapshot.find(selectedModuleId);
        if (selected != null) {
            String status = selected.hasMetrics
                    ? selected.percentageText() + " · 成功 " + selected.successCount + "/" + selected.sampleCount
                    : selected.message;
            bottomStatus.setText(selected.module.name + " · " + status);
            bottomStatus.setTextColor(selected.isAlert() ? COLOR_RED
                    : "auth".equals(selected.status) ? COLOR_AMBER : COLOR_MUTED);
        }

        if (snapshot.alertCount > 0) {
            headerStatus.setText("报警 " + snapshot.alertCount);
            headerStatus.setTextColor(Color.rgb(255, 103, 125));
        } else if (snapshot.healthyCount > 0) {
            headerStatus.setText("正常 " + snapshot.healthyCount + " · 待登录 " + snapshot.authenticationCount);
            headerStatus.setTextColor(Color.rgb(65, 218, 158));
        } else {
            headerStatus.setText("待登录 " + snapshot.authenticationCount);
            headerStatus.setTextColor(Color.rgb(242, 178, 60));
        }
        updateBrowserControls();
        updateOverlayButton();
        if (overviewDialog != null && overviewDialog.isShowing()) populateOverview(snapshot);
    }

    private void renderTabs(MonitorService.MonitorSnapshot snapshot) {
        if (tabViews.isEmpty()) {
            for (ModuleState state : snapshot.modules) {
                TextView tab = new TextView(this);
                tab.setGravity(Gravity.CENTER);
                tab.setTextSize(12);
                tab.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
                tab.setMinWidth(dp(80));
                tab.setMaxLines(1);
                tab.setPadding(dp(10), 0, dp(10), 0);
                tab.setOnClickListener(view -> selectModule(state.module.id));
                LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                );
                params.setMargins(0, 0, dp(4), 0);
                tabRow.addView(tab, params);
                tabViews.put(state.module.id, tab);
            }
        }
        for (ModuleState state : snapshot.modules) {
            TextView tab = tabViews.get(state.module.id);
            if (tab == null) continue;
            boolean selected = state.module.id.equals(selectedModuleId);
            tab.setText(state.module.name);
            tab.setTextColor(selected ? Color.WHITE : statusColor(state));
            tab.setBackground(rounded(selected ? COLOR_BLUE : Color.WHITE,
                    selected ? COLOR_BLUE : COLOR_BORDER, 5));
            tab.setContentDescription(state.module.name + "，" + statusLabel(state));
        }
    }

    private void updateBrowserControls() {
        if (!bound || selectedModuleId == null) return;
        backButton.setEnabled(monitorService.canGoBack(selectedModuleId));
        forwardButton.setEnabled(monitorService.canGoForward(selectedModuleId));
        String currentUrl = monitorService.currentUrl(selectedModuleId);
        if (!addressBar.hasFocus() && currentUrl != null && !currentUrl.equals(addressBar.getText().toString())) {
            addressBar.setText(currentUrl);
        }
    }

    private void showOverview() {
        if (!bound || lastSnapshot == null) {
            Toast.makeText(this, "监控服务仍在连接", Toast.LENGTH_SHORT).show();
            pendingOverview = true;
            return;
        }
        if (overviewDialog != null && overviewDialog.isShowing()) {
            overviewDialog.dismiss();
        }

        overviewContent = new LinearLayout(this);
        overviewContent.setOrientation(LinearLayout.VERTICAL);
        overviewContent.setPadding(dp(18), dp(8), dp(18), dp(8));
        ScrollView scrollView = new ScrollView(this);
        scrollView.addView(overviewContent);

        overviewDialog = new AlertDialog.Builder(this)
                .setTitle("短信监控总览")
                .setView(scrollView)
                .setPositiveButton("扫描全部", (dialog, which) -> monitorService.scanAll())
                .setNeutralButton("悬浮窗", (dialog, which) -> toggleOverlay())
                .setNegativeButton("关闭", null)
                .create();
        overviewDialog.setOnDismissListener(dialog -> {
            overviewDialog = null;
            overviewContent = null;
        });
        populateOverview(lastSnapshot);
        overviewDialog.show();
    }

    private void populateOverview(MonitorService.MonitorSnapshot snapshot) {
        if (overviewContent == null) return;
        overviewContent.removeAllViews();

        TextView summary = new TextView(this);
        summary.setText("报警 " + snapshot.alertCount + "   正常 " + snapshot.healthyCount
                + "   待登录 " + snapshot.authenticationCount + "   异常 " + snapshot.errorCount);
        summary.setTextSize(14);
        summary.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        summary.setTextColor(snapshot.alertCount > 0 ? COLOR_RED : COLOR_INK);
        summary.setPadding(0, 0, 0, dp(12));
        overviewContent.addView(summary);

        LinearLayout heading = overviewRow();
        heading.addView(overviewCell("后台", 1.45f, true));
        heading.addView(overviewCell("状态", 0.75f, true));
        heading.addView(overviewCell("成功率", 0.75f, true));
        heading.addView(overviewCell("成功/样本", 1f, true));
        overviewContent.addView(heading, matchWidth(dp(34)));

        for (ModuleState state : snapshot.modules) {
            LinearLayout row = overviewRow();
            row.setBackground(rounded(
                    state.module.id.equals(selectedModuleId) ? Color.rgb(232, 242, 253) : Color.WHITE,
                    COLOR_BORDER,
                    3
            ));
            row.setOnClickListener(view -> {
                selectModule(state.module.id);
                if (overviewDialog != null) overviewDialog.dismiss();
            });
            TextView name = overviewCell(state.module.name, 1.45f, false);
            name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
            row.addView(name);
            TextView status = overviewCell(statusLabel(state), 0.75f, false);
            status.setTextColor(statusColor(state));
            row.addView(status);
            TextView rate = overviewCell(state.percentageText(), 0.75f, false);
            rate.setTextColor(state.isAlert() ? COLOR_RED : COLOR_INK);
            row.addView(rate);
            row.addView(overviewCell(state.hasMetrics
                    ? state.successCount + "/" + state.sampleCount : "--/--", 1f, false));
            LinearLayout.LayoutParams rowParams = matchWidth(dp(42));
            rowParams.setMargins(0, 0, 0, dp(4));
            overviewContent.addView(row, rowParams);
        }

        ModuleState focus = snapshot.focus;
        TextView footer = new TextView(this);
        footer.setPadding(0, dp(10), 0, dp(8));
        footer.setTextSize(12);
        footer.setTextColor(COLOR_MUTED);
        if (focus == null) footer.setText("等待平台连接");
        else if (focus.hasMetrics) footer.setText("当前展示最低值：" + focus.module.name + " "
                + focus.percentageText() + " · 最近扫描 " + monitorService.formatTime(focus.scannedAt));
        else footer.setText("尚无已登录平台数据，点击对应后台完成登录。\n未登录平台不会覆盖已有监控值。");
        overviewContent.addView(footer);
    }

    private void toggleOverlay() {
        if (!bound) return;
        if (!Settings.canDrawOverlays(this)) {
            pendingOverlayEnable = true;
            Intent intent = new Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())
            );
            startActivity(intent);
            return;
        }
        monitorService.setOverlayEnabled(!monitorService.isOverlayEnabled());
        updateOverlayButton();
    }

    private void updateOverlayButton() {
        if (overlayButton == null) return;
        boolean enabled = bound && Settings.canDrawOverlays(this) && monitorService.isOverlayEnabled();
        overlayButton.setText(enabled ? "悬浮已开" : "悬浮窗");
        overlayButton.setTextColor(enabled ? COLOR_GREEN : COLOR_INK);
    }

    private void maybePromptOverlayPermission() {
        if (Settings.canDrawOverlays(this)) {
            if (monitorService.isOverlayEnabled()) monitorService.setOverlayEnabled(true);
            return;
        }
        SharedPreferences preferences = getSharedPreferences("monitor-preferences", MODE_PRIVATE);
        if (preferences.getBoolean("overlay-prompted", false)) return;
        preferences.edit().putBoolean("overlay-prompted", true).apply();
        new AlertDialog.Builder(this)
                .setTitle("开启悬浮监控")
                .setMessage("授权后，成功率和报警会持续悬浮在其他应用上层。首次只需设置一次。")
                .setPositiveButton("去授权", (dialog, which) -> {
                    pendingOverlayEnable = true;
                    startActivity(new Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:" + getPackageName())
                    ));
                })
                .setNegativeButton("稍后", null)
                .show();
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1001);
        }
    }

    private ImageButton iconButton(int drawable, String description) {
        ImageButton button = new ImageButton(this);
        button.setImageResource(drawable);
        button.setColorFilter(COLOR_INK);
        button.setScaleType(ImageButton.ScaleType.CENTER_INSIDE);
        button.setPadding(dp(10), dp(10), dp(10), dp(10));
        button.setBackground(rounded(Color.WHITE, COLOR_BORDER, 5));
        button.setContentDescription(description);
        button.setTooltipText(description);
        return button;
    }

    private TextView actionButton(String label, int drawable) {
        TextView button = new TextView(this);
        button.setText(label);
        button.setTextSize(11);
        button.setTextColor(COLOR_INK);
        button.setGravity(Gravity.CENTER);
        button.setSingleLine(true);
        button.setCompoundDrawablePadding(dp(4));
        button.setCompoundDrawablesWithIntrinsicBounds(drawable, 0, 0, 0);
        button.setBackground(rounded(Color.WHITE, COLOR_BORDER, 5));
        button.setPadding(dp(5), 0, dp(5), 0);
        return button;
    }

    private LinearLayout overviewRow() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        return row;
    }

    private TextView overviewCell(String text, float weight, boolean heading) {
        TextView cell = new TextView(this);
        cell.setText(text);
        cell.setTextSize(heading ? 11 : 12);
        cell.setTextColor(heading ? COLOR_MUTED : COLOR_INK);
        cell.setGravity(Gravity.CENTER_VERTICAL);
        cell.setSingleLine(true);
        cell.setPadding(dp(6), 0, dp(4), 0);
        if (heading) cell.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        cell.setLayoutParams(new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight));
        return cell;
    }

    private int statusColor(ModuleState state) {
        if (state.isAlert()) return COLOR_RED;
        if (state.hasMetrics) return COLOR_GREEN;
        if ("auth".equals(state.status)) return COLOR_AMBER;
        if ("error".equals(state.status)) return COLOR_MUTED;
        return COLOR_BLUE;
    }

    private String statusLabel(ModuleState state) {
        if (state.isAlert()) return "报警";
        if (state.hasMetrics) return "正常";
        if ("auth".equals(state.status)) return "需登录";
        if ("error".equals(state.status)) return "异常";
        if ("scanning".equals(state.status)) return "扫描中";
        return "连接中";
    }

    private GradientDrawable rounded(int fill, int stroke, int radiusDp) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radiusDp));
        drawable.setStroke(dp(1), stroke);
        return drawable;
    }

    private LinearLayout.LayoutParams matchWidth(int height) {
        return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height);
    }

    private LinearLayout.LayoutParams square(int size) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(size, size);
        params.setMargins(0, 0, dp(4), 0);
        return params;
    }

    private LinearLayout.LayoutParams actionParams() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, dp(36), 1f);
        params.setMargins(0, 0, dp(5), 0);
        return params;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
