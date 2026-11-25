(function () {
    const hud = document.getElementById('hud');
    const cluster = document.getElementById('status');
    const voiceDock = document.getElementById('voice-dock');
    const moneyToast = document.getElementById('money-toast');
    const xhairEl = document.getElementById('crosshair');
    const xhairSvg = document.getElementById('xhair-svg');

    let xhairCfg = null;   // current crosshair settings (from Lua)
    let xhairOnTarget = false;

    // Escape strings before injecting as HTML (buff icon names come from events).
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }

    // ---- config + saved settings (from Lua 'settings' message) ----
    let iconCfg = [];      // HKHudConfig.Icons
    let saved = {};        // per-icon overrides { id: {show, color} }
    let warnBelow = {};
    let theme = 'hk';
    let built = false;     // whether icon DOM exists yet

    // Icon glyphs — inline SVG paths keyed by config `icon` name. Simple,
    // Icons are Font Awesome 6 (loaded from CDN) — same glyphs ps-hud used.
    function faIcon(cls) {
        return '<i class="fa-solid ' + (cls || 'fa-heart') + '"></i>';
    }

    function post(name, payload) {
        return fetch(`https://${GetParent()}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload || {}),
        }).catch(() => {});
    }
    function GetParent() { return window.GetParentResourceName ? GetParentResourceName() : 'hk-hud'; }

    // Build the icon DOM once (from config). Each icon = a cell with a progress
    // ring/bar + glyph. Actual values/visibility updated each tick.
    function buildIcons() {
        cluster.innerHTML = '';
        if (voiceDock) voiceDock.innerHTML = '';
        iconCfg.forEach((ic) => {
            const cell = document.createElement('div');
            cell.className = 'icon-cell is-off';
            cell.dataset.id = ic.id;
            const color = (saved[ic.id] && saved[ic.id].color) || ic.color;
            cell.dataset.baseColor = color;   // restore target when no dynamic override
            cell.style.setProperty('--c', color);
            cell.innerHTML =
                '<div class="beam"></div>' +
                '<svg class="ring" viewBox="0 0 36 36">' +
                    '<circle class="ring-bg" cx="18" cy="18" r="15.5"/>' +
                    '<circle class="ring-fg" cx="18" cy="18" r="15.5"/>' +
                '</svg>' +
                '<div class="glyph">' + faIcon(ic.icon) + '</div>';
            // Voice/mic lives in its own bottom-right dock, not the left cluster.
            if (ic.id === 'voice' && voiceDock) voiceDock.appendChild(cell);
            else cluster.appendChild(cell);
        });
        built = true;
    }

    const CIRC = 2 * Math.PI * 15.5;  // ring circumference

    function setCell(id, opts) {
        const cell = cluster.querySelector('.icon-cell[data-id="' + id + '"]')
            || (voiceDock && voiceDock.querySelector('.icon-cell[data-id="' + id + '"]'));
        if (!cell) return;
        // visibility — animate via .is-off (fade + collapse); siblings reflow.
        // (Display mode incl. 'hidden' is resolved in update() → opts.visible.)
        const hidden = !opts.visible;
        cell.classList.toggle('is-off', hidden);
        if (hidden) return;
        // progress ring (pct 0..100, or null = no ring, just glyph)
        const fg = cell.querySelector('.ring-fg');
        if (opts.pct == null) {
            fg.style.strokeDasharray = '0 ' + CIRC;
        } else {
            const p = Math.max(0, Math.min(100, opts.pct));
            fg.style.strokeDasharray = (CIRC * p / 100) + ' ' + CIRC;
        }
        // dynamic colour override (e.g. engine health gradient). When absent,
        // restore the icon's base colour (saved override or config default).
        cell.style.setProperty('--c', opts.color || cell.dataset.baseColor || '#00c8ff');
        // warn pulse
        cell.classList.toggle('warn', !!opts.warn);
        // active highlight (e.g. talking, nitro active)
        cell.classList.toggle('active', !!opts.active);
        // purge cue (NOS purging) — distinct fast pulse
        cell.classList.toggle('purge', !!opts.purge);
    }

    // Clamp helper — ps-hud's capAmountToHundred.
    function cap(v) { v = Number(v) || 0; return v < 0 ? 0 : (v > 100 ? 100 : v); }

    // Value 0..100 → colour fading red (0) → orange/yellow (50) → green (100).
    // Two-stop lerp through yellow at the midpoint.
    function healthGradient(pct) {
        pct = cap(pct);
        const red = [0xf8, 0x71, 0x71];     // #f87171
        const yel = [0xf5, 0xc5, 0x18];     // #f5c518
        const grn = [0x34, 0xd3, 0x99];     // #34d399
        const lerp = (a, b, t) => Math.round(a + (b - a) * t);
        let c;
        if (pct <= 50) {
            const t = pct / 50;
            c = red.map((v, i) => lerp(v, yel[i], t));
        } else {
            const t = (pct - 50) / 50;
            c = yel.map((v, i) => lerp(v, grn[i], t));
        }
        return '#' + c.map((v) => v.toString(16).padStart(2, '0')).join('');
    }

    // Map raw status data → per-icon {visible, pct, warn, active}. This mirrors
    // ps-hud's playerStatusHudStore logic 1:1 (default dynamicIcons = OFF, i.e.
    // icons only show when relevant). Do NOT "improve" the thresholds — they are
    // ps-hud's exact rules so behaviour matches what players expect.
    function update(msg) {
        if (!built) return;
        const show = msg.show;
        const inVeh = msg.inVehicle;
        const d = msg.data || {};

        // DEBUG: force every icon visible with a demo ring so all styles/positions
        // can be checked at once (HKHudConfig.DebugAllIcons).
        if (msg.debugAll) {
            iconCfg.forEach((ic, i) => {
                setCell(ic.id, { visible: true, pct: 40 + (i * 7) % 60, warn: false, active: false });
            });
            return;
        }

        // pre-compute the progress values (ps-hud does these first)
        const val = {
            health:    cap(d.health),
            armor:     cap(d.armor),
            hunger:    cap(d.hunger),
            thirst:    cap(d.thirst),
            stress:    cap(d.stress),
            oxygen:    cap(d.oxygen),
            voice:     cap(d.voice || 0),   // already 0..100 (mode-based) from Lua
            parachute: cap(d.parachute),
            engine:    cap(d.engine),               // engine is /10 already (0..100)
            nitro:     cap(d.nos || 0),
        };
        const engineRaw = (d.engine == null) ? -1 : d.engine;  // <0 = on foot

        iconCfg.forEach((ic) => {
            const id = ic.id;
            let o = { visible: true, pct: null, warn: false, active: false };
            if (!show) { setCell(id, { visible: false }); return; }

            switch (id) {
                // ---- always-relevant player stats (hidden at full / zero) ----
                case 'health':
                    o.pct = d.dead ? 100 : val.health;
                    o.visible = d.dead ? true : (val.health < 100);   // hundred-handle
                    o.warn = d.dead || val.health <= 20;
                    break;
                case 'armor':
                    o.pct = val.armor; o.visible = val.armor !== 0;   // zero-handle
                    break;
                case 'hunger':
                    o.pct = val.hunger; o.visible = val.hunger < 100;
                    o.warn = d.hunger <= 30;
                    break;
                case 'thirst':
                    o.pct = val.thirst; o.visible = val.thirst < 100;
                    o.warn = d.thirst <= 30;
                    break;
                case 'stress':
                    o.pct = val.stress; o.visible = val.stress !== 0;
                    o.warn = val.stress >= 60;
                    break;
                case 'oxygen':
                    o.pct = val.oxygen; o.visible = val.oxygen < 100;
                    o.warn = val.oxygen <= 20;
                    break;
                // ---- voice: ring = mode (33/66/100); headset swap; talk glow ----
                case 'voice':
                    o.pct = val.voice;
                    o.active = !!(d.talking || d.radioTalking);
                    // icon swap handled below (radioChannel)
                    break;
                // ---- boolean indicators ----
                case 'parachute':
                    o.visible = (d.parachute != null && d.parachute >= 0); o.pct = null; break;
                // ---- vehicle-context ----
                case 'engine':
                    // show in-car when <95% and >=0 (on foot engineRaw<0 → hide)
                    o.pct = val.engine;
                    o.visible = (engineRaw >= 0 && engineRaw < 95);
                    // colour fades green → yellow/orange → red as health drops
                    o.color = healthGradient(val.engine);
                    o.warn = false;   // colour conveys severity; no red-pulse override
                    break;
                case 'nitro':
                    // show when nos>0 AND engine present (in a car).
                    o.pct = val.nitro;
                    o.visible = (val.nitro > 0 && engineRaw > 0);
                    o.active = !!(d.nitroActive && d.nitroActive !== 0);
                    o.purge = !!d.nosPurge;   // purging → distinct cue
                    break;
                case 'harness':
                    o.visible = !!(d.harness && d.harness !== 0); o.pct = null; break;
                case 'cruise':
                    o.visible = !!d.cruise; o.pct = null; o.active = true; break;
                default: o.visible = false;
            }

            // ---- Apply the player's display MODE (ps-hud style), ALL icons ----
            // 'hidden'  → never show.
            // 'always'  → force visible (vehicle icons still require being in a car).
            // 'dynamic' → keep the relevance rule computed above.
            const mode = (saved[id] && saved[id].mode) || ic.modeDefault || 'dynamic';
            if (mode === 'hidden') {
                o.visible = false;
            } else if (mode === 'always') {
                o.visible = ic.vehicle ? inVeh : true;
                if (o.pct == null && id !== 'voice') o.pct = (val[id] != null ? val[id] : null);
            }

            setCell(id, o);

            // Voice icon swaps microphone <-> headset on radio channel (ps-hud).
            if (id === 'voice') {
                const cell = cluster.querySelector('.icon-cell[data-id="voice"]')
                    || (voiceDock && voiceDock.querySelector('.icon-cell[data-id="voice"]'));
                if (cell) {
                    const iEl = cell.querySelector('.glyph i');
                    if (iEl) {
                        const wantRadio = (d.radioChannel && d.radioChannel > 0);
                        iEl.className = 'fa-solid ' + (wantRadio ? 'fa-headset' : 'fa-microphone');
                    }
                }
            }
        });
    }

    function applyTheme(t) {
        theme = t || 'hk';
        hud.className = 'theme-' + theme;
    }

    let moneyTimer = null;
    function showMoney(kind, amount) {
        const sign = amount >= 0 ? '' : '-';
        moneyToast.textContent = (kind === 'bank' ? '🏦 ' : '💵 ') + sign + '$' +
            Math.abs(Number(amount) || 0).toLocaleString('en-US');
        moneyToast.classList.remove('hidden');
        clearTimeout(moneyTimer);
        moneyTimer = setTimeout(() => moneyToast.classList.add('hidden'), 3000);
    }

    // Auto money-change popup: green +$ (received) / red -$ (spent), with the
    // new balance under it. Appears on every money change, then fades out.
    const moneyChangeEl = document.getElementById('money-change');
    function moneyChange(kind, amount, minus, balance) {
        if (!moneyChangeEl) return;
        const amt = Math.abs(Number(amount) || 0).toLocaleString('en-US');
        const pill = document.createElement('div');
        pill.className = 'mc-pill ' + (minus ? 'minus' : 'plus');
        pill.innerHTML =
            '<span class="mc-delta">' + (minus ? '-' : '+') + '$' + amt + '</span>' +
            '<span class="mc-meta">' + (kind === 'bank' ? '🏦' : '💵') +
                (balance != null ? ' $' + Number(balance).toLocaleString('en-US') : '') + '</span>';
        moneyChangeEl.appendChild(pill);
        // Cap the visible stack at 6 — some legit events fire a burst of money
        // changes; drop the oldest so the column never spams past 6 pills.
        while (moneyChangeEl.children.length > 6) {
            moneyChangeEl.removeChild(moneyChangeEl.firstElementChild);
        }
        // animate in, then out + remove
        requestAnimationFrame(() => pill.classList.add('show'));
        setTimeout(() => {
            pill.classList.remove('show');
            setTimeout(() => pill.remove(), 350);
        }, 2600);
    }

    // ---- External buff/enhancement pills (ps-hud contract) ----
    // data (buff): { display, iconName, buffName, progressValue, progressColor, iconColor }
    // data (enhancement): { display, enhancementName, iconColor }
    const extStatusEl = document.getElementById('external-status');
    function externalStatus(topic, d) {
        if (!extStatusEl || !d) return;
        const key = topic + ':' + (d.buffName || d.enhancementName || d.iconName || 'x');
        let pill = extStatusEl.querySelector('[data-k="' + CSS.escape(key) + '"]');
        if (d.display === false) { if (pill) pill.remove(); return; }
        if (!pill) {
            pill = document.createElement('div');
            pill.className = 'ext-pill';
            pill.dataset.k = key;
            extStatusEl.appendChild(pill);
        }
        const col = d.progressColor || d.iconColor || '#00c8ff';
        pill.style.setProperty('--c', col);
        const pct = (d.progressValue != null) ? Math.max(0, Math.min(100, d.progressValue)) : null;
        pill.innerHTML =
            (d.iconName ? '<i class="fa-solid fa-' + esc(String(d.iconName)) + '"></i>' : '') +
            (pct != null ? '<span class="ext-bar"><span style="width:' + pct + '%"></span></span>' : '');
    }

    // ---- Crosshair ----
    // Build the SVG lines/shapes for the current style + on-target scale.
    function drawCrosshair() {
        if (!xhairCfg) return;
        const c = xhairCfg;
        const onT = xhairOnTarget && c.mode === 'dynamic';
        // Whole-crosshair uniform scale via CSS transform (NOT per-line resize),
        // so on-target = the entire crosshair shrinks uniformly. Smaller = on target.
        xhairSvg.style.transform = onT ? 'scale(0.7)' : 'scale(1)';
        const size = Math.max(1, c.size);
        const gap  = Math.max(0, c.gap);
        const th   = c.thickness;
        const col  = onT && c.onTargetColor ? c.onTargetColor : c.color;
        const parts = [];
        const line = (x1, y1, x2, y2) =>
            `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${col}" stroke-width="${th}" stroke-linecap="round"${c.outline ? ' class="ol"' : ''}/>`;
        const style = c.style;

        if (style === 'cross' || style === 't') {
            parts.push(line(-(gap + size), 0, -gap, 0));  // left
            parts.push(line(gap, 0, gap + size, 0));      // right
            parts.push(line(0, gap, 0, gap + size));      // bottom
            if (style !== 't') parts.push(line(0, -(gap + size), 0, -gap)); // top (T = no top)
        }
        if (style === 'circle') {
            parts.push(`<circle cx="0" cy="0" r="${gap + size / 2}" fill="none" stroke="${col}" stroke-width="${th}"${c.outline ? ' class="ol"' : ''}/>`);
        }
        // Dot: drawn for the dot-only style OR when the Center Dot toggle is on.
        // (No 'crossdot' style — the toggle covers that, avoiding a double dot.)
        if (style === 'dot' || c.dot) {
            parts.push(`<circle cx="0" cy="0" r="${Math.max(1, th * 0.9)}" fill="${col}"${c.outline ? ' class="oldot"' : ''}/>`);
        }
        xhairSvg.innerHTML = parts.join('');
        xhairSvg.style.opacity = (c.opacity == null ? 90 : c.opacity) / 100;
    }

    function applyCrosshairSettings(cfg) {
        xhairCfg = cfg || null;
        // if disabled, ensure hidden
        if (!xhairCfg || !xhairCfg.enabled) { xhairEl.classList.add('hidden'); return; }
        drawCrosshair();
    }

    // ---- Compass ----
    // A degree bar panned by heading. We render 3 copies of the 0..360 pattern
    // (at -360, 0, +360) so it wraps seamlessly, and pan the SVG viewBox to
    // heading-90 .. heading+90 (a 180° window centred on the pointer).
    const cmpEl = document.getElementById('compass');
    const cmpTicks = document.getElementById('cmp-ticks');
    const cmpBearing = document.getElementById('cmp-bearing');
    const cmpDeg = document.getElementById('cmp-degrees');
    const cmpS1 = document.getElementById('cmp-s1');
    const cmpS2 = document.getElementById('cmp-s2');
    let cmpBuilt = false;
    let cmpCurrent = 0, cmpTarget = 0, cmpRAF = 0;

    // rAF tween of the compass heading toward cmpTarget (optimized mode). Moves
    // along the SHORT path around the 0/360 wrap so it never spins the long way.
    function cmpAnimate() {
        let diff = cmpTarget - cmpCurrent;
        // shortest angular direction
        if (diff > 180) diff -= 360; else if (diff < -180) diff += 360;
        if (Math.abs(diff) < 0.3) {
            cmpCurrent = cmpTarget;
            setCompassViewBox(cmpCurrent);
            cmpRAF = 0;
            return;
        }
        cmpCurrent += diff * 0.18;              // ease toward target
        if (cmpCurrent < 0) cmpCurrent += 360; else if (cmpCurrent >= 360) cmpCurrent -= 360;
        setCompassViewBox(cmpCurrent);
        cmpRAF = requestAnimationFrame(cmpAnimate);
    }

    function buildCompass() {
        // ticks every 15°, taller at the cardinals/inter-cardinals (every 45°)
        const ticks = [], bearings = [];
        const labels = { 0: 'N', 45: 'NE', 90: 'E', 135: 'SE', 180: 'S', 225: 'SW', 270: 'W', 315: 'NW', 360: 'N' };
        for (let rep = -1; rep <= 1; rep++) {
            const base = rep * 360;
            for (let d = 0; d <= 360; d += 15) {
                const x = base + d;
                const major = (d % 45 === 0);
                const h = major ? 20 : 9;
                const w = major ? 2 : 1.2;
                ticks.push('<rect x="' + x + '" y="0" width="' + w + '" height="' + h +
                    '" fill="#ffffff" fill-opacity="0.85"/>');
                if (major && labels[d] !== undefined) {
                    const isCard = (d % 90 === 0);
                    const col = (labels[d] === 'N') ? '#f5c518' : (isCard ? '#ffffff' : '#c8c8c8');
                    bearings.push('<text x="' + x + '" y="12" text-anchor="middle" ' +
                        'fill="' + col + '" font-size="' + (isCard ? 11 : 8) + '" ' +
                        'font-weight="700">' + labels[d] + '</text>');
                }
            }
        }
        cmpTicks.innerHTML = ticks.join('');
        cmpBearing.innerHTML = bearings.join('');
        cmpBuilt = true;
    }

    // Apply a heading to the compass viewBox (180° window centred on pointer).
    function setCompassViewBox(h) {
        const vb = (h - 90) + ' 0 180 24';
        cmpTicks.setAttribute('viewBox', vb);
        cmpBearing.setAttribute('viewBox', vb);
    }

    function updateCompass(msg) {
        if (!cmpBuilt) buildCompass();
        if (!msg.show) { cmpEl.classList.add('hidden'); if (cmpRAF) { cancelAnimationFrame(cmpRAF); cmpRAF = 0; } return; }
        cmpEl.classList.remove('hidden');
        const h = msg.heading || 0;

        if (msg.smooth) {
            // OPTIMIZED (low resource): the Lua tick is slow (~250ms), so we
            // JS-tween the viewBox toward the new heading here (short-path around
            // the 0/360 wrap) — cheap rAF interpolation, no per-frame Lua work.
            cmpTarget = h;
            if (!cmpRAF) cmpAnimate();
        } else {
            cmpCurrent = h;
            setCompassViewBox(h);
        }
        // degrees text
        cmpDeg.textContent = msg.degrees ? (h + '°') : '';
        cmpDeg.style.display = msg.degrees ? '' : 'none';
        // pointer
        document.getElementById('cmp-pointer').style.display = msg.pointer ? '' : 'none';
        // streets
        if (msg.streets) {
            cmpS1.textContent = msg.street1 || '';
            cmpS2.textContent = msg.street2 || '';
            cmpS1.parentElement.style.display = '';
        } else {
            cmpS1.parentElement.style.display = 'none';
        }
    }

    window.addEventListener('message', (ev) => {
        const msg = ev.data || {};
        switch (msg.action) {
            case 'settings':
                iconCfg   = msg.icons || [];
                saved     = msg.saved || {};
                warnBelow = msg.warnBelow || {};
                applyTheme(msg.theme);
                if (msg.statusPos) hud.setAttribute('data-pos', msg.statusPos);
                buildIcons();
                if (msg.crosshair && msg.crosshair.current) applyCrosshairSettings(msg.crosshair.current);
                break;
            case 'status':
                update(msg);
                break;
            case 'hide':
                if (built) document.querySelectorAll('.icon-cell').forEach((c) => c.classList.add('is-off'));
                break;
            case 'money':
                showMoney(msg.kind, msg.amount);
                break;
            case 'moneychange':
                moneyChange(msg.kind, msg.amount, msg.minus, msg.balance);
                break;
            case 'externalstatus':
                externalStatus(msg.topic, msg.data);
                break;
            case 'compass':
                updateCompass(msg);
                break;
            case 'crosshair':
                if (!xhairCfg || !xhairCfg.enabled || !msg.show) {
                    xhairEl.classList.add('hidden');
                } else {
                    xhairOnTarget = !!msg.onTarget;
                    drawCrosshair();
                    xhairEl.classList.remove('hidden');
                }
                break;
        }
    });
})();

