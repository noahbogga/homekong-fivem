// hk-race :: html/js/app.js — NUI controller (picker + admin panel)
(function () {
    'use strict';

    const $ = (s) => document.querySelector(s);
    const RES = 'hk-race';

    function post(name, body) {
        return fetch(`https://${RES}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body || {}),
        }).catch(() => {});
    }

    const picker = $('#picker');
    const admin = $('#admin');
    const raceHud = $('#race-hud');

    // Race HUD (top-right). Driven by SendNUIMessage from client/hud.lua.
    function renderRaceHud(d) {
        if (!d.show) { raceHud.classList.add('hidden'); return; }
        $('#rh-name').textContent = d.name || 'Race';
        raceHud.classList.toggle('legal', !!d.legal);
        raceHud.classList.toggle('illegal', !d.legal);
        $('#rh-cp').textContent = `${d.cp || 0}/${d.total || 0}`;
        const lapRow = document.querySelector('.rh-lap');
        if (d.isLoop) { lapRow.classList.remove('hidden'); $('#rh-lap').textContent = `${d.lap || 1}/${d.laps || 1}`; }
        else lapRow.classList.add('hidden');
        $('#rh-pos').textContent = `${d.pos || 1}/${d.racers || 1}`;
        const timeRow = document.querySelector('.rh-time');
        if (d.time) { timeRow.classList.remove('hidden'); $('#rh-time').textContent = d.time; }
        else timeRow.classList.add('hidden');
        const bestRow = document.querySelector('.rh-best');
        if (d.best) { bestRow.classList.remove('hidden'); $('#rh-best').textContent = d.best; }
        else bestRow.classList.add('hidden');
        raceHud.classList.remove('hidden');
    }

    function hideAll() {
        picker.classList.add('hidden');
        admin.classList.add('hidden');
    }

    function fmtReward(currency, amount) {
        if (!amount) return '—';
        return currency === 'coins' ? `${amount} HOMECOIN` : `$${amount.toLocaleString()}`;
    }

    function fmtTime(ms) {
        if (!ms || ms <= 0) return '--';
        const t = Math.floor(ms);
        const m = Math.floor(t / 60000);
        const s = Math.floor((t % 60000) / 1000);
        const mm = t % 1000;
        const pad = (n, l) => String(n).padStart(l, '0');
        return m > 0 ? `${m}:${pad(s, 2)}.${pad(mm, 3)}` : `${s}.${pad(mm, 3)}`;
    }

    // ===== Message handler =====
    window.addEventListener('message', (e) => {
        const d = e.data || {};
        try {
            switch (d.action) {
                case 'openPicker': return openPicker(d);
                case 'openAdmin':  return openAdmin(d);
                case 'refreshAdmin': return renderAdmin(d.tracks);
                case 'raceHud':    return renderRaceHud(d);
                case 'leaderboard': return renderLeaderboard(d.data);
                case 'close':      return hideAll();
            }
        } catch (err) {
            // Surface NUI-side errors to the F8 console (they are otherwise silent).
            post('nuiError', { where: d.action || 'unknown', msg: String(err && err.stack || err) });
        }
    });

    // ===== User picker =====
    let pkTierNames = ['Street', 'Sport', 'Super'];
    let pkMyTier = null;
    let pkSelectedTrack = null;
    let pkTierChosen = {};   // { [1..4]: bool }

    function showStep(which) {
        $('#pk-step-tracks').classList.toggle('hidden', which !== 'tracks');
        $('#pk-step-tiers').classList.toggle('hidden', which !== 'tiers');
        $('#pk-step-inrace').classList.toggle('hidden', which !== 'inrace');
        $('#pk-step-lb').classList.toggle('hidden', which !== 'lb');
    }

    // Head-2-Head top-bar control: toggle + cash bet. Reads current state from the
    // client (h2h:getState) and pushes changes back (h2h:setEnabled / h2h:setBet).
    let h2hWired = false;
    async function initH2HBar() {
        const bar = $('#pk-h2h-bar');
        const toggle = $('#pk-h2h-toggle');
        const betWrap = $('#pk-h2h-bet-wrap');
        const bet = $('#pk-h2h-bet');
        if (!bar || !toggle || !bet) return;

        // Pull current state.
        let state = { on: false, stake: 0, globalEnabled: true, maxBet: 1000000 };
        try {
            const r = await post('h2h:getState', {});
            if (r) { const j = await r.json().catch(() => null); if (j) state = Object.assign(state, j); }
        } catch (e) { /* keep defaults */ }

        // If the whole feature is disabled server-side, grey the bar out.
        bar.classList.toggle('disabled', !state.globalEnabled);
        toggle.checked = !!state.on;
        bet.value = state.stake || 0;
        if (state.maxBet) bet.max = state.maxBet;
        betWrap.classList.toggle('disabled', !state.on);

        if (h2hWired) return;   // bind listeners once
        h2hWired = true;

        toggle.addEventListener('change', () => {
            const on = toggle.checked;
            betWrap.classList.toggle('disabled', !on);
            post('h2h:setEnabled', { on });
        });

        const commitBet = () => {
            let v = parseInt(bet.value, 10);
            if (isNaN(v) || v < 0) v = 0;
            const max = parseInt(bet.max, 10) || 1000000;
            if (v > max) v = max;
            bet.value = v;
            post('h2h:setBet', { amount: v });
        };
        bet.addEventListener('change', commitBet);
        bet.addEventListener('blur', commitBet);
    }

    function openPicker(d) {
        hideAll();
        const loc = d.locales || {};
        pkTierNames = d.tierNames || pkTierNames;
        pkMyTier = d.myTier || null;
        pkSelectedTrack = null;
        pkTierChosen = {};
        $('#pk-title').textContent = loc.title || 'Street Races';
        $('#pk-subtitle').textContent = loc.subtitle || '';
        initH2HBar();
        // If already in a race, show the Leave view instead of the track list.
        if (d.inRace) {
            picker.classList.remove('hidden');
            showStep('inrace');
            return;
        }
        const list = $('#pk-list');
        const empty = $('#pk-empty');
        list.innerHTML = '';
        showStep('tracks');

        const tracks = d.tracks || [];
        if (!tracks.length) {
            empty.textContent = loc.empty || 'No tracks available.';
            empty.classList.remove('hidden');
        } else {
            empty.classList.add('hidden');
            tracks.forEach((t) => {
                const card = document.createElement('div');
                card.className = 'track-card';
                const typeBadge = t.trackType === 'loop' ? 'Loop' : 'One-way';
                const record = (t.bestLapMs && t.bestLapMs > 0)
                    ? `<span class="record clickable" title="View leaderboard">🏁 ${fmtTime(t.bestLapMs)} — ${escapeHtml(t.bestLapName || '?')} ▸</span>`
                    : `<span class="record clickable none" title="View leaderboard">No record yet ▸</span>`;
                const sc = t.suggestedTier && t.suggestedTier > 0 ? pkTierNames[t.suggestedTier - 1] : null;
                const classBadge = sc ? `<span class="class-badge">Suggested: ${escapeHtml(sc)}</span>` : '';
                const legalBadge = t.legal
                    ? `<span class="legal-badge legal">Legal</span>`
                    : `<span class="legal-badge illegal">Illegal</span>`;
                const lockArr = t.allowedTiers || [];
                const lockBadge = lockArr.length > 0
                    ? `<span class="class-badge">🔒 ${lockArr.map((x) => pkTierNames[x - 1] || ('T' + x)).join('/')}</span>`
                    : '';
                // Availability: greyed Start if the circuit is busy (someone hosting)
                // or on its post-start cooldown.
                let btnLabel = loc.start || 'Host Race';
                let disabled = false, statusBadge = '';
                if (t.busy) {
                    disabled = true; btnLabel = 'In use';
                    statusBadge = `<span class="legal-badge illegal">Being set up</span>`;
                } else if (t.cooldown && t.cooldown > 0) {
                    disabled = true;
                    const m = Math.ceil(t.cooldown / 60);
                    btnLabel = `Cooldown ${m}m`;
                    statusBadge = `<span class="legal-badge illegal">Cooldown ~${m}m</span>`;
                }
                card.innerHTML = `
                    <div class="track-info">
                        <div class="track-name">${escapeHtml(t.name)} <span class="tt-badge">${typeBadge}</span> ${legalBadge} ${statusBadge}</div>
                        <div class="track-meta">
                            <span>${t.checkpoints} checkpoints</span>
                            <span class="reward">1st: ${fmtReward(t.currency, t.p1)}</span>
                        </div>
                        <div class="track-meta">${record} ${classBadge} ${lockBadge}</div>
                    </div>
                    <div class="track-actions">
                        <button class="btn-accent"${disabled ? ' disabled' : ''}>${btnLabel}</button>
                    </div>`;
                card.querySelector('button').addEventListener('click', () => {
                    if (disabled) return;
                    pkSelectedTrack = t;
                    openTierStep();
                });
                card.querySelector('.record').addEventListener('click', () => {
                    post('picker:leaderboard', { trackId: t.id });
                });
                list.appendChild(card);
            });
        }
        picker.classList.remove('hidden');
    }

    function openTierStep() {
        $('#pk-tier-track').textContent = pkSelectedTrack ? pkSelectedTrack.name : '';
        // Laps input only for loop tracks.
        const isLoop = pkSelectedTrack && pkSelectedTrack.trackType === 'loop';
        $('#pk-laps-row').classList.toggle('hidden', !isLoop);
        // Your current tier line
        const yt = $('#pk-your-tier');
        if (pkMyTier && pkMyTier.tier) {
            yt.textContent = `Your vehicle: Class ${pkMyTier.name}`;
        } else {
            yt.textContent = 'You are on foot — tier shown when you enter a vehicle.';
        }
        // Track tier lock: only these tiers may be offered to the host (hard cap).
        const lock = (pkSelectedTrack && pkSelectedTrack.allowedTiers) || [];
        const locked = lock.length > 0;
        const allowed = {}; lock.forEach((t) => { allowed[t] = true; });
        // Build tier checkboxes (only those allowed by the track's lock).
        const tl = $('#pk-tier-list');
        tl.innerHTML = '';
        pkTierChosen = {};
        pkTierNames.forEach((name, i) => {
            const tier = i + 1;
            if (locked && !allowed[tier]) return;   // track forbids this tier entirely
            const row = document.createElement('label');
            row.className = 'tier-row';
            row.innerHTML = `
                <input type="checkbox" data-tier="${tier}">
                <span class="tier-name">Class ${escapeHtml(name)}</span>`;
            row.querySelector('input').addEventListener('change', (e) => {
                pkTierChosen[tier] = e.target.checked;
            });
            tl.appendChild(row);
        });
        // Hint when the track is locked.
        const hint = document.querySelector('#pk-step-tiers .tier-hint');
        if (hint) hint.textContent = locked
            ? 'This track is locked to specific tiers. Pick within them (or leave all off = all allowed here).'
            : 'Which vehicle tiers may join? Leave all off for no restriction.';
        showStep('tiers');
    }

    // Back to track list
    document.addEventListener('DOMContentLoaded', () => {});
    $('#pk-back').addEventListener('click', () => showStep('tracks'));
    $('#pk-leave').addEventListener('click', () => { hideAll(); post('picker:leave', {}); });
    $('#pk-lb-back').addEventListener('click', () => showStep('tracks'));

    // Render a track's leaderboard, split into per-tier sections (S / A / B) so
    // the classes don't crush together. Switches to the lb sub-view.
    function renderLeaderboard(d) {
        if (!d) return;
        const tierNames = d.tierNames || pkTierNames;
        $('#pk-lb-title').textContent = d.trackName || 'Leaderboard';
        const list = $('#pk-lb-list');
        const empty = $('#pk-lb-empty');
        list.innerHTML = '';
        const rows = d.rows || [];
        if (!rows.length) {
            empty.classList.remove('hidden');
        } else {
            empty.classList.add('hidden');
            // Bucket rows by tier index (0 = unclassified).
            const buckets = {};
            rows.forEach((r) => {
                const t = (r.tier && r.tier > 0) ? r.tier : 0;
                (buckets[t] = buckets[t] || []).push(r);
            });
            // Render fastest tier first (highest index), unclassified last.
            const order = [];
            for (let t = tierNames.length; t >= 1; t--) if (buckets[t]) order.push(t);
            if (buckets[0]) order.push(0);
            order.forEach((t) => {
                const label = t > 0 ? ('Class ' + (tierNames[t - 1] || '')) : 'Unclassified';
                const head = document.createElement('div');
                head.className = 'lb-tier-head';
                head.textContent = label;
                list.appendChild(head);
                buckets[t].forEach((r, i) => {
                    const rank = i + 1;
                    const row = document.createElement('div');
                    row.className = 'lb-row' + (rank === 1 ? ' lb-first' : '');
                    row.innerHTML = `
                        <span class="lb-rank">${rank}</span>
                        <span class="lb-time">${fmtTime(r.ms)}</span>
                        <span class="lb-name">${escapeHtml(r.name || '?')}</span>
                        <span class="lb-veh">${escapeHtml(r.vehicle || r.model || '-')}</span>`;
                    list.appendChild(row);
                });
            });
        }
        picker.classList.remove('hidden');
        showStep('lb');
    }
    $('#pk-host-go').addEventListener('click', () => {
        const allowed = [];
        for (let t = 1; t <= pkTierNames.length; t++) if (pkTierChosen[t]) allowed.push(t);
        const isLoop = pkSelectedTrack && pkSelectedTrack.trackType === 'loop';
        let laps = null;
        if (isLoop) {
            laps = parseInt($('#pk-laps').value, 10);
            if (!laps || laps < 1) laps = 1;
            if (laps > 20) laps = 20;
        }
        let minP = parseInt($('#pk-min').value, 10);
        if (!minP || minP < 1) minP = 1; if (minP > 8) minP = 8;
        post('picker:host', {
            trackId: pkSelectedTrack ? pkSelectedTrack.id : null,
            allowedTiers: allowed,   // empty = no restriction
            laps: laps,              // null for one-way
            slipstream: $('#pk-slip').checked,
            ghostMode: $('#pk-ghost').value,
            minPlayers: minP,
        });
        hideAll();
    });

    // ===== Admin panel =====
    let adminLocales = {};
    function openAdmin(d) {
        hideAll();
        adminLocales = d.locales || {};
        $('#ad-title').textContent = adminLocales.title || 'Race Administration';
        $('#ad-tracks-lbl').textContent = adminLocales.tracks || 'Tracks';
        $('#ad-new').textContent = adminLocales.newTrack || '+ Create Track';
        renderAdmin(d.tracks);
        showAdminView('tracks');   // always open on the tracks view
        admin.classList.remove('hidden');
    }

    function renderAdmin(tracks) {
        const tl = $('#ad-track-list');
        const empty = $('#ad-empty');
        tl.innerHTML = '';
        if (empty) empty.classList.toggle('hidden', (tracks || []).length > 0);
        const arr = tracks || [];
        arr.forEach((t, i) => {
            const card = document.createElement('div');
            card.className = 'track-card';
            const listedBadge = t.listed
                ? `<span class="badge on">listed</span>`
                : `<span class="badge">hidden</span>`;
            // Up/down reorder controls (disabled at the edges).
            const upDis = i === 0 ? ' disabled' : '';
            const downDis = i === arr.length - 1 ? ' disabled' : '';
            card.innerHTML = `
                <div class="track-order">
                    <button class="ord-btn up"${upDis} title="Move up">▲</button>
                    <button class="ord-btn down"${downDis} title="Move down">▼</button>
                </div>
                <div class="track-info">
                    <div class="track-name">#${t.id} ${escapeHtml(t.name)} ${listedBadge}</div>
                    <div class="track-meta">
                        <span>${t.checkpoints} CP</span>
                        <span class="reward">${fmtReward(t.currency, (t.amounts && t.amounts[0]) || 0)}</span>
                    </div>
                </div>
                <div class="track-actions">
                    <button class="btn-ghost lbmanage" title="Manage leaderboard">🏁 LB</button>
                    <button class="btn-ghost listtoggle">${t.listed ? 'Hide' : 'Show'}</button>
                    <button class="btn-ghost edit">${adminLocales.edit || 'Edit'}</button>
                    <button class="btn-danger del">${adminLocales.del || 'Delete'}</button>
                </div>`;
            if (upDis === '') card.querySelector('.ord-btn.up').addEventListener('click', () => {
                post('admin:reorderTrack', { id: t.id, dir: -1 });
            });
            if (downDis === '') card.querySelector('.ord-btn.down').addEventListener('click', () => {
                post('admin:reorderTrack', { id: t.id, dir: 1 });
            });
            card.querySelector('.lbmanage').addEventListener('click', () => {
                openLbManager(t.id, t.name);
            });
            card.querySelector('.listtoggle').addEventListener('click', () => {
                post('admin:toggleListed', { id: t.id });
            });
            card.querySelector('.edit').addEventListener('click', () => {
                post('admin:editTrack', { id: t.id });
                hideAll();
            });
            card.querySelector('.del').addEventListener('click', () => {
                post('admin:deleteTrack', { id: t.id });
            });
            tl.appendChild(card);
        });
    }

    // ===== Buttons =====
    $('#ad-new').addEventListener('click', () => post('admin:newTrack', {}));

    // ===== Car Tiers view =====
    let ctCars = [];
    let ctTierNames = ['Street', 'Sport', 'Super'];

    function showAdminView(which) {
        $('#ad-view-tracks').classList.toggle('hidden', which !== 'tracks');
        $('#ad-view-cartiers').classList.toggle('hidden', which !== 'cartiers');
        $('#ad-view-lb').classList.toggle('hidden', which !== 'lb');
    }

    function renderCarTiers(filter) {
        const list = $('#ad-ct-list');
        list.innerHTML = '';
        const f = (filter || '').toLowerCase();
        ctCars.forEach((c) => {
            const hay = ((c.name || '') + ' ' + (c.model || '')).toLowerCase();
            if (f && hay.indexOf(f) === -1) return;
            const row = document.createElement('div');
            row.className = 'ct-row';
            // Auto-detected class (what it gets with no override). "—" if hk-handling
            // has no data for this car (it'd fall back to the configured default).
            const autoLbl = c.autoName ? escapeHtml(c.autoName) : '—';
            // Provisional = no real accel/top data yet, just the default-tier guess.
            // Mark with * so an admin knows it needs a drive-by (or manual override).
            const prov = c.autoProvisional === true;
            const autoCell = prov ? `${autoLbl}*` : autoLbl;
            const autoTitle = prov
                ? 'No data yet — default guess. Drive it once to auto-calibrate, or set an override.'
                : 'Auto-detected class';
            const autoOpt = c.autoName ? `Auto (${autoLbl}${prov ? '*' : ''})` : 'Auto';
            let opts = `<option value="0"${c.override === 0 ? ' selected' : ''}>${autoOpt}</option>`;
            ctTierNames.forEach((n, i) => {
                const t = i + 1;
                opts += `<option value="${t}"${c.override === t ? ' selected' : ''}>${escapeHtml(n)}</option>`;
            });
            row.innerHTML = `
                <span class="ct-name">${escapeHtml(c.name || c.model)}<span class="ct-model">${escapeHtml(c.model || '')}</span></span>
                <span class="ct-auto${prov ? ' ct-auto-prov' : ''}" title="${autoTitle}">${autoCell}</span>
                <select class="ct-sel">${opts}</select>`;
            row.querySelector('select').addEventListener('change', (e) => {
                const tier = parseInt(e.target.value, 10);
                c.override = tier;
                post('admin:setCarTier', { hash: c.hash, tier: tier, model: c.model, name: c.name });
            });
            list.appendChild(row);
        });
    }

    $('#ad-cartiers').addEventListener('click', async () => {
        showAdminView('cartiers');
        $('#ad-ct-list').innerHTML = '<p class="empty">Loading cars...</p>';
        try {
            const resp = await fetch(`https://${RES}/admin:getCarTiers`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
            });
            const data = await resp.json();
            ctCars = (data && data.cars) || [];
            ctTierNames = (data && data.tierNames) || ctTierNames;
        } catch (e) { ctCars = []; }
        $('#ad-ct-search').value = '';
        renderCarTiers('');
    });
    $('#ad-ct-back').addEventListener('click', () => showAdminView('tracks'));
    $('#ad-ct-search').addEventListener('input', (e) => renderCarTiers(e.target.value));

    // ===== Leaderboard management view =====
    let lbTrackId = null, lbTrackName = '', lbTierNames = ['B', 'A', 'S'];

    async function loadLb() {
        $('#ad-lb-list').innerHTML = '<p class="empty">Loading...</p>';
        try {
            const resp = await fetch(`https://${RES}/admin:lbGet`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ trackId: lbTrackId }),
            });
            const data = await resp.json();
            lbTierNames = (data && data.tierNames) || lbTierNames;
            renderLbAdmin((data && data.rows) || []);
        } catch (e) { renderLbAdmin([]); }
    }

    function renderLbAdmin(rows) {
        const list = $('#ad-lb-list');
        const empty = $('#ad-lb-empty');
        list.innerHTML = '';
        if (!rows.length) { empty.classList.remove('hidden'); return; }
        empty.classList.add('hidden');
        // Rank resets per tier (matches the player view's per-tier split).
        const rankByTier = {};
        rows.forEach((r) => {
            const t = (r.tier && r.tier > 0) ? r.tier : 0;
            rankByTier[t] = (rankByTier[t] || 0) + 1;
            const rank = rankByTier[t];
            const tierName = t > 0 ? (lbTierNames[t - 1] || '') : '-';
            const row = document.createElement('div');
            row.className = 'lb-row lb-row-admin';
            row.innerHTML = `
                <span class="lb-rank">${rank}</span>
                <span class="lb-time">${fmtTime(r.ms)}</span>
                <span class="lb-name"><input class="lb-name-in" type="text" maxlength="64" value="${escapeHtml(r.name || '')}"></span>
                <span class="lb-veh">${escapeHtml(r.vehicle || r.model || '-')}</span>
                <span class="lb-tier">${escapeHtml(tierName)}</span>
                <span class="lb-adm">
                    <button class="ord-btn lb-save" title="Save name">✔</button>
                    <button class="ord-btn lb-del" title="Delete record">🗑</button>
                </span>`;
            // Rename: edit the inline field, then Save (or press Enter). CEF has no
            // window.prompt, so everything is inline.
            const input = row.querySelector('.lb-name-in');
            const saveBtn = row.querySelector('.lb-save');
            const doSave = async () => {
                const name = (input.value || '').trim();
                if (!name || name === (r.name || '')) return;   // no-op on empty/unchanged
                saveBtn.disabled = true;
                await post('admin:lbRename', { rowId: r.id, name: name });
                r.name = name;
                saveBtn.disabled = false;
                saveBtn.classList.add('lb-saved');
                setTimeout(() => saveBtn.classList.remove('lb-saved'), 900);
            };
            saveBtn.addEventListener('click', doSave);
            input.addEventListener('keydown', (e) => { if (e.key === 'Enter') doSave(); });
            // Delete: two-step confirm (button turns red "Sure?" for 3s).
            const delBtn = row.querySelector('.lb-del');
            let armed = false, armTimer = null;
            delBtn.addEventListener('click', async () => {
                if (!armed) {
                    armed = true;
                    delBtn.classList.add('lb-armed');
                    delBtn.textContent = '?';
                    delBtn.title = 'Click again to confirm delete';
                    armTimer = setTimeout(() => {
                        armed = false; delBtn.classList.remove('lb-armed');
                        delBtn.textContent = '🗑'; delBtn.title = 'Delete record';
                    }, 3000);
                    return;
                }
                if (armTimer) clearTimeout(armTimer);
                await post('admin:lbDelete', { rowId: r.id });
                loadLb();
            });
            list.appendChild(row);
        });
    }

    function openLbManager(trackId, trackName) {
        lbTrackId = trackId;
        lbTrackName = trackName || 'Race';
        $('#ad-lb-title').textContent = `Leaderboard — ${lbTrackName}`;
        showAdminView('lb');
        loadLb();
    }
    $('#ad-lb-back').addEventListener('click', () => showAdminView('tracks'));

    document.querySelectorAll('[data-close]').forEach((btn) => {
        btn.addEventListener('click', () => {
            const which = btn.getAttribute('data-close');
            hideAll();
            post(which + ':close', {});
        });
    });

    // ESC closes whichever is open.
    document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        if (!picker.classList.contains('hidden')) { hideAll(); post('picker:close', {}); }
        else if (!admin.classList.contains('hidden')) { hideAll(); post('admin:close', {}); }
    });

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }
})();
