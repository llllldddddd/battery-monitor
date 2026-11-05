package io.github.llllldddddd.battery;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.widget.FrameLayout;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * index.html in a WebView, Bluetooth through the Android BLE API (see app/bridge.js).
 * Everything except the GATT/scan callbacks runs on the main thread.
 */
@SuppressWarnings({"deprecation", "MissingPermission"})
public class MainActivity extends Activity {
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final int REQ_PERMS = 1, REQ_SAVE = 2;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, Integer> pending = new HashMap<>();
    private final List<Object[]> waitingForPerms = new ArrayList<>();
    private WebView web;
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private boolean scanning;
    private String saveText;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        BluetoothManager bm = (BluetoothManager) getSystemService(BLUETOOTH_SERVICE);
        adapter = bm != null ? bm.getAdapter() : null;

        FrameLayout root = new FrameLayout(this);
        web = new WebView(this);
        root.addView(web);
        setContentView(root);
        // Android 15 draws apps under the status and navigation bars
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets i = insets.getInsets(WindowInsets.Type.systemBars());
                v.setPadding(i.left, i.top, i.right, i.bottom);
            } else {
                v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                        insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });

        WebSettings ws = web.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "AndroidBle");

        // bridge.js must run before the page's own script; a fixed https origin keeps the
        // recorded history (IndexedDB). Nothing is loaded from the network.
        String html = asset("index.html").replaceFirst("<head>",
                java.util.regex.Matcher.quoteReplacement("<head>\n<script>" + asset("bridge.js") + "</script>"));
        web.loadDataWithBaseURL("https://battery.local/", html, "text/html", "utf-8", null);

        if (!hasPerms()) requestPermissions(perms(), REQ_PERMS);
    }

    @Override
    protected void onDestroy() {
        closeGatt();
        web.destroy();
        super.onDestroy();
    }

    private String asset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
            return out.toString("UTF-8");
        } catch (IOException e) {
            return "";
        }
    }

    private class Bridge {
        @JavascriptInterface
        public void post(String json) {
            main.post(() -> {
                try {
                    handle(new JSONObject(json));
                } catch (JSONException ignored) {
                }
            });
        }
    }

    // ---------- talking to the page ----------

    private void send(JSONObject m) {
        main.post(() -> web.evaluateJavascript("window.__ble && __ble.receive(" + m + ")", null));
    }

    private void reply(int id, Object value) {
        try {
            send(new JSONObject().put("id", id).put("ok", true).put("value", value == null ? JSONObject.NULL : value));
        } catch (JSONException ignored) {
        }
    }

    private void fail(int id, String error, String name) {
        try {
            send(new JSONObject().put("id", id).put("ok", false).put("error", error).put("name", name));
        } catch (JSONException ignored) {
        }
    }

    private void fail(int id, String error) {
        fail(id, error, "NetworkError");
    }

    private void finish(String key, String error) {
        Integer id = pending.remove(key);
        if (id == null) return;
        if (error == null) reply(id, null);
        else fail(id, error);
    }

    private void failAll(String error) {
        for (int id : pending.values()) fail(id, error);
        pending.clear();
    }

    // ---------- permissions ----------

    private String[] perms() {
        return Build.VERSION.SDK_INT >= 31
                ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT}
                : new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }

    private boolean hasPerms() {
        for (String p : perms())
            if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) return false;
        return true;
    }

    private void ready(int id, Runnable run) {
        if (adapter == null) {
            fail(id, "На телефоне нет Bluetooth");
        } else if (!hasPerms()) {
            waitingForPerms.add(new Object[]{id, run});
            if (waitingForPerms.size() == 1) requestPermissions(perms(), REQ_PERMS);
        } else if (!adapter.isEnabled()) {
            fail(id, "Bluetooth выключен");
            startActivity(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE));
        } else {
            run.run();
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        List<Object[]> queued = new ArrayList<>(waitingForPerms);
        waitingForPerms.clear();
        for (Object[] q : queued) {
            if (hasPerms()) ready((Integer) q[0], (Runnable) q[1]);
            else fail((Integer) q[0], "Нет разрешения на Bluetooth. Включите его в настройках приложения.");
        }
    }

    // ---------- commands from bridge.js ----------

    private void handle(JSONObject m) {
        int id = m.optInt("id");
        switch (m.optString("cmd")) {
            case "scanStart":
                scanning = true;
                ready(id, () -> {
                    if (!scanning) return;
                    BluetoothLeScanner scanner = adapter.getBluetoothLeScanner();
                    if (scanner == null) {
                        fail(id, "Bluetooth выключен");
                        return;
                    }
                    scanner.startScan(null, new ScanSettings.Builder()
                            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback);
                    reply(id, null);
                });
                break;
            case "scanStop":
                if (scanning && hasPerms() && adapter.isEnabled() && adapter.getBluetoothLeScanner() != null)
                    adapter.getBluetoothLeScanner().stopScan(scanCallback);
                scanning = false;
                break;
            case "lastDevice": {
                SharedPreferences p = getPreferences(MODE_PRIVATE);
                String dev = p.getString("device", null);
                try {
                    reply(id, dev == null ? null : new JSONObject().put("device", dev).put("name", p.getString("name", "")));
                } catch (JSONException ignored) {
                }
                break;
            }
            case "connect":
                ready(id, () -> {
                    BluetoothDevice dev;
                    try {
                        dev = adapter.getRemoteDevice(m.optString("device"));
                    } catch (IllegalArgumentException e) {
                        fail(id, "Устройство не найдено", "NotFoundError");
                        return;
                    }
                    closeGatt();
                    pending.put("connect", id);
                    gatt = dev.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
                });
                break;
            case "disconnect":
                closeGatt();
                failAll("Отключено");
                break;
            case "service":
                if (gatt == null) fail(id, "Не подключено");
                else if (gatt.getService(UUID.fromString(m.optString("service"))) == null)
                    fail(id, "Нет нужного сервиса", "NotFoundError");
                else reply(id, null);
                break;
            case "characteristic": {
                BluetoothGattService svc = gatt == null ? null : gatt.getService(UUID.fromString(m.optString("service")));
                if (svc == null || svc.getCharacteristic(UUID.fromString(m.optString("char"))) == null)
                    fail(id, "Нет характеристики", "NotFoundError");
                else reply(id, null);
                break;
            }
            case "write": {
                BluetoothGattCharacteristic c = characteristic(m.optString("char"));
                if (c == null) {
                    fail(id, "Не подключено");
                    break;
                }
                JSONArray arr = m.optJSONArray("data");
                byte[] data = new byte[arr == null ? 0 : arr.length()];
                for (int i = 0; i < data.length; i++) data[i] = (byte) arr.optInt(i);
                boolean noResponse = !m.optBoolean("response")
                        && (c.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0;
                c.setWriteType(noResponse ? BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                        : BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
                c.setValue(data);
                pending.put("write", id);
                if (!gatt.writeCharacteristic(c)) finish("write", "Не удалось отправить запрос");
                break;
            }
            case "notify": {
                BluetoothGattCharacteristic c = characteristic(m.optString("char"));
                if (c == null) {
                    fail(id, "Не подключено");
                    break;
                }
                gatt.setCharacteristicNotification(c, true);
                BluetoothGattDescriptor d = c.getDescriptor(CCCD);
                if (d == null) {
                    reply(id, null);
                    break;
                }
                d.setValue((c.getProperties() & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
                        ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE);
                pending.put("notify", id);
                if (!gatt.writeDescriptor(d)) finish("notify", "Не удалось включить уведомления");
                break;
            }
            case "awake":
                // the web page did the same with a screen wake lock: Android stops apps when the screen is off
                if (m.optBoolean("on")) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                break;
            case "save": {
                saveText = m.optString("text");
                Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType("text/csv")
                        .putExtra(Intent.EXTRA_TITLE, m.optString("name", "battery.csv"));
                startActivityForResult(i, REQ_SAVE);
                break;
            }
        }
    }

    private BluetoothGattCharacteristic characteristic(String uuid) {
        if (gatt == null) return null;
        UUID want = UUID.fromString(uuid);
        for (BluetoothGattService s : gatt.getServices()) {
            BluetoothGattCharacteristic c = s.getCharacteristic(want);
            if (c != null) return c;
        }
        return null;
    }

    private void closeGatt() {
        if (gatt == null) return;
        gatt.disconnect();
        gatt.close();
        gatt = null;
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        if (code != REQ_SAVE || result != RESULT_OK || data == null || saveText == null) return;
        Uri uri = data.getData();
        try (OutputStream out = getContentResolver().openOutputStream(uri)) {
            out.write(saveText.getBytes(StandardCharsets.UTF_8));
            Toast.makeText(this, "Сохранено", Toast.LENGTH_SHORT).show();
        } catch (IOException | NullPointerException e) {
            Toast.makeText(this, "Не удалось сохранить файл", Toast.LENGTH_LONG).show();
        }
        saveText = null;
    }

    // ---------- Bluetooth callbacks (binder threads) ----------

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int type, ScanResult r) {
            ScanRecord rec = r.getScanRecord();
            String name = rec != null ? rec.getDeviceName() : null;
            if (name == null) {
                try {
                    name = r.getDevice().getName();
                } catch (SecurityException ignored) {
                }
            }
            JSONArray services = new JSONArray();
            if (rec != null && rec.getServiceUuids() != null)
                for (ParcelUuid u : rec.getServiceUuids()) services.put(u.toString());
            try {
                send(new JSONObject().put("event", "scan").put("device", r.getDevice().getAddress())
                        .put("name", name == null ? "" : name).put("services", services).put("rssi", r.getRssi()));
            } catch (JSONException ignored) {
            }
        }
    };

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            main.post(() -> {
                if (g != gatt) return;
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    g.discoverServices();
                    return;
                }
                g.close();
                gatt = null;
                finish("connect", "Не удалось подключиться (код " + status + ")");
                failAll("Связь потеряна");
                try {
                    send(new JSONObject().put("event", "disconnected").put("device", g.getDevice().getAddress()));
                } catch (JSONException ignored) {
                }
            });
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            main.post(() -> {
                if (g != gatt) return;
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    finish("connect", "Не удалось прочитать сервисы");
                    closeGatt();
                    return;
                }
                String name = "";
                try {
                    name = g.getDevice().getName();
                } catch (SecurityException ignored) {
                }
                getPreferences(MODE_PRIVATE).edit()
                        .putString("device", g.getDevice().getAddress())
                        .putString("name", name == null ? "" : name).apply();
                finish("connect", null);
            });
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            main.post(() -> finish("write", status == BluetoothGatt.GATT_SUCCESS ? null : "Ошибка записи " + status));
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
            main.post(() -> finish("notify", status == BluetoothGatt.GATT_SUCCESS ? null : "Ошибка подписки " + status));
        }

        // Only the old callback: Android 13+ calls both, and handling both would double every packet
        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            byte[] value = c.getValue();
            if (value == null) return;
            JSONArray data = new JSONArray();
            for (byte b : value) data.put(b & 0xff);
            try {
                send(new JSONObject().put("event", "notify").put("char", c.getUuid().toString()).put("data", data));
            } catch (JSONException ignored) {
            }
        }
    };
}
