/* hk-wheel :: nui/bridge.js
 *
 * The transport. This page runs inside FiveM's CEF (NUI). CEF CAN open a
 * WebSocket to 127.0.0.1 (localhost is allowed), which the game's Lua CANNOT do
 * natively — that's the whole reason the bridge lives here.
 *
 * Flow:
 *   companion app  ⇄  (WebSocket, localhost)  ⇄  THIS page  ⇄  (NUI msgs)  ⇄  Lua
 *
 *   • App → us: JSON wheel frames {t:"input", ...}. We forward to Lua via
 *     fetchNui('wheelFrame', frame). Lua reads it next game tick.
 *   • Lua → us: SendNUIMessage({type:"ffb"|"config"|"connect"|"disconnect"}).
 *     We relay to the app over the socket (FFB frames, handshake).
 *
 * The page is invisible and never focuses (no NUI focus grab) — pure data.
 */

'use strict';

const RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'hk-wheel';

let ws = null;
let cfg = { host: '127.0.0.1', port: 24897, reconnectMs: 2000, debug: false };
let reconnectTimer = null;
let connected = false;

function log(...a) { if (cfg.debug) console.log('[hk-wheel]', ...a); }

// POST a message back to the Lua side. Fire-and-forget; Lua caches the latest.
function toLua(event, data) {
    fetch(`https://${RES}/${event}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {}),
    }).catch(() => { /* NUI callback not registered yet — ignore */ });
}

function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        openSocket();
    }, cfg.reconnectMs);
}

function openSocket() {
    try { if (ws) { ws.onclose = null; ws.close(); } } catch (e) {}
    const url = `ws://${cfg.host}:${cfg.port}`;
    log('connecting', url);
    try {
        ws = new WebSocket(url);
    } catch (e) {
        log('ctor failed', e);
        scheduleReconnect();
        return;
    }

    ws.onopen = () => {
        connected = true;
        log('connected');
        // Handshake: tell the app who we are + request its device info.
        try { ws.send(JSON.stringify({ t: 'hello', from: 'hk-wheel', v: 1 })); } catch (e) {}
        toLua('bridgeState', { connected: true });
    };

    ws.onmessage = (ev) => {
        // App → game. Expect small JSON frames. Keep parsing cheap (high rate).
        let msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        if (!msg) return;

        // TYPED frames (our richer protocol, if the app ever sends them).
        if (msg.t === 'device') { toLua('wheelDevice', msg); return; }
        if (msg.t === 'bye')    { toLua('wheelDevice', { connected: false }); return; }
        if (msg.t === 'input')  { toLua('wheelFrame', msg); return; }

        // WheelBridge.exe FORMAT (2026-07-27): no `t` field. Sends
        //   { steering:-1..1, throttle:0..1, brake:0..1, buttons:[<pressed idx>...], timestamp }
        // Translate to the frame the Lua expects: rename steering->steer, pass buttons[] through
        // as `btns` (Lua maps indices -> shift/reverse/neutral/box/actions via its config). Detect
        // it by the presence of `steering` (the exe's key) or a numeric `buttons` array.
        if (msg.steering !== undefined || Array.isArray(msg.buttons)) {
            toLua('wheelFrame', {
                steer:    msg.steering,
                throttle: msg.throttle,
                brake:    msg.brake,
                btns:     Array.isArray(msg.buttons) ? msg.buttons : [],
                ts:       msg.timestamp,
            });
            // The exe never sends a device report; synthesize "device present" on first frame so
            // the Lua's staleness/active gate (Wheel.deviceUp) turns on.
            if (!window.__hkWheelDeviceUp) {
                window.__hkWheelDeviceUp = true;
                toLua('wheelDevice', { name: 'WheelBridge', connected: true });
            }
        }
    };

    ws.onerror = () => { log('ws error'); };

    ws.onclose = () => {
        if (connected) toLua('bridgeState', { connected: false });
        connected = false;
        window.__hkWheelDeviceUp = false;   // re-synthesize the device on the next reconnect
        ws = null;
        scheduleReconnect();
    };
}

// Lua → us (SendNUIMessage). Relay to the app, or reconfigure the socket.
window.addEventListener('message', (e) => {
    const d = e.data || {};
    if (d.type === 'config') {
        // Apply transport config from Config.lua and (re)open the socket.
        cfg.host = d.host || cfg.host;
        cfg.port = d.port || cfg.port;
        cfg.reconnectMs = d.reconnectMs || cfg.reconnectMs;
        cfg.debug = !!d.debug;
        openSocket();
    } else if (d.type === 'ffb') {
        // FFB frame from the sim → app. Drop if not connected (no queueing; latest wins).
        if (ws && connected) {
            try { ws.send(JSON.stringify({ t: 'ffb', f: d.f })); } catch (err) {}
        }
    } else if (d.type === 'appcfg') {
        // Push runtime config to the app (e.g. wheel range, gains changed in-game).
        if (ws && connected) {
            try { ws.send(JSON.stringify({ t: 'cfg', c: d.c })); } catch (err) {}
        }
    } else if (d.type === 'disconnect') {
        try { if (ws) { ws.onclose = null; ws.close(); ws = null; } } catch (err) {}
        connected = false;
    }
});

// The Lua side sends {type:'config'} on resource start to kick us off.
log('bridge.js loaded');
