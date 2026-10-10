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
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.LinkedHashMap;
import java.util.ArrayList;
import java.util.List;
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
    private MonitorService.MonitorSnapshot lastSnapshot;

    private final ServiceConnection serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            monitorService = ((MonitorService.LocalBinder) binder).getService();
            bound = true;
            monitorService.addListener(MainActivity.this);
            chooseInitialModule();
            attachSelectedPage();
            updateBrowserControls();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            bound = false;
            monitorService = null;
            bottomStatus.setText("页面服务连接已断开");
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        buildInterface();
        consumeIntent(getIntent());

        Intent serviceIntent = new Intent(this, MonitorService.class);
        bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        consumeIntent(intent);
        if (bound) {
            attachSelectedPage();
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
        bottomStatus.setText("正在连接页面服务...");
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
        title.setText("后台工作台");
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

        ImageButton credentials = iconButton(android.R.drawable.ic_lock_lock, "自动登录设置");
        credentials.setOnClickListener(view -> showLoginSettings());
        navigation.addView(credentials, square(dp(38)));

        ImageButton highlights = iconButton(android.R.drawable.ic_menu_edit, "自动高亮关键词");
        highlights.setOnClickListener(view -> showHighlightSettings());
        navigation.addView(highlights, square(dp(38)));

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

    private void consumeIntent(Intent intent) {
        if (intent == null) return;
        String moduleId = intent.getStringExtra("module-id");
        if (moduleId != null && !moduleId.isEmpty()) selectedModuleId = moduleId;
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
        if (selected != null) bottomStatus.setText(selected.module.name + " · " + selected.message);
        headerStatus.setText(snapshot.modules.size() + " 个后台");
        updateBrowserControls();
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

    private void showLoginSettings() {
        if (!bound || selectedModuleId == null || lastSnapshot == null) {
            Toast.makeText(this, "页面服务仍在连接", Toast.LENGTH_SHORT).show();
            return;
        }
        ModuleState state = lastSnapshot.find(selectedModuleId);
        if (state == null) return;
        LocalCredentialStore.Summary summary = monitorService.credentialSummary(selectedModuleId);

        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        form.setPadding(dp(20), dp(4), dp(20), 0);

        EditText username = new EditText(this);
        username.setHint("后台账号");
        username.setSingleLine(true);
        username.setText(summary.username);
        username.setInputType(android.text.InputType.TYPE_CLASS_TEXT);
        form.addView(username, matchWidth(dp(48)));

        EditText password = new EditText(this);
        password.setHint(summary.passwordConfigured ? "密码已保存，留空保持不变" : "后台密码");
        password.setSingleLine(true);
        password.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        form.addView(password, matchWidth(dp(48)));

        EditText totp = new EditText(this);
        totp.setHint(summary.totpConfigured
                ? "Google 密钥已保存，留空保持不变"
                : "Google 密钥（没有二次验证可留空）");
        totp.setSingleLine(true);
        totp.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        form.addView(totp, matchWidth(dp(48)));

        CheckBox clearTotp = new CheckBox(this);
        clearTotp.setText("清除已保存的 Google 密钥");
        clearTotp.setVisibility(summary.totpConfigured ? View.VISIBLE : View.GONE);
        form.addView(clearTotp, matchWidth(dp(38)));

        CheckBox enabled = new CheckBox(this);
        enabled.setText("Token 失效时自动登录");
        enabled.setChecked(summary.configured ? summary.autoLoginEnabled : true);
        form.addView(enabled, matchWidth(dp(38)));

        TextView localNotice = new TextView(this);
        localNotice.setText((summary.tokenConfigured ? "本地 Token：已加密保存\n" : "本地 Token：登录成功后自动保存\n")
                + "账号、密码、Google 密钥和 Token 只保存在本机 Keystore。");
        localNotice.setTextSize(12);
        localNotice.setTextColor(COLOR_MUTED);
        localNotice.setPadding(0, dp(8), 0, 0);
        form.addView(localNotice, matchWidth(dp(48)));

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(state.module.name + " 自动登录")
                .setView(form)
                .setPositiveButton("保存", null)
                .setNeutralButton("删除配置", null)
                .setNegativeButton("取消", null)
                .create();
        dialog.setOnShowListener(ignored -> {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
                String error = monitorService.saveCredentials(
                        selectedModuleId,
                        username.getText().toString(),
                        password.getText().toString(),
                        totp.getText().toString(),
                        clearTotp.isChecked(),
                        enabled.isChecked()
                );
                if (!error.isEmpty()) {
                    Toast.makeText(this, error, Toast.LENGTH_LONG).show();
                    return;
                }
                dialog.dismiss();
            });
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setEnabled(summary.configured);
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(view -> {
                monitorService.removeCredentials(selectedModuleId);
                dialog.dismiss();
            });
        });
        dialog.show();
    }

    private void showHighlightSettings() {
        if (!bound) {
            Toast.makeText(this, "页面服务仍在连接", Toast.LENGTH_SHORT).show();
            return;
        }
        MonitorService.HighlightSettings settings = monitorService.getHighlightSettings();
        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        form.setPadding(dp(20), dp(4), dp(20), 0);

        CheckBox enabled = new CheckBox(this);
        enabled.setText("启用自动高亮");
        enabled.setChecked(settings.enabled);
        form.addView(enabled, matchWidth(dp(42)));

        TextView termsLabel = new TextView(this);
        termsLabel.setText("关键词");
        termsLabel.setTextColor(COLOR_INK);
        termsLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        termsLabel.setPadding(0, dp(7), 0, dp(5));
        form.addView(termsLabel, matchWidth(dp(34)));

        EditText terms = new EditText(this);
        terms.setGravity(Gravity.TOP | Gravity.START);
        terms.setMinLines(7);
        terms.setMaxLines(12);
        terms.setHint("每行一个关键词");
        terms.setText(String.join("\n", settings.terms));
        terms.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        terms.setBackground(rounded(Color.WHITE, COLOR_BORDER, 5));
        terms.setPadding(dp(10), dp(8), dp(10), dp(8));
        form.addView(terms, matchWidth(dp(190)));

        TextView colorLabel = new TextView(this);
        colorLabel.setText("高亮颜色");
        colorLabel.setTextColor(COLOR_INK);
        colorLabel.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        colorLabel.setPadding(0, dp(12), 0, dp(6));
        form.addView(colorLabel, matchWidth(dp(38)));

        String[] colorValues = new String[]{"#fff176", "#ffb74d", "#81c784", "#64b5f6", "#f48fb1"};
        int[] colors = new int[]{
                Color.rgb(255, 241, 118), Color.rgb(255, 183, 77),
                Color.rgb(129, 199, 132), Color.rgb(100, 181, 246),
                Color.rgb(244, 143, 177)
        };
        String[] selectedColor = new String[]{settings.color};
        LinearLayout swatches = new LinearLayout(this);
        swatches.setOrientation(LinearLayout.HORIZONTAL);
        swatches.setGravity(Gravity.CENTER_VERTICAL);
        List<TextView> swatchViews = new ArrayList<>();
        for (int index = 0; index < colorValues.length; index++) {
            TextView swatch = new TextView(this);
            swatch.setTag(colorValues[index]);
            swatch.setContentDescription("高亮颜色 " + (index + 1));
            swatchViews.add(swatch);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(dp(34), dp(34));
            params.setMargins(0, 0, dp(10), 0);
            swatches.addView(swatch, params);
            int selectedIndex = index;
            swatch.setOnClickListener(view -> {
                selectedColor[0] = colorValues[selectedIndex];
                for (int item = 0; item < swatchViews.size(); item++) {
                    boolean selected = colorValues[item].equals(selectedColor[0]);
                    swatchViews.get(item).setBackground(rounded(
                            colors[item], selected ? COLOR_BLUE : COLOR_BORDER,
                            selected ? 17 : 15
                    ));
                }
            });
        }
        for (int index = 0; index < swatchViews.size(); index++) {
            boolean selected = colorValues[index].equals(selectedColor[0]);
            swatchViews.get(index).setBackground(rounded(
                    colors[index], selected ? COLOR_BLUE : COLOR_BORDER,
                    selected ? 17 : 15
            ));
        }
        form.addView(swatches, matchWidth(dp(42)));

        CheckBox wholeWords = new CheckBox(this);
        wholeWords.setText("仅匹配完整单词或词组");
        wholeWords.setChecked(settings.wholeWords);
        form.addView(wholeWords, matchWidth(dp(42)));

        ScrollView scrollView = new ScrollView(this);
        scrollView.addView(form);
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("自动高亮关键词")
                .setView(scrollView)
                .setPositiveButton("保存", null)
                .setNegativeButton("取消", null)
                .create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener(view -> {
                    String error = monitorService.saveHighlightSettings(
                            enabled.isChecked(),
                            terms.getText().toString(),
                            selectedColor[0],
                            wholeWords.isChecked()
                    );
                    if (!error.isEmpty()) {
                        Toast.makeText(this, error, Toast.LENGTH_LONG).show();
                        return;
                    }
                    dialog.dismiss();
                }));
        dialog.show();
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
