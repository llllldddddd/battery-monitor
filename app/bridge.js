// navigator.bluetooth for the Mac and Android apps: their web views have no Web Bluetooth,
// so the same page talks to the battery through the native side instead.
// Only the parts index.html uses are implemented. Native API: post({id, cmd, ...}),
// answers come back as __ble.receive({id, ok, value | error}) or events ({event, ...}).
(() => {
  const post = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ble
    ? (m) => window.webkit.messageHandlers.ble.postMessage(JSON.stringify(m))
    : window.AndroidBle ? (m) => window.AndroidBle.post(JSON.stringify(m)) : null;
  if (!post) return;

  let seq = 0;
  const calls = new Map();
  const devices = new Map();
  const chars = new Map();
  let chooser = null;

  function call(cmd, args, timeoutMs) {
    return new Promise((resolve, reject) => {
      const id = ++seq;
      const timer = timeoutMs ? setTimeout(() => {
        calls.delete(id);
        reject(new DOMException("Батарея не отвечает", "NetworkError"));
      }, timeoutMs) : null;
      calls.set(id, { resolve, reject, timer });
      post(Object.assign({ id, cmd }, args));
    });
  }

  const norm = (uuid) => String(uuid).toLowerCase();

  class Characteristic extends EventTarget {
    constructor(device, uuid) { super(); this.uuid = uuid; this._device = device; this.value = null; }
    _write(data, response) {
      const bytes = Array.from(data instanceof ArrayBuffer ? new Uint8Array(data)
        : new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
      return call("write", { char: this.uuid, data: bytes, response }, 5000);
    }
    writeValueWithoutResponse(data) { return this._write(data, false); }
    writeValue(data) { return this._write(data, true); }
    async startNotifications() { await call("notify", { char: this.uuid }, 5000); return this; }
  }

  class Service {
    constructor(device, uuid) { this.uuid = uuid; this._device = device; }
    async getCharacteristic(uuid) {
      uuid = norm(uuid);
      await call("characteristic", { service: this.uuid, char: uuid }, 10000);
      const c = new Characteristic(this._device, uuid);
      chars.set(uuid, c);
      return c;
    }
  }

  class Gatt {
    constructor(device) { this.device = device; this.connected = false; }
    async connect() {
      try { await call("connect", { device: this.device.id }, 20000); }
      catch (e) { post({ cmd: "disconnect" }); throw e; }
      this.connected = true;
      return this;
    }
    disconnect() {
      post({ cmd: "disconnect" });
      if (!this.connected) return;
      this.connected = false;
      this.device.dispatchEvent(new Event("gattserverdisconnected"));
    }
    async getPrimaryService(uuid) {
      uuid = norm(uuid);
      await call("service", { service: uuid }, 10000);
      return new Service(this.device, uuid);
    }
  }

  class Device extends EventTarget {
    constructor(id, name) { super(); this.id = id; this.name = name || ""; this.gatt = new Gatt(this); }
  }

  const deviceFor = (id, name) => {
    let d = devices.get(id);
    if (!d) devices.set(id, (d = new Device(id, name)));
    else if (name) d.name = name;
    return d;
  };

  function matches(found, options) {
    if (options.acceptAllDevices) return true;
    const services = (found.services || []).map(norm);
    return (options.filters || []).some((f) =>
      (f.namePrefix && found.name && found.name.startsWith(f.namePrefix))
      || (f.services && f.services.some((s) => services.includes(norm(s)))));
  }

  // Stand-in for Chrome's device picker
  function requestDevice(options) {
    if (chooser) chooser.cancel();
    return new Promise((resolve, reject) => {
      const box = document.createElement("div");
      box.style.cssText = "position:fixed;inset:0;z-index:100;background:rgba(0,0,0,.45);display:flex;"
        + "align-items:center;justify-content:center;padding:16px";
      box.innerHTML = `<div style="background:var(--card);color:var(--text);border-radius:16px;padding:18px;
          width:100%;max-width:420px;max-height:80vh;display:flex;flex-direction:column;gap:12px">
        <b style="font-size:17px">Выберите батарею</b>
        <div class="note" data-k="state">Ищу устройства…</div>
        <div data-k="list" style="overflow:auto;display:flex;flex-direction:column;gap:6px"></div>
        <button class="ghost" data-k="cancel">Отмена</button></div>`;
      const q = (k) => box.querySelector(`[data-k="${k}"]`);
      const seen = new Map();
      const finish = (dev) => {
        post({ cmd: "scanStop" });
        box.remove();
        chooser = null;
        if (dev) resolve(dev);
        else reject(new DOMException("Устройство не выбрано", "NotFoundError"));
      };
      chooser = {
        found(f) {
          if (!matches(f, options)) return;
          let row = seen.get(f.device);
          if (!row) {
            row = document.createElement("button");
            row.className = "ghost";
            row.style.cssText = "display:flex;justify-content:space-between;gap:12px;text-align:left";
            row.addEventListener("click", () => finish(deviceFor(f.device, f.name)));
            seen.set(f.device, row);
            q("list").appendChild(row);
            q("state").textContent = "Нажмите на устройство, чтобы подключиться";
          }
          row.innerHTML = "";
          const name = document.createElement("span");
          name.textContent = f.name || "Без имени";
          const rssi = document.createElement("span");
          rssi.style.opacity = ".6";
          rssi.textContent = f.rssi != null ? `${f.rssi} дБм` : "";
          row.append(name, rssi);
        },
        error(msg) { q("state").textContent = msg; },
        cancel() { finish(null); },
      };
      q("cancel").addEventListener("click", () => finish(null));
      document.body.appendChild(box);
      call("scanStart", {}).catch((e) => chooser && chooser.error(e.message));
    });
  }

  // previously connected battery, so the app can reconnect on start without the picker
  async function getDevices() {
    const last = await call("lastDevice", {});
    return last ? [deviceFor(last.device, last.name)] : [];
  }

  function receive(m) {
    if (m.id != null) {
      const c = calls.get(m.id);
      if (!c) return;
      calls.delete(m.id);
      clearTimeout(c.timer);
      if (m.ok) c.resolve(m.value);
      else c.reject(new DOMException(m.error || "Ошибка Bluetooth", m.name || "NetworkError"));
    } else if (m.event === "scan") {
      if (chooser) chooser.found(m);
    } else if (m.event === "notify") {
      const c = chars.get(norm(m.char));
      if (!c) return;
      c.value = new DataView(new Uint8Array(m.data).buffer);
      c.dispatchEvent(new Event("characteristicvaluechanged"));
    } else if (m.event === "disconnected") {
      const d = devices.get(m.device);
      if (d && d.gatt.connected) {
        d.gatt.connected = false;
        d.dispatchEvent(new Event("gattserverdisconnected"));
      }
    }
  }

  window.__ble = { receive };
  Object.defineProperty(navigator, "bluetooth", { value: { requestDevice, getDevices }, configurable: true });

  // On Android this keeps the screen on, on the Mac it keeps the computer from sleeping
  class WakeLockSentinel extends EventTarget {
    constructor() { super(); this.released = false; }
    async release() {
      if (this.released) return;
      this.released = true;
      post({ cmd: "awake", on: false });
      this.dispatchEvent(new Event("release"));
    }
  }
  Object.defineProperty(navigator, "wakeLock", {
    value: { request: async () => { post({ cmd: "awake", on: true }); return new WakeLockSentinel(); } },
    configurable: true,
  });

  window.nativeSave = (name, text) => post({ cmd: "save", name, text });
  window.isNativeApp = true;
})();
