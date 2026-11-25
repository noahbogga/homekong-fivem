// hk-documents portal — runs in a real browser (phone/PC), not in-game CEF.
// Uploads an image to the FiveM server's portal endpoint, which forwards to
// Zipline and marks the code claimable in-game.
(function () {
    'use strict';

    // ── Endpoint base ─────────────────────────────────────────────────────
    // The portal is opened in an external browser, so it must reach the FiveM
    // server's HTTP endpoint. If this page is served FROM that endpoint the
    // relative path works as-is. Otherwise set ENDPOINT to the public address,
    // e.g. 'https://docs.example.com' (a reverse-proxy to the fxserver port).
    const ENDPOINT = ''; // '' = same origin as this page

    // Shared secret required by the server's /portal-upload (server/sv_config.lua
    // PortalConfig.secret). MUST be kept identical to that value. This is served
    // to the browser, so it only blocks unauthenticated scanners/off-origin tools.
    const SECRET = 'CHANGE_ME_hk_documents_portal_secret';

    const $ = (s) => document.querySelector(s);
    const codeEl = $('#code'), drop = $('#drop'), fileEl = $('#file');
    const preview = $('#preview'), sendBtn = $('#send'), statusEl = $('#status');

    let imageData = null;   // data URL

    // i18n — baked-in zh-hk defaults; overwritten by /portal-i18n (which follows
    // the server's Config.Locale) so the portal page matches the in-game language.
    const T = {
        pp_title: '文件圖片上載',
        pp_sub: '輸入遊戲內顯示的代碼，然後選擇或貼上圖片。',
        pp_code_label: '上載代碼',
        pp_drop: '按此選擇 · 拖放 · 或 <b>貼上 (Ctrl+V)</b>',
        pp_btn_upload: '上載',
        pp_uploading: '正在上載…',
        pp_done: '✓ 已上載！請返回遊戲繼續。',
        pp_fail: '上載失敗：',
        pp_no_server: '無法連接伺服器，請檢查你的網絡連線。',
        pp_not_image: '這不是圖片。',
        pp_too_large: '圖片過大（上限 10 MB）。',
    };
    function applyStaticText() {
        document.title = 'HOMEKONG · ' + T.pp_title;
        const set = (sel, html) => { const el = $(sel); if (el) el.innerHTML = html; };
        set('#pp-title', T.pp_title);
        set('#pp-sub', T.pp_sub);
        set('#pp-code-label', T.pp_code_label);
        set('#pp-drop-text', T.pp_drop);
        set('#send', T.pp_btn_upload);
    }
    applyStaticText();   // render zh-hk immediately, then refine from the server

    function setStatus(msg, cls) { statusEl.textContent = msg || ''; statusEl.className = 'status' + (cls ? ' ' + cls : ''); }
    function refreshBtn() { sendBtn.disabled = !(imageData && codeEl.value.trim().length === 6); }

    codeEl.addEventListener('input', () => { codeEl.value = codeEl.value.toUpperCase(); refreshBtn(); });

    function loadFile(file) {
        if (!file || !file.type.startsWith('image/')) { setStatus(T.pp_not_image, 'err'); return; }
        if (file.size > 10 * 1024 * 1024) { setStatus(T.pp_too_large, 'err'); return; }
        const reader = new FileReader();
        reader.onload = () => {
            imageData = reader.result;
            preview.src = imageData; preview.classList.remove('hidden');
            setStatus(''); refreshBtn();
        };
        reader.readAsDataURL(file);
    }

    drop.addEventListener('click', () => fileEl.click());
    fileEl.addEventListener('change', () => loadFile(fileEl.files[0]));

    ['dragenter', 'dragover'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
    ['dragleave', 'drop'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.remove('over'); }));
    drop.addEventListener('drop', e => { if (e.dataTransfer.files[0]) loadFile(e.dataTransfer.files[0]); });

    // clipboard paste — this is the "cool" bit that in-game CEF can't do
    window.addEventListener('paste', e => {
        const items = (e.clipboardData || {}).items || [];
        for (const it of items) {
            if (it.type && it.type.startsWith('image/')) { loadFile(it.getAsFile()); return; }
        }
    });

    sendBtn.addEventListener('click', async () => {
        const code = codeEl.value.trim().toUpperCase();
        if (code.length !== 6 || !imageData) return;
        sendBtn.disabled = true; setStatus(T.pp_uploading);
        try {
            const res = await fetch(ENDPOINT + '/portal-upload', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ code, image: imageData, secret: SECRET }),
            });
            const j = await res.json();
            if (j && j.ok) {
                setStatus(T.pp_done, 'ok');
                preview.style.opacity = '0.5';
            } else {
                setStatus(T.pp_fail + ((j && j.error) || res.status), 'err');
                sendBtn.disabled = false;
            }
        } catch (err) {
            setStatus(T.pp_no_server, 'err');
            sendBtn.disabled = false;
        }
    });

    // Pull the active locale from the server and re-render static text. Silent
    // no-op on failure — the baked-in zh-hk defaults already rendered.
    (async () => {
        try {
            const res = await fetch(ENDPOINT + '/portal-i18n');
            const j = await res.json();
            if (j && j.ok && j.strings) {
                Object.assign(T, j.strings);
                applyStaticText();
                if (j.locale) document.documentElement.lang = j.locale;
            }
        } catch (e) { /* keep defaults */ }
    })();
})();
