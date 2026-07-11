package com.local.smssuccessmonitor;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class ModuleConfig {
    public final String id;
    public final String name;
    public final String url;

    ModuleConfig(String id, String name, String url) {
        this.id = id;
        this.name = name;
        this.url = url;
    }

    public static List<ModuleConfig> load(Context context) throws Exception {
        StringBuilder json = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                context.getAssets().open("modules.json"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) json.append(line);
        }

        JSONArray array = new JSONArray(json.toString());
        List<ModuleConfig> modules = new ArrayList<>(array.length());
        for (int index = 0; index < array.length(); index += 1) {
            JSONObject item = array.getJSONObject(index);
            modules.add(new ModuleConfig(
                    item.getString("id"),
                    item.getString("name"),
                    item.getString("url")
            ));
        }
        return Collections.unmodifiableList(modules);
    }
}
