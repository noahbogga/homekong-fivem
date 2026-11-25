(function () {
    const RESOURCE = 'hk-hub';

    const overlay   = document.getElementById('overlay');
    const hubBody   = document.getElementById('hub-body');   // normal grid target
    const brandEl   = document.getElementById('brand-name'); // normal header brand
    const rail      = document.getElementById('rail');
    const railItems = document.getElementById('rail-items');  // minimal target
    const flyout    = document.getElementById('flyout');
    const flyoutTitle = document.getElementById('flyout-title');
    const flyoutClose = document.getElementById('flyout-close');
    const setBody   = document.getElementById('settings-body');
    const lawsBody  = document.getElementById('laws-body');
    const reportBody = document.getElementById('report-body');
    const keybindsBody = document.getElementById('keybinds-body');
    const squadBody = document.getElementById('squad-body');
    // buttons exist in both modes
    const btnCloseEls = [document.getElementById('btn-close'), document.getElementById('btn-close-rail')].filter(Boolean);
    const btnSetEls   = [document.getElementById('btn-settings'), document.getElementById('btn-settings-rail')].filter(Boolean);

    let items = [];       // flat list in render order (for keyboard nav)
    let focusIdx = 0;
    let isOpen = false;
    let settings = null;  // settings payload from Lua
    let view = 'grid';    // 'grid' | 'settings' | 'laws' | 'report' | 'squad'
    let reportBusy = false;  // true while a submit is in flight
    let keybinds = null;  // keybinds reference data (from the open payload)
    let menuMode = 'normal'; // 'normal' | 'minimal'
    let lawsData = null;  // cached laws.json
    let lawsActiveDoc = 0;
    let lawsQuery = '';
    let setTab = 'info';  // settings sub-tab: 'info' | 'hud'
    let lastInfo = null;  // cached getInfo result (re-applied on Info tab re-render)
    let lastAvatar = null; // cached avatar URL (re-applied on Info tab re-render)
    let hudTab = 'toggles'; // within HUD: 'toggles' | 'icons'
    let railKbd = false;  // minimal mode: keyboard nav keeps the rail expanded (labels visible) without needing hover

    function post(name, payload) {
        return fetch(`https://${RESOURCE}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload || {}),
        }).catch(() => {});
    }

    // Small shared API for the squad module (html/squad.js) so it can reuse the
    // NUI POST bridge + HTML escaper without duplicating them.
    window.HKHubAPI = {
        post: (name, payload) => post(name, payload),
        postJson: (name, payload) => fetch(`https://${RESOURCE}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload || {}),
        }).then((r) => r.json()).catch(() => null),
        esc: (s) => esc(s),
    };

    // Escape any string coming from config before injecting as HTML.
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }

    function renderBrand(brand) {
        // Normal header: HOME<accent>KONG</accent>. Rail badge = initials (static "HK").
        if (brand && brand.name && brandEl) {
            const n = String(brand.name);
            const mid = Math.ceil(n.length / 2);
            brandEl.innerHTML = esc(n.slice(0, mid)) + '<span class="accent">' + esc(n.slice(mid)) + '</span>';
        }
        const tagEl = document.getElementById('brand-tag');
        if (tagEl && brand && brand.tagline) tagEl.textContent = brand.tagline;
    }

    // Builds BOTH layouts (normal card grid + minimal rail) from one item list,
    // so switching mode is instant with no re-fetch.
    function render(list) {
        hubBody.innerHTML = '';
        railItems.innerHTML = '';
        items = [];

        // Group by section, preserving first-seen order.
        const order = [];
        const groups = {};
        list.forEach((it) => {
            const sec = it.section || '';
            if (!(sec in groups)) { groups[sec] = []; order.push(sec); }
            groups[sec].push(it);
        });

        const iconOf = (it) => (it.icon && it.icon.indexOf('fa-') === 0) ? it.icon : 'fa-circle';
        // Brand glyphs (discord, youtube…) live in Font Awesome's BRANDS style,
        // not solid. Detect them so the right style class is applied.
        const BRAND_ICONS = { 'fa-discord':1, 'fa-youtube':1, 'fa-twitch':1, 'fa-tiktok':1, 'fa-instagram':1, 'fa-x-twitter':1, 'fa-steam':1 };
        const iconStyleOf = (it) => BRAND_ICONS[iconOf(it)] ? 'fa-brands' : 'fa-solid';

        order.forEach((sec, si) => {
            // ----- NORMAL: a section with a card grid -----
            const section = document.createElement('section');
            section.className = 'section';
            if (sec) {
                const title = document.createElement('div');
                title.className = 'section-title';
                title.textContent = sec;
                section.appendChild(title);
            }
            const grid = document.createElement('div');
            grid.className = 'grid';
            section.appendChild(grid);
            hubBody.appendChild(section);

            // ----- MINIMAL: a divider between rail sections -----
            if (si > 0) {
                const div = document.createElement('div');
                div.className = 'rail-divider';
                railItems.appendChild(div);
            }

            groups[sec].forEach((it) => {
                const idx = items.length;
                items.push(it);

                // normal card
                const tile = document.createElement('div');
                tile.className = 'tile';
                tile.dataset.idx = idx;
                if (it.accent) tile.style.setProperty('--tile-accent', it.accent);
                tile.innerHTML =
                    '<div class="tile-icon"><i class="' + iconStyleOf(it) + ' ' + esc(iconOf(it)) + '"></i></div>' +
                    '<div class="tile-body">' +
                        '<div class="tile-label">' + esc(it.label || '') + '</div>' +
                        (it.zh ? '<div class="tile-zh">' + esc(it.zh) + '</div>' : '') +
                        (it.sub ? '<div class="tile-sub">' + esc(it.sub) + '</div>' : '') +
                    '</div>' +
                    '<div class="tile-go"><i class="fa-solid fa-chevron-right"></i></div>';
                tile.addEventListener('click', () => launch(idx));
                tile.addEventListener('mouseenter', () => setFocus(idx));
                grid.appendChild(tile);

                // minimal rail icon
                const btn = document.createElement('button');
                btn.className = 'rail-item';
                btn.dataset.idx = idx;
                if (it.accent) btn.style.setProperty('--tile-accent', it.accent);
                btn.dataset.tip = (it.label || '') + (it.zh ? '  ·  ' + it.zh : '');
                btn.innerHTML = '<i class="' + iconStyleOf(it) + ' ' + esc(iconOf(it)) + '"></i>' +
                    '<span class="rail-label">' + esc(it.label || '') +
                    (it.zh ? '<span class="rail-zh">' + esc(it.zh) + '</span>' : '') + '</span>';
                btn.addEventListener('click', () => launch(idx));
                btn.addEventListener('mouseenter', () => setFocus(idx));
                railItems.appendChild(btn);
            });
        });

        focusIdx = 0;
        setFocus(0);
    }

    // ---- Panel: two tabs (Info / Settings) ----
    function renderSettings(s) {
        setBody.innerHTML = '';

        const head = document.createElement('div');
        head.className = 'set-tabs';
        [['info', '玩家資訊 Info'], ['settings', '設定 Settings']].forEach(([id, label]) => {
            const t = document.createElement('div');
            t.className = 'set-tab' + (setTab === id ? ' active' : '');
            t.textContent = label;
            t.addEventListener('click', () => { setTab = id; renderSettings(s); });
            head.appendChild(t);
        });
        setBody.appendChild(head);

        const content = document.createElement('div');
        content.className = 'set-content';
        setBody.appendChild(content);

        if (setTab === 'settings') {
            renderSettingsInto(content, s);
        } else {
            renderInfoInto(content, s);
            // Re-apply cached info if we have it; otherwise fetch (first open).
            if (lastInfo) setInfo(lastInfo);
            if (lastAvatar) setAvatar(lastAvatar);
            post('getInfo');
        }
    }

    // ---- Settings tab: preferences (optimizer, speedo) + HUD (toggles/icons) ----
    function renderSettingsInto(container, s) {
        // Preferences group (optimizer + speedo + placeholders)
        const pg = document.createElement('div');
        pg.className = 'set-group';
        pg.innerHTML = '<div class="set-group-title">偏好 · PREFERENCES</div>';
        let hasPref = false;

        // Menu layout mode (normal card grid vs minimal icon rail)
        hasPref = true;
        pg.appendChild(buildModePref({
            label: 'Menu Style', zh: '選單樣式',
            desc: 'Normal = card menu · Minimal = slim icon rail.',
            modes: [
                { name: 'normal',  label: 'Full',    zh: '完整' },
                { name: 'minimal', label: 'Minimal', zh: '精簡 · Beta' },
            ],
            current: s.menuMode || 'normal',
        }, 'setMenuMode'));

        if (s.optimizer && s.optimizer.modes) { hasPref = true; pg.appendChild(buildModePref(s.optimizer, 'setOptimizerMode')); }
        if (s.speedo && s.speedo.modes)       { hasPref = true; pg.appendChild(buildModePref(s.speedo, 'setSpeedoMode')); }

        // Launch rows (open external menus like /armenu)
        (s.launchers || []).forEach((l) => {
            hasPref = true;
            const p = document.createElement('div');
            p.className = 'pref';
            const btn = document.createElement('button');
            btn.className = 'hud-action-btn';
            btn.textContent = l.btn || 'Open';
            btn.addEventListener('click', () => post('launchSettingCmd', { id: l.id }));
            p.innerHTML =
                '<div class="pref-head"><div class="pref-title">' + esc(l.label) +
                (l.zh ? '<span class="zh">' + esc(l.zh) + '</span>' : '') + '</div></div>' +
                (l.desc ? '<div class="pref-desc">' + esc(l.desc) + '</div>' : '');
            p.querySelector('.pref-head').appendChild(btn);
            pg.appendChild(p);
        });

        (s.placeholders || []).forEach((ph) => {
            hasPref = true;
            const p = document.createElement('div');
            p.className = 'pref' + (ph.soon ? ' disabled' : '');
            p.innerHTML =
                '<div class="pref-head"><div class="pref-title">' + esc(ph.label) +
                (ph.zh ? '<span class="zh">' + esc(ph.zh) + '</span>' : '') + '</div>' +
                (ph.soon ? '<span class="soon-badge">Soon</span>' : '') + '</div>' +
                (ph.desc ? '<div class="pref-desc">' + esc(ph.desc) + '</div>' : '');
            pg.appendChild(p);
        });
        if (hasPref) container.appendChild(pg);

        // Mobile / web access key (play the casino + sportsbook from a browser).
        container.appendChild(buildMobileAccessGroup());

        // hk-hud status-icon group (theme + per-icon mode/colour). This is the
        // real HUD (hk-hud); the ps-hud group below is legacy/retired.
        if (s.hkhud) container.appendChild(buildHkHudGroup(s.hkhud));

        // Minimap group (shape / on-foot) — drives hk-hud.
        if (s.minimap) container.appendChild(buildMinimapGroup(s.minimap));

        // Compass group (show / on-foot / follow / streets / pointer / degrees).
        if (s.compass) container.appendChild(buildCompassGroup(s.compass));

        // Crosshair group (only if hk-hud running)
        if (s.crosshair) container.appendChild(buildCrosshairGroup(s.crosshair));

        // (The old ps-hud HUD toggle group was removed — ps-hud is retired.
        //  Minimap + Compass groups above now own that functionality via hk-hud.)
    }

    // ---- Mobile / web access key group ----
    // Shows the player how to reach the browser/PWA Steak mirror. The key is
    // hidden by default; revealing requires a deliberate press+confirm, and a
    // Regenerate button resets the key AND all outside sessions if it leaks.
    function buildMobileAccessGroup() {
        const g = document.createElement('div');
        g.className = 'set-group';
        g.innerHTML = '<div class="set-group-title">流動版 · MOBILE ACCESS</div>';

        const p = document.createElement('div');
        p.className = 'pref';
        p.innerHTML =
            '<div class="pref-head"><div class="pref-title">Web / Mobile Login' +
            '<span class="zh">網頁登入</span></div></div>' +
            '<div class="pref-desc">Play the casino and sportsbook from your phone or a browser, even while offline. ' +
            'Go to <b>games.example.com</b>, enter your Login ID and 8-character key.</div>' +
            '<div class="mob-key-box">' +
              '<div class="mob-key-row"><span class="mob-key-label">Login ID</span>' +
                '<span class="mob-key-val" id="mob-login">— — —</span></div>' +
              '<div class="mob-key-row"><span class="mob-key-label">Access Key</span>' +
                '<span class="mob-key-val" id="mob-key">••••••••</span></div>' +
            '</div>' +
            '<div class="mob-key-warn" id="mob-warn">Keep this key private. Anyone with it can bet with your money.</div>' +
            '<div class="mob-key-actions">' +
              '<button class="hud-action-btn" id="mob-reveal">Show key</button>' +
              '<button class="hud-action-btn danger" id="mob-regen">Regenerate</button>' +
            '</div>' +
            '<div class="mob-key-status" id="mob-status"></div>';
        g.appendChild(p);

        wireMobileAccess(p);
        return g;
    }

    // Behaviour for the Mobile Access group: reveal (press+confirm) and regen.
    function wireMobileAccess(root) {
        const loginEl  = root.querySelector('#mob-login');
        const keyEl    = root.querySelector('#mob-key');
        const revealBtn= root.querySelector('#mob-reveal');
        const regenBtn = root.querySelector('#mob-regen');
        const statusEl = root.querySelector('#mob-status');
        let shown = false;      // is the key currently visible
        let confirmingReveal = false;
        let confirmingRegen = false;
        let cur = null;         // {loginId, key, ver}

        function setStatus(msg, cls) {
            statusEl.textContent = msg || '';
            statusEl.className = 'mob-key-status' + (cls ? ' ' + cls : '');
        }
        function paint() {
            loginEl.textContent = cur && cur.loginId ? cur.loginId : (cur === null ? '— — —' : 'not set');
            if (shown && cur && cur.key) {
                keyEl.textContent = cur.key;
                revealBtn.textContent = 'Hide key';
            } else {
                keyEl.textContent = cur && cur.key ? '••••••••' : 'not set';
                revealBtn.textContent = cur && cur.key ? 'Show key' : 'Create key';
            }
        }

        // Reveal / create flow.
        revealBtn.addEventListener('click', async () => {
            if (shown) { shown = false; confirmingReveal = false; paint(); setStatus(''); return; }
            if (!cur || !cur.key) {
                // No key yet — create one (a first regen).
                setStatus('Creating key…');
                const res = await HKHubAPI.postJson('regenMobileKey', {});
                if (res && res.ok && res.key) { cur = res.key; shown = true; paint(); setStatus('Key created. Keep it private.', 'ok'); }
                else setStatus(mobErr(res), 'err');
                return;
            }
            if (!confirmingReveal) {
                confirmingReveal = true;
                revealBtn.textContent = 'Tap again to reveal';
                setStatus('Make sure nobody is watching your screen.', 'warn');
                setTimeout(() => { if (confirmingReveal) { confirmingReveal = false; paint(); setStatus(''); } }, 4000);
                return;
            }
            confirmingReveal = false;
            shown = true; paint();
            setStatus('Showing your key. Hide it when done.', 'warn');
        });

        // Regenerate flow (double-press to confirm; resets all sessions).
        regenBtn.addEventListener('click', async () => {
            if (!confirmingRegen) {
                confirmingRegen = true;
                regenBtn.textContent = 'Confirm reset';
                setStatus('This logs out ALL web/mobile devices and makes a new key.', 'warn');
                setTimeout(() => { if (confirmingRegen) { confirmingRegen = false; regenBtn.textContent = 'Regenerate'; setStatus(''); } }, 4000);
                return;
            }
            confirmingRegen = false;
            regenBtn.textContent = 'Regenerate';
            setStatus('Regenerating…');
            const res = await HKHubAPI.postJson('regenMobileKey', {});
            if (res && res.ok && res.key) { cur = res.key; shown = true; paint(); setStatus('New key ready. Old devices are logged out.', 'ok'); }
            else setStatus(mobErr(res), 'err');
        });

        function mobErr(res) {
            const e = res && res.err;
            if (e === 'unavailable' || e === 'engine_unreachable') return 'Steak service is offline, try again shortly.';
            return 'Something went wrong, try again.';
        }

        // Initial fetch (metadata only — key stays masked until revealed).
        (async () => {
            const res = await HKHubAPI.postJson('getMobileKey', {});
            if (res && res.ok) { cur = res.key || { loginId: null, key: null }; paint(); }
            else { cur = { loginId: null, key: null }; paint(); }
        })();
    }

    // Reusable segmented mode picker (optimizer / speedo).
    function buildModePref(o, callback, payloadKey) {
        const key = payloadKey || 'mode';
        const p = document.createElement('div');
        p.className = 'pref';
        p.innerHTML =
            '<div class="pref-head"><div class="pref-title">' + esc(o.label || '') +
            (o.zh ? '<span class="zh">' + esc(o.zh) + '</span>' : '') + '</div></div>' +
            (o.desc ? '<div class="pref-desc">' + esc(o.desc) + '</div>' : '');
        const seg = document.createElement('div');
        seg.className = 'seg';
        o.modes.forEach((m) => {
            const opt = document.createElement('div');
            opt.className = 'seg-opt' + (m.name === o.current ? ' active' : '');
            opt.dataset.mode = m.name;
            opt.innerHTML =
                (m.icon ? '<span class="ico">' + esc(m.icon) + '</span>' : '') +
                '<span class="en">' + esc(m.label) + '</span>' +
                (m.zh ? '<span class="zh">' + esc(m.zh) + '</span>' : '');
            opt.addEventListener('click', () => {
                const payload = {}; payload[key] = m.name;
                post(callback, payload);
                seg.querySelectorAll('.seg-opt').forEach((el) =>
                    el.classList.toggle('active', el.dataset.mode === m.name));
            });
            seg.appendChild(opt);
        });
        p.appendChild(seg);
        return p;
    }

    // hk-hud status-icon settings: theme + per-icon display mode & colour.
    // Drives hk-hud via hkhudSetTheme / hkhudSetIcon / hkhudReset callbacks.
    function buildHkHudGroup(h) {
        const saved = h.saved || {};
        const g = document.createElement('div');
        g.className = 'set-group';

        const title = document.createElement('div');
        title.className = 'set-group-title';
        title.textContent = '狀態圖示 · STATUS ICONS';
        const reset = document.createElement('button');
        reset.className = 'hud-reset';
        reset.textContent = '↺ 全部重設 Reset All';
        reset.title = 'Reset all HUD settings (icons, theme, minimap, compass, crosshair) to defaults';
        reset.addEventListener('click', () => { post('hkhudResetAll'); });
        title.appendChild(reset);
        g.appendChild(title);

        // Master HUD on/off + cinematic black bars (side by side).
        const en = document.createElement('div');
        en.className = 'hud-row';
        en.innerHTML = '<div class="hud-row-label"><span class="en">HUD Enabled</span>' +
            '<span class="zh">顯示 HUD</span>' +
            '<span class="desc">Master switch for the whole HUD</span></div>';
        en.appendChild(mkSwitch(h.enabled !== false, (on) => post('hkhudSetEnabled', { on })));
        g.appendChild(en);

        const cin = document.createElement('div');
        cin.className = 'hud-row';
        cin.innerHTML = '<div class="hud-row-label"><span class="en">Cinematic Bars</span>' +
            '<span class="zh">電影黑邊</span>' +
            '<span class="desc">Letterbox black bars top & bottom</span></div>';
        cin.appendChild(mkSwitch(!!h.cinematic, (on) => post('hkhudSetCinematic', { on })));
        g.appendChild(cin);

        // Theme picker (HOMEKONG vs Legacy rings)
        if (h.themes && h.themes.length) {
            g.appendChild(buildModePref({
                label: 'Theme', zh: '主題',
                modes: h.themes.map((t) => ({ name: t.id, label: t.label, zh: t.zh })),
                current: h.theme || 'hk',
            }, 'hkhudSetTheme', 'theme'));
        }

        // Per-icon rows: mode dropdown (+ colour for progress icons).
        (h.icons || []).forEach((ic) => {
            const ov = saved[ic.id] || {};
            const curMode = ov.mode || ic.modeDefault || 'dynamic';
            const curColor = ov.color || ic.color;

            const row = document.createElement('div');
            row.className = 'hud-row';
            row.innerHTML = '<div class="hud-row-label"><span class="en">' + esc(ic.label) +
                '</span>' + (ic.zh ? '<span class="zh">' + esc(ic.zh) + '</span>' : '') + '</div>';

            const ctrls = document.createElement('div');
            ctrls.className = 'icon-ctrls';

            // colour swatch (opens the preset picker inline)
            const dot = document.createElement('button');
            dot.className = 'icon-colordot';
            dot.style.background = curColor;
            let picker = null;
            dot.addEventListener('click', () => {
                if (picker) { picker.remove(); picker = null; return; }
                picker = buildSwatchPopover(curColor, (hex) => {
                    dot.style.background = hex;
                    post('hkhudSetIcon', { name: ic.id, color: hex });
                    picker.remove(); picker = null;
                });
                ctrls.appendChild(picker);
            });
            ctrls.appendChild(dot);

            // mode dropdown — all icons get the 3 modes (always/dynamic/hidden).
            const sel = document.createElement('select');
            sel.className = 'mode-select';
            const modes = [['always', '一直顯示 Always'], ['dynamic', '需要時 Dynamic'], ['hidden', '隱藏 Hidden']];
            modes.forEach(([val, lbl]) => {
                const opt = document.createElement('option');
                opt.value = val; opt.textContent = lbl;
                if (val === curMode) opt.selected = true;
                sel.appendChild(opt);
            });
            sel.addEventListener('change', () => post('hkhudSetIcon', { name: ic.id, mode: sel.value }));
            ctrls.appendChild(sel);

            row.appendChild(ctrls);
            g.appendChild(row);
        });

        return g;
    }

    // Small preset-swatch popover reused for icon colours (CEF-safe, no native picker).
    function buildSwatchPopover(cur, onPick) {
        const box = document.createElement('div');
        box.className = 'swatch-pop';
        ['#00ff88', '#00c8ff', '#ffffff', '#ffcc00', '#ff3b3b', '#ff59d6',
         '#7c4dff', '#00e676', '#21ab61', '#326dbf', '#dd6e14', '#b648ff'].forEach((c) => {
            const s = document.createElement('button');
            s.className = 'sw' + (c === cur ? ' active' : '');
            s.style.background = c;
            s.addEventListener('click', () => onPick(c));
            box.appendChild(s);
        });
        return box;
    }

    // Minimap settings group: shape (circle/square), border, show-on-foot.
    function buildMinimapGroup(m) {
        const g = document.createElement('div');
        g.className = 'set-group';
        g.innerHTML = '<div class="set-group-title">小地圖 · MINIMAP</div>';

        // shape picker (segmented) — sends { key:'shape', value:<name> }
        const sp = document.createElement('div');
        sp.className = 'pref';
        sp.innerHTML = '<div class="pref-head"><div class="pref-title">Shape<span class="zh">形狀</span></div></div>';
        const seg = document.createElement('div');
        seg.className = 'seg';
        [['circle', 'Circle 圓形'], ['square', 'Square 方形']].forEach(([val, lbl]) => {
            const opt = document.createElement('div');
            opt.className = 'seg-opt' + ((m.shape || 'circle') === val ? ' active' : '');
            opt.innerHTML = '<span class="en">' + esc(lbl) + '</span>';
            opt.addEventListener('click', () => {
                post('hkhudSetMinimap', { key: 'shape', value: val });
                seg.querySelectorAll('.seg-opt').forEach((e) => e.classList.remove('active'));
                opt.classList.add('active');
            });
            seg.appendChild(opt);
        });
        sp.appendChild(seg);
        g.appendChild(sp);

        // show-on-foot toggle
        const f = document.createElement('div');
        f.className = 'hud-row';
        f.innerHTML = '<div class="hud-row-label"><span class="en">Show On Foot</span>' +
            '<span class="zh">步行時顯示</span>' +
            '<span class="desc">Off = minimap only shows in vehicles</span></div>';
        f.appendChild(mkSwitch(m.onFoot !== false, (on) => post('hkhudSetMinimap', { key: 'onFoot', value: on })));
        g.appendChild(f);

        return g;
    }

    // Compass settings group: show / on-foot / follow-cam / streets / pointer / degrees.
    function buildCompassGroup(c) {
        const g = document.createElement('div');
        g.className = 'set-group';
        g.innerHTML = '<div class="set-group-title">羅盤 · COMPASS</div>';
        const rows = [
            ['show',      'Show Compass',   '顯示羅盤',   c.show !== false],
            ['onFoot',    'Show On Foot',   '步行時顯示', !!c.onFoot],
            ['follow',    'Follow Camera',  '跟隨鏡頭',   c.follow !== false],
            ['streets',   'Street Names',   '街道名稱',   c.streets !== false],
            ['pointer',   'Center Pointer', '中心指標',   c.pointer !== false],
            ['degrees',   'Show Degrees',   '顯示度數',   c.degrees !== false],
            ['optimized', 'Optimized FPS',  '優化幀率',   c.optimized !== false],
        ];
        rows.forEach(([key, en, zh, val]) => {
            const r = document.createElement('div');
            r.className = 'hud-row';
            r.innerHTML = '<div class="hud-row-label"><span class="en">' + en + '</span>' +
                '<span class="zh">' + zh + '</span></div>';
            r.appendChild(mkSwitch(val, (on) => post('hkhudSetCompass', { key: key, value: on })));
            g.appendChild(r);
        });
        return g;
    }

    // Crosshair settings group (drives hk-hud via setCrosshair* callbacks).
    function buildCrosshairGroup(x) {
        const cur = x.current || {};
        const g = document.createElement('div');
        g.className = 'set-group';
        g.innerHTML = '<div class="set-group-title">準星 · CROSSHAIR</div>';

        const en = document.createElement('div');
        en.className = 'hud-row';
        en.innerHTML = '<div class="hud-row-label"><span class="en">Enable</span><span class="zh">啟用準星</span>' +
            '<span class="desc">Only shown while aiming (hold RMB).</span></div>';
        en.appendChild(mkSwitch(cur.enabled !== false, (on) => post('setCrosshairEnabled', { on })));
        g.appendChild(en);

        const body = document.createElement('div');
        body.className = 'xhair-body';
        body.appendChild(mkChoiceRow('Style 樣式', (x.styles || []).map((st) => ({ val: st.id, label: st.label })),
            cur.style, (v) => post('setCrosshair', { key: 'style', value: v })));
        body.appendChild(mkChoiceRow('Mode 模式',
            [{ val: 'static', label: 'Static 靜態' }, { val: 'dynamic', label: 'Dynamic 動態' }],
            cur.mode, (v) => post('setCrosshair', { key: 'mode', value: v })));
        body.appendChild(mkColorRow('Colour 顏色', cur.color || '#00ff88',
            (hex) => post('setCrosshair', { key: 'color', value: hex })));
        body.appendChild(mkSliderRow('Size 大小', 2, 30, cur.size, (v) => post('setCrosshair', { key: 'size', value: v })));
        body.appendChild(mkSliderRow('Gap 間距', 0, 20, cur.gap, (v) => post('setCrosshair', { key: 'gap', value: v })));
        body.appendChild(mkSliderRow('Thickness 粗細', 1, 8, cur.thickness, (v) => post('setCrosshair', { key: 'thickness', value: v })));
        body.appendChild(mkSliderRow('Opacity 透明度', 10, 100, cur.opacity, (v) => post('setCrosshair', { key: 'opacity', value: v })));

        const dotRow = document.createElement('div');
        dotRow.className = 'hud-row';
        dotRow.innerHTML = '<div class="hud-row-label"><span class="en">Center Dot</span><span class="zh">中心點</span></div>';
        dotRow.appendChild(mkSwitch(!!cur.dot, (on) => post('setCrosshair', { key: 'dot', value: on })));
        body.appendChild(dotRow);

        const olRow = document.createElement('div');
        olRow.className = 'hud-row';
        olRow.innerHTML = '<div class="hud-row-label"><span class="en">Outline</span><span class="zh">黑邊</span></div>';
        olRow.appendChild(mkSwitch(cur.outline !== false, (on) => post('setCrosshair', { key: 'outline', value: on })));
        body.appendChild(olRow);

        g.appendChild(body);
        return g;
    }

    // ---- small reusable controls ----
    function mkSwitch(on, onChange) {
        const sw = document.createElement('label');
        sw.className = 'switch';
        const input = document.createElement('input');
        input.type = 'checkbox'; input.checked = !!on;
        const track = document.createElement('span'); track.className = 'track';
        const thumb = document.createElement('span'); thumb.className = 'thumb';
        input.addEventListener('change', () => onChange(input.checked));
        sw.appendChild(input); sw.appendChild(track); sw.appendChild(thumb);
        return sw;
    }
    function mkChoiceRow(label, choices, cur, onPick) {
        const row = document.createElement('div');
        row.className = 'hud-row';
        row.innerHTML = '<div class="hud-row-label"><span class="en">' + esc(label) + '</span></div>';
        const box = document.createElement('div');
        box.className = 'hud-choice';
        choices.forEach((ch) => {
            const opt = document.createElement('div');
            opt.className = 'hud-choice-opt' + (ch.val === cur ? ' active' : '');
            opt.textContent = ch.label;
            opt.addEventListener('click', () => {
                onPick(ch.val);
                box.querySelectorAll('.hud-choice-opt').forEach((e) => e.classList.remove('active'));
                opt.classList.add('active');
            });
            box.appendChild(opt);
        });
        row.appendChild(box);
        return row;
    }
    // Color control: preset swatches + hex field. Avoids the native
    // <input type=color> OS picker, which misbehaves in FiveM's CEF (loses
    // pointer / doesn't commit when the cursor leaves the popup).
    const COLOR_PRESETS = ['#00ff88', '#00c8ff', '#ffffff', '#ffcc00', '#ff3b3b',
        '#ff59d6', '#7c4dff', '#00e676', '#000000'];
    function mkColorRow(label, hex, onChange) {
        const row = document.createElement('div');
        row.className = 'hud-row color-hud-row';
        row.innerHTML = '<div class="hud-row-label"><span class="en">' + esc(label) + '</span></div>';
        const wrap = document.createElement('div');
        wrap.className = 'color-row';

        const tx = document.createElement('input');
        tx.type = 'text'; tx.className = 'color-hex'; tx.value = hex; tx.maxLength = 7;

        const preview = document.createElement('span');
        preview.className = 'color-preview';
        preview.style.background = hex;

        const swatches = document.createElement('div');
        swatches.className = 'color-swatches';
        const norm = (v) => {
            v = String(v).trim(); if (v[0] !== '#') v = '#' + v;
            return /^#[0-9a-fA-F]{6}$/.test(v) ? v.toLowerCase() : null;
        };
        const apply = (v) => {
            const n = norm(v);
            if (!n) return;
            tx.value = n; preview.style.background = n;
            swatches.querySelectorAll('.sw').forEach((s) =>
                s.classList.toggle('active', s.dataset.c === n));
            onChange(n);
        };
        COLOR_PRESETS.forEach((c) => {
            const s = document.createElement('button');
            s.className = 'sw' + (c === (norm(hex) || '') ? ' active' : '');
            s.dataset.c = c;
            s.style.background = c;
            s.addEventListener('click', () => apply(c));
            swatches.appendChild(s);
        });
        tx.addEventListener('change', () => apply(tx.value));

        wrap.appendChild(preview);
        wrap.appendChild(tx);
        wrap.appendChild(swatches);
        row.appendChild(wrap);
        return row;
    }
    function mkSliderRow(label, min, max, val, onChange) {
        const row = document.createElement('div');
        row.className = 'hud-row';
        const out = document.createElement('span');
        out.className = 'slider-val';
        out.textContent = val;
        row.innerHTML = '<div class="hud-row-label"><span class="en">' + esc(label) + '</span></div>';
        const rng = document.createElement('input');
        rng.type = 'range'; rng.min = min; rng.max = max; rng.value = val;
        rng.className = 'slider';
        rng.addEventListener('input', () => { out.textContent = rng.value; });
        rng.addEventListener('change', () => onChange(parseInt(rng.value, 10)));
        const wrap = document.createElement('div');
        wrap.className = 'slider-wrap';
        wrap.appendChild(rng); wrap.appendChild(out);
        row.appendChild(wrap);
        return row;
    }

    // ---- Info tab: account + money + identity (no prefs) ----
    function renderInfoInto(setBody, s) {
        // Profile header: character avatar (ped headshot) + name. The avatar URL
        // is filled by setInfo / setAvatar; a placeholder shows until it lands.
        const prof = document.createElement('div');
        prof.className = 'set-group profile-head';
        prof.innerHTML =
            '<div class="profile-avatar" id="profile-avatar">' +
                '<i class="fa-solid fa-user profile-avatar-ph"></i>' +
            '</div>' +
            '<div class="profile-meta">' +
                '<div class="profile-name" id="profile-name">…</div>' +
                '<div class="profile-sub" id="profile-sub"></div>' +
            '</div>';
        setBody.appendChild(prof);

        // Account stats: playtime + days since first joined (filled by setInfo).
        const stat = document.createElement('div');
        stat.className = 'set-group';
        stat.innerHTML =
            '<div class="set-group-title">帳戶 · ACCOUNT</div>' +
            '<div class="stat-row">' +
                '<div class="stat-box"><div class="stat-val" id="stat-playtime">…</div>' +
                    '<div class="stat-cap">遊玩時間 · Playtime</div></div>' +
                '<div class="stat-box"><div class="stat-val" id="stat-days">…</div>' +
                    '<div class="stat-cap">加入日數 · Days Joined</div></div>' +
            '</div>';
        setBody.appendChild(stat);

        // Money: cash / bank / homecoin (filled by setInfo).
        if (s.money && s.money.length) {
            const g = document.createElement('div');
            g.className = 'set-group';
            g.innerHTML = '<div class="set-group-title">財產 · BALANCE</div>';
            const row = document.createElement('div');
            row.className = 'money-row';
            s.money.forEach((m) => {
                const box = document.createElement('div');
                box.className = 'money-box';
                box.innerHTML =
                    '<div class="money-ico">' + esc(m.icon || '') + '</div>' +
                    '<div class="money-val loading" data-money="' + esc(m.key) +
                        '" data-prefix="' + esc(m.prefix || '') + '">…</div>' +
                    '<div class="money-cap">' + esc(m.label) +
                        (m.zh ? ' · ' + esc(m.zh) : '') + '</div>';
                row.appendChild(box);
            });
            g.appendChild(row);
            setBody.appendChild(g);
        }

        // Identity group
        if (s.identity && s.identity.length) {
            const g = document.createElement('div');
            g.className = 'set-group';
            g.innerHTML = '<div class="set-group-title">身份 · IDENTITY</div>';
            const card = document.createElement('div');
            card.className = 'id-card';
            s.identity.forEach((row) => {
                const r = document.createElement('div');
                r.className = 'id-row';
                r.innerHTML =
                    '<div class="id-label"><span class="en">' + esc(row.label) + '</span>' +
                    (row.zh ? '<span class="zh">' + esc(row.zh) + '</span>' : '') + '</div>' +
                    '<div class="id-value loading" data-id="' + esc(row.key) + '">…</div>';
                card.appendChild(r);
            });
            g.appendChild(card);
            setBody.appendChild(g);
        }

        // (Keybinds moved to a main-menu tile in the INFO section — see config.)

        // (Feedback moved to a main-menu tile in the INFO section — see config.)

        // (Preferences + HUD moved to the Settings tab — renderSettingsInto.)
    }

    function fmtPlaytime(mins) {
        mins = Number(mins) || 0;
        const h = Math.floor(mins / 60);
        const m = Math.floor(mins % 60);
        if (h >= 1) return h.toLocaleString('en-US') + 'h ' + m + 'm';
        return m + 'm';
    }

    // Days since a unix (seconds) first-join timestamp from txAdmin.
    function daysSince(tsSeconds) {
        if (!tsSeconds) return null;
        const then = Number(tsSeconds) * 1000;
        if (!then || isNaN(then)) return null;
        const days = Math.floor((Date.now() - then) / 86400000);
        return days < 0 ? 0 : days;
    }

    function fmtMoney(prefix, val) {
        const n = Number(val) || 0;
        return (prefix || '') + n.toLocaleString('en-US');
    }

    // Fill account stats, money, and identity when the server responds.
    function setInfo(info) {
        info = info || {};
        lastInfo = info;   // cache so re-rendering the Info tab keeps the values

        // Profile header: name + job sub-line + avatar (if already cached).
        const pname = document.getElementById('profile-name');
        if (pname) pname.textContent = info.charName || '—';
        const psub = document.getElementById('profile-sub');
        if (psub) psub.textContent = info.job || '';
        if (info.avatar) setAvatar(info.avatar);

        // Account stats (from txAdmin: playtime in minutes, tsJoined unix secs)
        const pt = document.getElementById('stat-playtime');
        if (pt) pt.textContent = (info.playtimeMins == null) ? '—' : fmtPlaytime(info.playtimeMins);
        const dy = document.getElementById('stat-days');
        if (dy) {
            const d = daysSince(info.tsJoined);
            dy.textContent = (d === null) ? '—' : String(d);
        }

        // Money
        const money = info.money || {};
        setBody.querySelectorAll('.money-val').forEach((el) => {
            const key = el.dataset.money;
            const prefix = el.dataset.prefix || '';
            el.classList.remove('loading');
            const val = money[key];
            el.textContent = (val === undefined || val === null) ? '—' : fmtMoney(prefix, val);
        });

        // Identity rows — the value text is clickable to copy (no button).
        setBody.querySelectorAll('.id-value').forEach((el) => {
            const key = el.dataset.id;
            el.classList.remove('loading');

            // Licenses: array → one stacked clickable line per license.
            if (key === 'licenses') {
                const arr = Array.isArray(info.licenses) ? info.licenses : [];
                if (!arr.length) { el.innerHTML = '<span class="none">—</span>'; return; }
                el.textContent = '';
                el.classList.add('multi');
                arr.forEach((lic) => {
                    // copy just the hex (after the "labelN: " prefix) if present.
                    const hex = String(lic).replace(/^license2?:\s*/, '');
                    el.appendChild(makeCopyLine(lic, hex));
                });
                return;
            }

            let val = info[key];
            // Steam name falls back to FiveM name when the API gave nothing.
            if (key === 'steamName' && (val === undefined || val === null || val === '')) {
                val = info.fivemName ? info.fivemName + ' (FiveM)' : null;
            }
            if (val === undefined || val === null || val === '') {
                el.innerHTML = '<span class="none">—</span>';
            } else {
                el.textContent = '';
                el.appendChild(makeCopyLine(String(val), String(val)));
            }
        });
    }

    // Character avatar URL arrives with setInfo (if cached) or later via setAvatar
    // once a fresh capture completes. Swaps the placeholder for the portrait.
    function setAvatar(url) {
        if (!url) return;
        lastAvatar = url;
        const box = document.getElementById('profile-avatar');
        if (!box) return;
        box.innerHTML = '';
        const im = document.createElement('img');
        im.className = 'profile-avatar-img';
        im.src = url;
        im.onerror = () => { box.innerHTML = '<i class="fa-solid fa-user profile-avatar-ph"></i>'; };
        box.appendChild(im);
    }

    // Rasterise a registered ped-headshot txd into a base64 PNG. The game exposes
    // the runtime txd via the built-in `nui-img/{txd}/{txd}` scheme; drawing it to
    // a transparent canvas and reading toDataURL gives us an isolated portrait
    // (no world background) to hand back to Lua -> server -> Zipline.
    function genAvatar(txd) {
        if (!txd) { post('avatarData', { data: '' }); return; }
        const img = new Image();
        img.onload = () => {
            try {
                const c = document.createElement('canvas');
                c.width = img.naturalWidth || 256;
                c.height = img.naturalHeight || 256;
                const ctx = c.getContext('2d');
                ctx.clearRect(0, 0, c.width, c.height);
                ctx.drawImage(img, 0, 0, c.width, c.height);
                post('avatarData', { data: c.toDataURL('image/png') });
            } catch (e) {
                post('avatarData', { data: '' });
            }
        };
        img.onerror = () => { post('avatarData', { data: '' }); };
        img.src = `https://nui-img/${txd}/${txd}`;
    }

    // Steam persona name arrives after setInfo (separate, non-blocking).
    function setSteamName(name) {
        if (!name) return;
        const el = setBody && setBody.querySelector('.id-value[data-id="steamName"]');
        if (!el) return;
        el.classList.remove('loading');
        el.textContent = '';
        el.appendChild(makeCopyLine(String(name), String(name)));
    }

    // A clickable value chip: shows `display`, copies `copyVal`, flashes "已複製".
    function makeCopyLine(display, copyVal) {
        const line = document.createElement('span');
        line.className = 'id-copy';
        line.title = '點擊複製 · Click to copy';
        line.textContent = display;
        line.addEventListener('click', () => {
            copyText(copyVal);
            const prev = line.textContent;
            line.classList.add('copied');
            line.textContent = '✓ 已複製 Copied';
            setTimeout(() => { line.textContent = prev; line.classList.remove('copied'); }, 1000);
        });
        return line;
    }

    function copyText(text) {
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
        } else {
            fallbackCopy(text);
        }
    }

    function fallbackCopy(text) {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        document.body.removeChild(ta);
    }

    // Active launcher elements depend on the mode.
    function tileEls() {
        if (menuMode === 'minimal') {
            // items + the settings gear (so arrow-nav can reach settings). The
            // gear is marked data-idx="settings" and handled specially in launch().
            const arr = Array.from(railItems.querySelectorAll('.rail-item'));
            const gear = document.getElementById('btn-settings-rail');
            if (gear && settings) arr.push(gear);
            return arr;
        }
        return hubBody.querySelectorAll('.tile');
    }

    function setFocus(idx) {
        const els = tileEls();
        if (!els.length) return;
        focusIdx = Math.max(0, Math.min(idx, els.length - 1));
        els.forEach((el, i) => el.classList.toggle('focused', i === focusIdx));
        els[focusIdx].scrollIntoView({ block: 'nearest' });
    }

    // Move focus by a step, wrapping around the ends. Used by keyboard nav so
    // the rail (single column) never feels dead-ended at top/bottom.
    function moveFocus(step) {
        const els = tileEls();
        if (!els.length) return;
        const n = els.length;
        setFocus(((focusIdx + step) % n + n) % n);
    }

    // Keyboard nav in minimal mode: `.kbd` makes the focused item show its label
    // (per-item, via CSS) without needing mouse hover.
    function setRailKbd(on) {
        railKbd = on && menuMode === 'minimal';
        rail.classList.toggle('kbd', railKbd);
    }

    // Normal grid = compute columns for up/down nav; rail = single column.
    function colsPerRow() {
        if (menuMode === 'minimal') return 1;
        const els = tileEls();
        if (els.length < 2) return 1;
        const top0 = els[0].offsetTop;
        let cols = 1;
        for (let i = 1; i < els.length; i++) {
            if (els[i].offsetTop === top0) cols++; else break;
        }
        return cols;
    }

    function launch(idx) {
        // In minimal mode the settings gear is appended after the items; if the
        // focused element is the gear (idx === items.length), open settings.
        if (menuMode === 'minimal' && idx >= items.length) { showSettings(); return; }
        const it = items[idx];
        if (!it) return;
        if (it.view === 'laws') { showLaws(); return; }
        if (it.view === 'keybinds') { showKeybinds(); return; }
        if (it.view === 'report') { showReport(); return; }
        if (it.view === 'squad') { showSquad(); return; }
        // Link tiles (isLink): the URL lives in Lua — just send the id; Lua looks
        // it up and messages back 'openUrl' to actually open the browser.
        post('launch', { id: it.id });
    }

    function close() { post('close'); }

    // Open an external URL via FiveM's CEF openUrl native. Called only from Lua
    // (the 'openUrl' message) — the URL is never held in NUI config.
    function openUrl(url) {
        if (typeof url !== 'string' || !url) return;
        try {
            if (typeof invokeNative === 'function') invokeNative('openUrl', url);
        } catch (e) {}
    }

    function applyMode(mode) {
        menuMode = (mode === 'minimal') ? 'minimal' : 'normal';
        overlay.setAttribute('data-mode', menuMode);
        // Leaving minimal mode drops any keyboard-held rail expansion.
        if (menuMode !== 'minimal') setRailKbd(false);
    }

    function open(msg) {
        renderBrand(msg.brand);
        applyMode(msg.menuMode);
        render(msg.items || []);
        settings = msg.settings || null;
        keybinds = msg.keybinds || null;
        btnSetEls.forEach((b) => b.classList.toggle('hidden', !settings));
        showGrid();
        overlay.classList.remove('hidden');
        isOpen = true;
    }

    // Flyout body toggling (only one body visible at a time).
    function showFlyoutBody(el, title) {
        setBody.classList.add('hidden');
        lawsBody.classList.add('hidden');
        reportBody.classList.add('hidden');
        keybindsBody.classList.add('hidden');
        squadBody.classList.add('hidden');
        flyout.classList.remove('flyout-squad');
        // Squad lifts its name + chips into the top bar; hide that slot whenever we
        // switch to any body (squad view re-shows it via HKSquad). Also close the
        // squad panel if we're navigating away from it to another view directly.
        if (view === 'squad' && el !== squadBody && window.HKSquad) window.HKSquad.close();
        const sqHead = document.getElementById('flyout-squad-head');
        if (sqHead && el !== squadBody) { sqHead.innerHTML = ''; sqHead.classList.add('hidden'); }
        el.classList.remove('hidden');
        flyoutTitle.textContent = title;
        flyout.classList.remove('hidden');
        overlay.classList.add('flyout-open');  // hides the launcher (hub/rail) behind it
        // Minimal mode is keyboard-only with no cursor; a view is a real popup,
        // so turn the mouse on for it (CSS centers it + hides the rail).
        if (menuMode === 'minimal') { setRailKbd(false); post('cursor', { on: true }); }
    }

    // Leaving a view. In normal mode we fall back to the card grid; in minimal
    // mode there's no grid to return to (the bar is keyboard-only), so closing a
    // view closes the whole hub — the player just taps F5 to get the bar back.
    function closeView() {
        if (menuMode === 'minimal') { close(); } else { showGrid(); }
    }

    // "grid" = launcher shown (rail or panel), flyout closed.
    function showGrid() {
        if (view === 'squad' && window.HKSquad) window.HKSquad.close();
        view = 'grid';
        flyout.classList.add('hidden');
        overlay.classList.remove('flyout-open');
        railItems.querySelectorAll('.rail-item').forEach((e) => e.classList.remove('open'));
        btnSetEls.forEach((b) => b.classList.remove('active'));
        // Invariant: the minimal rail is keyboard-only (no cursor); the normal
        // card grid needs the mouse. Reconcile whenever we return to the launcher.
        post('cursor', { on: menuMode !== 'minimal' });
        setFocus(focusIdx);
    }

    function showSettings() {
        if (!settings) return;
        view = 'settings';
        renderSettings(settings);  // handles getInfo fetch when on the Info tab
        showFlyoutBody(setBody, '設定 Settings');
        btnSetEls.forEach((b) => b.classList.add('active'));
    }

    // ---- Laws viewer ----
    function showLaws() {
        view = 'laws';
        showFlyoutBody(lawsBody, '法律條文 Laws');
        btnSetEls.forEach((b) => b.classList.remove('active'));
        if (lawsData) {
            renderLaws();
        } else {
            lawsBody.innerHTML = '<div class="law-empty">載入中… Loading…</div>';
            // laws.json sits next to index.html in html/ (base URL is .../html/).
            fetch('laws.json')
                .then((r) => r.json())
                .then((d) => { lawsData = d; lawsActiveDoc = 0; lawsQuery = ''; renderLaws(); })
                .catch(() => { lawsBody.innerHTML = '<div class="law-empty">無法載入法律文件 Failed to load.</div>'; });
        }
    }

    // ---- Keybinds reference (read-only view) ----
    function showKeybinds() {
        const kb = keybinds;
        if (!kb || !kb.groups) return;
        view = 'keybinds';
        showFlyoutBody(keybindsBody, '按鍵綁定 Keybinds');
        btnSetEls.forEach((b) => b.classList.remove('active'));
        keybindsBody.innerHTML = '';
        const wrap = document.createElement('div');
        wrap.className = 'kb-wrap';
        (kb.groups || []).forEach((grp) => {
            const g = document.createElement('div');
            g.className = 'kb-group';
            g.innerHTML = '<div class="kb-group-title">' + esc(grp.title || '') + '</div>';
            const card = document.createElement('div');
            card.className = 'kb-card';
            (grp.keys || []).forEach((it) => {
                const row = document.createElement('div');
                row.className = 'kb-row';
                row.innerHTML =
                    '<span class="kb-cap">' + esc(it.key || '') + '</span>' +
                    '<span class="kb-label">' + esc(it.label || '') +
                    (it.sub ? '<small>' + esc(it.sub) + '</small>' : '') + '</span>';
                card.appendChild(row);
            });
            g.appendChild(card);
            wrap.appendChild(g);
        });
        if (kb.note) {
            const note = document.createElement('div');
            note.className = 'kb-note';
            note.innerHTML = '<i class="fa-solid fa-circle-info"></i> ' + esc(kb.note);
            wrap.appendChild(note);
        }
        keybindsBody.appendChild(wrap);
    }

    // ---- Bug report / feedback form ----
    // Character count (trimmed). Char count is simpler + less buggy than words.
    function charCount(s) {
        return String(s || '').trim().length;
    }

    function showReport() {
        const rc = settings && settings.report;
        if (!rc) return;
        view = 'report';
        reportBusy = false;
        showFlyoutBody(reportBody, '意見回饋 Feedback');
        btnSetEls.forEach((b) => b.classList.remove('active'));
        renderReport(rc);
    }

    function renderReport(rc) {
        const minC = rc.minChars || 20;
        const minSC = rc.minStepChars || 20;
        reportBody.innerHTML = '';

        const wrap = document.createElement('div');
        wrap.className = 'report-wrap';

        // Intro line (single unified feedback — no category to pick).
        const intro = document.createElement('div');
        intro.className = 'report-note';
        intro.innerHTML =
            '<i class="fa-solid fa-comment-dots"></i> 回報錯誤或提供任何意見 — 我們會逐一閱讀。 ' +
            'Report a bug or share any feedback — we read every one.';
        wrap.appendChild(intro);

        // Description field + live char counter
        wrap.appendChild(fieldLabel('說明 · What happened', '請盡量詳細 (最少 ' + minC + ' 字元) · Be specific (min ' + minC + ' characters)'));
        const msg = document.createElement('textarea');
        msg.className = 'report-input'; msg.id = 'report-msg'; msg.rows = 5;
        msg.placeholder = '例如：打開背包時畫面卡住，無法關閉…';
        wrap.appendChild(msg);
        const msgCount = document.createElement('div');
        msgCount.className = 'report-count'; msgCount.id = 'report-msg-count';
        wrap.appendChild(msgCount);

        // Steps field + counter
        wrap.appendChild(fieldLabel('重現步驟 · Steps to reproduce', '你做了什麼才出現這個問題？ · What did you do leading up to it?'));
        const steps = document.createElement('textarea');
        steps.className = 'report-input'; steps.id = 'report-steps'; steps.rows = 3;
        steps.placeholder = '1. …\n2. …\n3. …';
        wrap.appendChild(steps);
        const stepCount = document.createElement('div');
        stepCount.className = 'report-count'; stepCount.id = 'report-step-count';
        wrap.appendChild(stepCount);

        // F8 console log paste field (optional). Players can't have us read the
        // console, but they can copy it themselves: F8 → select all → paste here.
        wrap.appendChild(fieldLabel('F8 主控台記錄 · Console log (optional)',
            '按 F8 打開主控台 → Ctrl+A 全選 → Ctrl+C 複製 → 貼上此處。 ' +
            'Press F8, select all (Ctrl+A), copy, and paste here.'));
        const con = document.createElement('textarea');
        con.className = 'report-input report-console'; con.id = 'report-console'; con.rows = 4;
        con.placeholder = '(選填 · optional) 在此貼上 F8 主控台內容…';
        wrap.appendChild(con);

        // Screenshot toggle — only shown when the feature is enabled server-side.
        if (rc.screenshot) {
            const shotRow = document.createElement('label');
            shotRow.className = 'report-toggle';
            const shot = document.createElement('input');
            shot.type = 'checkbox'; shot.id = 'report-shot';
            shot.checked = rc.screenshotDefault === true;
            shotRow.appendChild(shot);
            const shotTxt = document.createElement('span');
            shotTxt.innerHTML = '附上螢幕截圖 · Attach a screenshot';
            shotRow.appendChild(shotTxt);
            wrap.appendChild(shotRow);
        }

        // Diagnostics note (what gets auto-attached)
        const note = document.createElement('div');
        note.className = 'report-note';
        note.innerHTML =
            '<i class="fa-solid fa-circle-info"></i> 系統會自動附上診斷資訊（座標、車輛、資源狀態、FPS 等）以協助除錯。' +
            'Diagnostics (location, vehicle, resource state, FPS…) are attached automatically to help us debug.';
        wrap.appendChild(note);

        // Submit + status
        const submit = document.createElement('button');
        submit.className = 'report-submit'; submit.id = 'report-submit';
        submit.disabled = true;
        submit.innerHTML = '<i class="fa-solid fa-paper-plane"></i> 送出 · Submit';
        submit.addEventListener('click', () => doSubmitReport(rc));
        wrap.appendChild(submit);

        const status = document.createElement('div');
        status.className = 'report-status'; status.id = 'report-status';
        wrap.appendChild(status);

        reportBody.appendChild(wrap);

        // Live validation: enable submit only when both required fields meet
        // their character minimums. The console field is optional.
        function refresh() {
            const mc = charCount(msg.value), sc = charCount(steps.value);
            msgCount.textContent = mc + ' / ' + minC + ' 字元 chars';
            msgCount.classList.toggle('ok', mc >= minC);
            stepCount.textContent = sc + ' / ' + minSC + ' 字元 chars';
            stepCount.classList.toggle('ok', sc >= minSC);
            submit.disabled = reportBusy || mc < minC || sc < minSC;
        }
        msg.addEventListener('input', refresh);
        steps.addEventListener('input', refresh);
        refresh();
    }

    // Small label+hint block used by the report form.
    function fieldLabel(title, hint) {
        const el = document.createElement('div');
        el.className = 'report-field-label';
        el.innerHTML = '<div class="rf-title">' + esc(title) + '</div>' +
            (hint ? '<div class="rf-hint">' + esc(hint) + '</div>' : '');
        return el;
    }

    function doSubmitReport(rc) {
        if (reportBusy) return;
        const msg = document.getElementById('report-msg');
        const steps = document.getElementById('report-steps');
        const con = document.getElementById('report-console');
        const shot = document.getElementById('report-shot');
        const submit = document.getElementById('report-submit');
        const status = document.getElementById('report-status');
        if (!msg || !steps) return;
        if (charCount(msg.value) < (rc.minChars || 20)) return;
        if (charCount(steps.value) < (rc.minStepChars || 20)) return;

        reportBusy = true;
        if (submit) { submit.disabled = true; submit.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 送出中… Sending…'; }
        if (status) { status.className = 'report-status'; status.textContent = ''; }
        post('submitReport', {
            message: msg.value,
            steps: steps.value,
            console: con ? con.value.slice(0, 4000) : '',
            screenshot: !!(shot && shot.checked),
        });
    }

    // Server → NUI result of a submission.
    function reportResult(res) {
        res = res || {};
        reportBusy = false;
        const submit = document.getElementById('report-submit');
        const status = document.getElementById('report-status');
        if (submit) { submit.disabled = false; submit.innerHTML = '<i class="fa-solid fa-paper-plane"></i> 送出 · Submit'; }
        if (!status) return;
        if (res.ok) {
            status.className = 'report-status ok';
            status.innerHTML = '<i class="fa-solid fa-circle-check"></i> 已送出，感謝回報！ Thanks — your report was sent.';
            const msg = document.getElementById('report-msg'), steps = document.getElementById('report-steps');
            const con = document.getElementById('report-console');
            if (msg) msg.value = ''; if (steps) steps.value = ''; if (con) con.value = '';
            if (submit) submit.disabled = true;
        } else {
            status.className = 'report-status err';
            status.innerHTML = '<i class="fa-solid fa-triangle-exclamation"></i> ' + esc(reportErr(res));
        }
    }

    function reportErr(res) {
        switch (res.err) {
            case 'too_short':   return '說明太短了。 Description is too short.';
            case 'steps_short': return '請補充重現步驟。 Please add reproduction steps.';
            case 'cooldown':    return '請稍候 ' + (res.wait || '') + ' 秒再送出。 Please wait ' + (res.wait || '') + 's before sending again.';
            case 'no_webhook':  return '回報功能尚未設定。 Reporting isn\'t configured yet.';
            case 'disabled':    return '回報功能已停用。 Reporting is disabled.';
            default:            return '送出失敗，請稍後再試。 Failed to send — try again later.';
        }
    }

    // ---- Squad panel (delegated to html/squad.js via window.HKSquad) ----
    function showSquad() {
        if (!window.HKSquad) return;
        view = 'squad';
        showFlyoutBody(squadBody, '小隊 Squad');
        flyout.classList.add('flyout-squad');   // wider box for the team panel
        btnSetEls.forEach((b) => b.classList.remove('active'));
        window.HKSquad.open(squadBody);
    }

    function highlight(text) {
        const t = esc(text);
        if (!lawsQuery) return t;
        try {
            const re = new RegExp('(' + lawsQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
            return t.replace(re, '<mark>$1</mark>');
        } catch (e) { return t; }
    }

    function matches(text) {
        return !lawsQuery || String(text).toLowerCase().includes(lawsQuery.toLowerCase());
    }

    function renderLaws() {
        const docs = (lawsData && lawsData.docs) || [];
        // #laws-body is the single scroll container. Sticky header (tabs +
        // search + index) stays pinned; content flows and scrolls beneath it.
        lawsBody.innerHTML = '';
        lawsBody.scrollTop = 0;

        const wrap = document.createElement('div');
        wrap.className = 'laws-wrap';

        // --- Sticky header ---
        const head = document.createElement('div');
        head.className = 'laws-head';

        // Tabs
        const tabs = document.createElement('div');
        tabs.className = 'laws-tabs';
        docs.forEach((d, i) => {
            const t = document.createElement('div');
            t.className = 'law-tab' + (i === lawsActiveDoc ? ' active' : '');
            t.innerHTML = (d.icon ? esc(d.icon) + ' ' : '') + esc(d.title) +
                ' <span class="t-en">' + esc(d.en || '') + '</span>';
            t.addEventListener('click', () => { lawsActiveDoc = i; renderLaws(); });
            tabs.appendChild(t);
        });
        head.appendChild(tabs);

        // Section index (jump-links)
        const index = document.createElement('div');
        index.className = 'laws-index';
        head.appendChild(index);

        wrap.appendChild(head);

        // --- Scrollable content ---
        const content = document.createElement('div');
        content.className = 'laws-content';
        wrap.appendChild(content);
        renderContent(content, index, docs[lawsActiveDoc]);

        lawsBody.appendChild(wrap);
    }

    // Slugify a heading into a DOM id for the index jump-links.
    function secId(i) { return 'law-sec-' + lawsActiveDoc + '-' + i; }

    function renderContent(container, index, doc) {
        container.innerHTML = '';
        if (index) index.innerHTML = '';
        if (!doc) return;

        if (doc.note) {
            const n = document.createElement('div');
            n.className = 'doc-note';
            n.textContent = '※ ' + doc.note;
            container.appendChild(n);
        }

        let shown = 0;
        (doc.sections || []).forEach((sec, secIdx) => {
            // Filter this section's entries by the query.
            const items = sec.items || [];
            const pens = sec.penalties || [];
            const fItems = items.filter((x) => matches(x));
            const fPens = pens.filter((p) => matches(p.name) || matches(p.fine) || matches(p.jail));
            const headMatch = matches(sec.heading);

            // If searching and nothing in this section matches, skip it —
            // unless the heading itself matches (then show all its entries).
            if (lawsQuery && !headMatch && fItems.length === 0 && fPens.length === 0) return;
            const useItems = (lawsQuery && !headMatch) ? fItems : items;
            const usePens = (lawsQuery && !headMatch) ? fPens : pens;
            shown++;

            const id = secId(secIdx);

            // Index chip → smooth-scroll to this section.
            if (index) {
                const chip = document.createElement('button');
                chip.className = 'law-idx';
                // Short label = leading token of the heading (e.g. "A.", "B2.").
                chip.textContent = sec.heading;
                chip.addEventListener('click', () => {
                    const target = document.getElementById(id);
                    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
                });
                index.appendChild(chip);
            }

            const s = document.createElement('div');
            s.className = 'law-sec';
            s.id = id;

            const h = document.createElement('div');
            h.className = 'law-sec-head';
            h.innerHTML = highlight(sec.heading);
            s.appendChild(h);

            if (sec.intro) {
                const intro = document.createElement('div');
                intro.className = 'law-sec-intro';
                intro.innerHTML = highlight(sec.intro);
                s.appendChild(intro);
            }

            if (useItems.length) {
                const ul = document.createElement('ul');
                ul.className = 'law-list';
                useItems.forEach((x) => {
                    const li = document.createElement('li');
                    li.innerHTML = highlight(x);
                    ul.appendChild(li);
                });
                s.appendChild(ul);
            }

            if (usePens.length) {
                usePens.forEach((p) => {
                    const row = document.createElement('div');
                    row.className = 'pen';
                    row.innerHTML =
                        '<div class="pen-name">' + highlight(p.name) + '</div>' +
                        '<div class="pen-meta">' +
                            (p.fine ? '<span class="pen-fine">' + highlight(p.fine) + '</span>' : '') +
                            (p.jail ? '<span class="pen-jail">' + highlight(p.jail) + '</span>' : '') +
                        '</div>';
                    s.appendChild(row);
                });
            }

            container.appendChild(s);
        });

        if (shown === 0) {
            container.innerHTML = '<div class="law-empty">找不到相關條文 No matching laws.</div>';
        }
    }


    function hide() {
        if (view === 'squad' && window.HKSquad) window.HKSquad.close();
        overlay.classList.add('hidden');
        isOpen = false;
        setRailKbd(false);  // don't leak keyboard-expanded rail into the next open
    }

    btnCloseEls.forEach((b) => b.addEventListener('click', close));
    btnSetEls.forEach((b) => b.addEventListener('click', () => {
        if (view === 'settings') closeView(); else showSettings();
    }));
    flyoutClose.addEventListener('click', closeView);

    // (Per-item label fly-out is pure CSS :hover now — no rail-wide expand.)

    // Click on the dim (outside rail + flyout) closes.
    overlay.addEventListener('mousedown', (e) => {
        if (e.target === overlay) close();
    });

    // Shared nav handler. In minimal mode the rail has NO NUI focus (so the game
    // keeps WASD etc.), and Lua forwards ESC/arrows/Enter here via a 'key'
    // message — so this must work identically whether driven by a real keydown
    // (normal mode / open popup) or a forwarded key (minimal rail).
    function handleNavKey(key) {
        if (!isOpen) return;
        // In a sub-view, ESC leaves it: normal mode → back to the card grid;
        // minimal mode → closes the whole hub (there's no grid behind the rail).
        if (view === 'settings' || view === 'laws' || view === 'report' || view === 'keybinds' || view === 'squad') {
            if (key === 'Escape') {
                // In the squad view, let an open popup/dialog swallow Escape first
                // so it closes that instead of the whole view.
                if (view === 'squad' && window.HKSquad && window.HKSquad.onEscape && window.HKSquad.onEscape()) return;
                closeView();
            }
            return;
        }
        if (menuMode === 'minimal') {
            // Vertical rail: Up/Down move (wrapping) + reveal labels, Left/Right
            // collapse/expand the label flyout, Home/End jump to ends.
            switch (key) {
                case 'Escape':     close(); break;
                case 'ArrowDown':  setRailKbd(true); moveFocus(1);  break;
                case 'ArrowUp':    setRailKbd(true); moveFocus(-1); break;
                case 'ArrowRight': setRailKbd(true); break;
                case 'ArrowLeft':  setRailKbd(false); break;
                case 'Home':       setRailKbd(true); setFocus(0); break;
                case 'End':        setRailKbd(true); setFocus(tileEls().length - 1); break;
                case 'Enter':      launch(focusIdx); break;
                default: break;
            }
            return;
        }
        const cols = colsPerRow();
        switch (key) {
            case 'Escape':     close(); break;
            case 'ArrowRight': setFocus(focusIdx + 1); break;
            case 'ArrowLeft':  setFocus(focusIdx - 1); break;
            case 'ArrowDown':  setFocus(focusIdx + cols); break;
            case 'ArrowUp':    setFocus(focusIdx - cols); break;
            case 'Home':       setFocus(0); break;
            case 'End':        setFocus(tileEls().length - 1); break;
            case 'Enter':      launch(focusIdx); break;
            default: break;
        }
    }

    // Real keydown: only fires when the NUI actually HAS focus (normal mode, or
    // any mode with a popup open). The minimal rail gets keys via the 'key'
    // message path instead. preventDefault stops the browser scrolling on arrows.
    const NAV_KEYS = { Escape:1, Enter:1, ArrowUp:1, ArrowDown:1, ArrowLeft:1, ArrowRight:1, Home:1, End:1 };
    document.addEventListener('keydown', (e) => {
        if (!isOpen || !NAV_KEYS[e.key]) return;
        // Don't hijack keys while the player is typing in a field (report form):
        // let Enter/arrows/Home/End edit the text normally. ESC still closes.
        const t = e.target;
        const typing = t && (t.tagName === 'TEXTAREA' || t.tagName === 'INPUT' || t.isContentEditable);
        if (typing && e.key !== 'Escape') return;
        e.preventDefault();
        handleNavKey(e.key);
    });

    window.addEventListener('message', (ev) => {
        const msg = ev.data || {};
        if (msg.action === 'open') open(msg);
        else if (msg.action === 'close') hide();
        else if (msg.action === 'key') handleNavKey(msg.key);  // forwarded from Lua (minimal rail)
        else if (msg.action === 'openUrl') openUrl(msg.url);    // Lua-routed external link
        else if (msg.action === 'setInfo') setInfo(msg.info);
        else if (msg.action === 'setSteamName') setSteamName(msg.name);
        else if (msg.action === 'setAvatar') setAvatar(msg.url);
        else if (msg.action === 'genAvatar') genAvatar(msg.txd);
        else if (msg.action === 'reportResult') reportResult(msg.result);
        else if (msg.action === 'squadState' && window.HKSquad) window.HKSquad.onState(msg.state);
        else if (msg.action === 'squadPositions' && window.HKSquad) window.HKSquad.onPositions(msg.positions);
        else if (msg.action === 'squadWaypointsChanged' && window.HKSquad) window.HKSquad.onWaypointsChanged();
        else if (msg.action === 'squadInvite' && window.HKSquad) window.HKSquad.onInvite(msg.invite);
        else if (msg.action === 'squadChatMessage' && window.HKSquad) window.HKSquad.onChatMessage(msg.message);
        else if (msg.action === 'squadOverlay' && window.HKSquad) window.HKSquad.onOverlay(msg);
        else if (msg.action === 'setMenuMode') {
            if (settings) settings.menuMode = msg.mode;  // keep picker in sync
            applyMode(msg.mode);
            showGrid();
        }
    });
})();
