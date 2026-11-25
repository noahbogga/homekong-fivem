/* ═══════════════════════════════════════════════════════════════ *
 *  HK-CHAT — NUI (vanilla, no framework)                            *
 *  Keyboard-only tabbed dock (top-left): idle feed, open panel,     *
 *  Global aggregation, per-tab lists, whisper, timestamps, command  *
 *  palette + live preview, and a keyboard-navigable admin panel.    *
 *  NO mouse handlers anywhere — all navigation is via keys.         *
 * ═══════════════════════════════════════════════════════════════ */
(function () {
    'use strict';

    const RES = 'hk-chat';
    const el = {
        chat: document.getElementById('chat'),
        tabs: document.getElementById('tabs'),
        stream: document.getElementById('stream'),
        inputRow: document.getElementById('inputRow'),
        selfId: document.getElementById('selfId'),
        inputTab: document.getElementById('inputTab'),
        input: document.getElementById('input'),
        preview: document.getElementById('preview'),
        palette: document.getElementById('palette'),
        roster: document.getElementById('roster'),
        adminOverlay: document.getElementById('adminOverlay'),
        adminFilter: document.getElementById('adminFilter'),
        adminList: document.getElementById('adminList'),
        adminSections: document.getElementById('adminSections'),
        secCommands: document.getElementById('secCommands'),
        secPlayers: document.getElementById('secPlayers'),
        secMessages: document.getElementById('secMessages'),
        playerList: document.getElementById('playerList'),
        msgList: document.getElementById('msgList'),
        adminFoot: document.getElementById('adminFoot'),
    };

    const state = {
        cfg: null,
        tabs: [],
        aggregates: [],       // channels mirrored into Global
        activeTab: 'global',
        open: false,
        messages: {},         // { tabId: [ {…} ] }
        commands: [],         // viewer-filtered palette command list
        nicks: {},
        jobRoom: 'unemployed',
        selfId: 0,             // our own server id, shown in the input-bar pill
        paletteSel: 0,
        paletteView: [],
        idleTimer: null,
        MAX_PER_TAB: 50,   // cap the on-screen log per tab (Global etc. show last 50)
        showTs: true,
        // input history recall (terminal-style up/down)
        sentHistory: [],      // past submitted lines, oldest → newest
        histIndex: -1,        // -1 = not browsing; else index into sentHistory
        histDraft: '',        // what was typed before we started browsing
        HIST_MAX: 50,
        // send cooldown (anti-spam) — greys the whole bar for `cooldownUntil`
        cooldownUntil: 0,     // performance.now() ms when the bar unlocks
        cooldownTimer: null,
        // admin panel
        adminOpen: false,
        adminSection: 'commands',  // commands | players | messages
        adminAll: [],         // full command list w/ toggles (admins only)
        adminView: [],
        adminSel: 0,
        players: [],          // online players + mute state (admin)
        playersView: [],
        playerSel: 0,
        recent: [],           // recent public messages (admin remove)
        recentView: [],
        recentSel: 0,
        isAdmin: false,
    };

    function setSelfId(id) {
        if (id == null || id <= 0) return;
        state.selfId = id;
        el.selfId.textContent = '#' + id;
    }

    function post(cb, data) {
        return fetch(`https://${RES}/${cb}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data || {}),
        }).catch(() => {});
    }

    function esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    /* ── message store + Global aggregation ────────────────────── */
    function pushMessage(m) {
        const tab = m.tab || 'global';
        store(tab, m);

        // Mirror allowed channels into Global (the unified personal feed). We
        // only ever receive messages we're allowed to see, so this is safe.
        // `noMirror` lines (e.g. private /911) stay in their own tab only.
        if (tab !== 'global' && !m.noMirror && state.aggregates.indexOf(tab) !== -1) {
            store('global', Object.assign({ _mirror: tab }, m));
            if (state.activeTab === 'global') renderStream();
        }

        if (tab !== state.activeTab) markUnread(tab, true);
        if (tab === state.activeTab) renderStream();
        bumpIdle();
    }

    function store(tab, m) {
        if (!state.messages[tab]) state.messages[tab] = [];
        const arr = state.messages[tab];
        arr.push(m);
        if (arr.length > state.MAX_PER_TAB) arr.shift();
    }

    // Admin removed a message everywhere: drop every copy (incl. Global mirror)
    // matching this mid across all tabs, then re-render the active tab.
    function removeByMid(mid) {
        if (mid == null) return;
        for (const tab in state.messages) {
            state.messages[tab] = state.messages[tab].filter((m) => m.mid !== mid);
        }
        renderStream();
    }

    /* ── rendering: one message line ───────────────────────────── */
    function renderLine(m) {
        const div = document.createElement('div');
        let cls = 'msg';
        if (m.system) cls += ' system';
        if (m.me) cls += ' me';
        if (m.history) cls += ' history';
        div.className = cls;

        let html = '';

        // Timestamp prefix (server-stamped HH:MM).
        if (state.showTs && m.stamp) html += `<span class="ts">${esc(m.stamp)}</span>`;

        // Channel/emergency tag pill (JOB green, OOC, EMERGENCY, ANNOUNCE…).
        // This doubles as the Global-mirror origin marker, so we don't add a
        // separate mirror tag when the line already carries its own.
        if (m.tag) {
            const c = m.color || 'var(--gold)';
            html += `<span class="tag" style="color:${esc(c)};background:${hexToSoft(c)};border:1px solid ${esc(c)}">${esc(m.tag)}</span>`;
        } else if (m._mirror && m._mirror !== 'gameplay') {
            // Mirrored line with no tag of its own: show its origin channel.
            // Whisper gets a PINK pill (matches the whisper channel colour);
            // anything else is a neutral grey origin marker.
            const label = m._mirror.toUpperCase();
            if (m._mirror === 'whisper') {
                const pink = '#c084fc';
                html += `<span class="tag" style="color:${pink};background:${hexToSoft(pink)};border:1px solid ${pink}">${esc(label)}</span>`;
            } else {
                html += `<span class="tag" style="color:var(--fg-dim);background:rgba(255,255,255,0.05);border:1px solid var(--border)">${esc(label)}</span>`;
            }
        }

        // Whisper direction — ID ONLY between players. Admin DMs (from txAdmin)
        // have no meaningful player id, so they show the admin's name instead.
        if ((m.tab === 'whisper' || m._mirror === 'whisper') && !m.system) {
            if (m.adminDm) {
                html += `<span class="wdir">${esc(m.fromName || 'ADMIN')} →</span> `;
            } else if (m.dir === 'out') {
                html += `<span class="wdir">→ [${esc(m.toId)}]</span> `;
            } else {
                html += `<span class="wdir">[${esc(m.id)}] →</span> `;
            }
            html += `<span class="body">${esc(m.text)}</span>`;
            div.innerHTML = html;
            return div;
        }

        // Normal line: Name: text  (NO id chip — Global/Gameplay/Job show the
        // nickname/char-name only. The server id is shown in Whisper, which is
        // handled in its own branch above.)
        if (m.name) {
            const nc = m.color || 'var(--fg)';
            html += `<span class="name" style="color:${esc(nc)}">${esc(m.name)}</span>`;
            if (!m.system) html += `<span class="body">: </span>`;
        }
        html += `<span class="body">${esc(m.text)}</span>`;
        div.innerHTML = html;
        return div;
    }

    function hexToSoft(c) {
        if (c && c.startsWith('#') && c.length === 7) {
            const r = parseInt(c.slice(1, 3), 16),
                  g = parseInt(c.slice(3, 5), 16),
                  b = parseInt(c.slice(5, 7), 16);
            return `rgba(${r},${g},${b},0.14)`;
        }
        return 'rgba(255,255,255,0.06)';
    }

    function renderStream() {
        // If the user has paged up to read back, DON'T yank them to the bottom
        // when a new line arrives — only auto-follow when already near the end.
        const nearBottom =
            el.stream.scrollHeight - el.stream.scrollTop - el.stream.clientHeight < 60;

        const arr = state.messages[state.activeTab] || [];
        el.stream.innerHTML = '';
        const list = state.open ? arr : arr.slice(-(state.cfg ? state.cfg.idleMessages : 12));
        for (const m of list) el.stream.appendChild(renderLine(m));

        // Idle preview + first render + already-at-bottom → pin to newest.
        if (!state.open || nearBottom) el.stream.scrollTop = el.stream.scrollHeight;
    }

    // Page the open stream up/-1 or down/+1 by ~90% of the visible height.
    function scrollStream(dir) {
        if (!state.open) return;
        const page = Math.max(40, el.stream.clientHeight * 0.9);
        el.stream.scrollTop += dir * page;
    }

    // Briefly flash a rejection hint WITHOUT wiping the draft. We post a system
    // line to the active tab's stream (visible even with text in the box) and
    // pulse the input border red.
    let hintTimer = null;
    function flashInputHint(text) {
        el.inputRow.classList.add('reject');
        pushMessage({ tab: state.activeTab, system: true, color: '#f87171', text: text });
        if (hintTimer) clearTimeout(hintTimer);
        hintTimer = setTimeout(() => el.inputRow.classList.remove('reject'), 1400);
    }

    /* ── tabs (no click handlers — keyboard only) ──────────────── */
    function renderTabs() {
        el.tabs.innerHTML = '';
        state.tabs.forEach((t) => {
            const d = document.createElement('div');
            d.className = 'tab' + (t.id === state.activeTab ? ' active' : '');
            d.style.setProperty('--tab-color', t.color || 'var(--accent)');
            d.dataset.id = t.id;
            d.innerHTML =
                `<span class="tab-label">${esc(t.label)}</span>` +
                `<span class="tab-zh">${esc(t.zh || '')}</span>` +
                `<span class="dot"></span>`;
            el.tabs.appendChild(d);
        });
    }

    function markUnread(tabId, on) {
        const node = el.tabs.querySelector(`.tab[data-id="${tabId}"]`);
        if (node) node.classList.toggle('unread', !!on);
    }

    function setTab(id) {
        if (!state.tabs.some((t) => t.id === id)) return;
        state.activeTab = id;
        const def = currentTabDef();
        el.inputTab.textContent = def ? def.label : id;
        el.inputTab.style.color = def && def.color ? def.color : 'var(--accent)';
        el.tabs.querySelectorAll('.tab').forEach((n) =>
            n.classList.toggle('active', n.dataset.id === id));
        markUnread(id, false);
        updateInputForTab();
        renderStream();

        // Job tab: ask the server who's online in my job (roster header).
        if (id === 'job') { post('requestRoster', {}); }
        renderRoster();
    }

    // Roster header — only visible on the Job tab while the panel is open.
    function renderRoster() {
        const show = state.open && state.activeTab === 'job';
        el.roster.classList.toggle('hidden', !show);
        if (!show) return;
        const r = state.roster || { room: '', list: [] };
        const chips = r.list.map((p) =>
            `<span class="rchip ${p.me ? 'me' : ''}">[${esc(p.id)}] ${esc(p.name)}</span>`
        ).join('');
        el.roster.innerHTML =
            `<span class="roster-title">ON DUTY · ${esc((r.room || '').toUpperCase())} · ${r.list.length}</span>` +
            `<div class="roster-chips">${chips || '<span class="rchip empty">No one else online</span>'}</div>`;
    }

    function currentTabDef() {
        return state.tabs.find((t) => t.id === state.activeTab);
    }

    // We NEVER disable the input (a disabled input can't receive Tab/Esc keys,
    // which was the tab-cycle bug). Each tab gets its own guidance placeholder.
    function updateInputForTab() {
        // Don't clobber the live "Cooling down… Ns" placeholder.
        if (cooldownActive()) return;
        const id = state.activeTab;
        let ph;
        if (id === 'whisper') {
            ph = 'ID space message  (e.g.  12 hey)  =  /w 12 hey on Global';
        } else if (id === 'gameplay') {
            ph = 'Gameplay-related only — /ooc, /911 …  (type / for commands)';
        } else if (id === 'job') {
            ph = 'Message your job — Tab to switch, / for commands';
        } else {
            ph = 'Say something…  (type / for commands)';
        }
        el.input.placeholder = ph;
    }

    function cycleTab(dir) {
        const n = state.tabs.length;
        const idx = state.tabs.findIndex((t) => t.id === state.activeTab);
        const next = ((idx === -1 ? 0 : idx) + dir + n) % n;   // wraps both ways
        setTab(state.tabs[next].id);
    }

    /* ── idle fade ─────────────────────────────────────────────── */
    function bumpIdle() {
        if (state.open) return;
        el.chat.classList.remove('faded');
        if (state.idleTimer) clearTimeout(state.idleTimer);
        const after = state.cfg ? state.cfg.idleFadeAfter : 12000;
        state.idleTimer = setTimeout(() => el.chat.classList.add('faded'), after);
    }

    /* ── open / close the focused panel ────────────────────────── */
    function openPanel() {
        if (state.open) return;
        state.open = true;
        el.chat.classList.remove('idle', 'faded');
        el.chat.classList.add('open');
        el.tabs.classList.remove('hidden');
        el.inputRow.classList.remove('hidden');
        if (state.idleTimer) clearTimeout(state.idleTimer);
        updateInputForTab();
        renderStream();
        el.input.value = '';
        el.preview.textContent = '';
        // Re-run tab entry so the Job tab requests its roster when opened onto it.
        setTab(state.activeTab);
        // If we reopened mid-cooldown, re-apply the greyed state + countdown.
        if (cooldownActive()) {
            startCooldown(state.cooldownUntil - performance.now());
        }
        // Pin to the bottom AFTER layout settles, so opening a long backlog lands
        // instantly at the newest line (no animated top→bottom sweep).
        requestAnimationFrame(() => { el.stream.scrollTop = el.stream.scrollHeight; });
        setTimeout(() => el.input.focus(), 10);
    }

    function closePanel(canceled, message) {
        if (!state.open) return;
        state.open = false;
        el.chat.classList.remove('open');
        el.chat.classList.add('idle');
        el.inputRow.classList.add('hidden');
        el.palette.classList.add('hidden');
        el.roster.classList.add('hidden');
        el.input.blur();
        el.input.value = '';
        el.preview.textContent = '';
        // Submit with the tab we were actually on. If a "/" auto-jumped us to
        // GAMEPLAY, restore the origin tab so the jump was fully transient.
        const submitTab = state.activeTab;
        if (cmdJumpTab) { state.activeTab = cmdJumpTab; cmdJumpTab = null; }
        resetHistoryBrowsing();
        post('submit', { canceled: !!canceled, message: message || '', tab: submitTab });
        renderStream();
        bumpIdle();
    }

    /* ── command palette ───────────────────────────────────────── */
    // When "/" auto-jumps us to GAMEPLAY, remember the tab we came from so we
    // can return if the player clears the slash without sending. Reset on close.
    let cmdJumpTab = null;

    function updatePalette() {
        const v = el.input.value;
        if (v[0] !== '/') { hidePalette(); return; }

        const typed = v.slice(1).split(/\s+/)[0].toLowerCase();
        const rows = state.commands.filter((c) =>
            c.name.slice(1).toLowerCase().startsWith(typed));
        state.paletteView = rows;
        // Preview-only palette: always highlight the top match (no arrow nav).
        state.paletteSel = 0;

        // Ghost completion behind the caret (only while typing the command word).
        const best = rows[0];
        const onlyCmdWord = !/\s/.test(v);
        if (best && onlyCmdWord && best.name.toLowerCase().startsWith(v.toLowerCase())
            && best.name.length > v.length) {
            el.preview.textContent = v + best.name.slice(v.length);
        } else {
            el.preview.textContent = '';
        }
        renderPalette(rows);
    }

    function renderPalette(rows) {
        if (!rows.length) {
            el.palette.innerHTML =
                `<div class="palette-head"><span class="slash">/</span> COMMANDS</div>` +
                `<div class="cmd-empty">No matching commands</div>`;
            el.palette.classList.remove('hidden');
            return;
        }
        let html = `<div class="palette-head"><span class="slash">/</span> COMMANDS · ${rows.length}</div>`;
        rows.forEach((c, i) => {
            const params = (c.params || []).map((p) => `[${esc(p.name)}]`).join(' ');
            html +=
                `<div class="cmd ${i === state.paletteSel ? 'sel' : ''}">` +
                `<span class="cmd-name">${esc(c.name)}</span>` +
                (params ? `<span class="cmd-params">${params}</span>` : '') +
                (c.help ? `<span class="cmd-help">${esc(c.help)}</span>` : '') +
                `</div>`;
        });
        el.palette.innerHTML = html;
        el.palette.classList.remove('hidden');
        const sel = el.palette.querySelector('.cmd.sel');
        if (sel) sel.scrollIntoView({ block: 'nearest' });
    }

    function hidePalette() {
        el.palette.classList.add('hidden');
        el.preview.textContent = '';
    }

    function paletteVisible() {
        return !el.palette.classList.contains('hidden') && state.paletteView.length > 0;
    }

    function paletteComplete() {
        if (!paletteVisible()) return false;
        const c = state.paletteView[state.paletteSel] || state.paletteView[0];
        el.input.value = c.name + ' ';
        el.preview.textContent = '';
        updatePalette();
        return true;
    }

    /* ── admin panel (keyboard-navigable, 3 sections) ──────────── */
    const ADMIN_SECS = ['commands', 'players', 'messages'];

    function openAdmin() {
        if (!state.isAdmin) return;
        state.adminOpen = true;
        setAdminSection('commands');
        el.adminOverlay.classList.remove('hidden');
        el.adminFilter.value = '';
        post('requestModData', {});   // fetch players + recent messages
        applyAdminFilter();
        setTimeout(() => el.adminFilter.focus(), 10);
    }

    function closeAdmin() {
        if (!state.adminOpen) return;
        state.adminOpen = false;
        el.adminOverlay.classList.add('hidden');
        el.adminFilter.blur();
        post('close', {});
    }

    function setAdminSection(sec) {
        state.adminSection = sec;
        el.secCommands.classList.toggle('hidden', sec !== 'commands');
        el.secPlayers.classList.toggle('hidden', sec !== 'players');
        el.secMessages.classList.toggle('hidden', sec !== 'messages');
        el.adminSections.querySelectorAll('.asec').forEach((n) =>
            n.classList.toggle('active', n.dataset.sec === sec));
        el.adminFilter.placeholder =
            sec === 'commands' ? 'Filter commands…' :
            sec === 'players'  ? 'Filter players…' : 'Filter messages…';
        renderAdminFoot();
        applyAdminFilter();
    }

    function cycleAdminSection(dir) {
        const i = ADMIN_SECS.indexOf(state.adminSection);
        setAdminSection(ADMIN_SECS[(i + dir + ADMIN_SECS.length) % ADMIN_SECS.length]);
    }

    function renderAdminFoot() {
        const s = state.adminSection;
        const nav = '<span><kbd>↑</kbd><kbd>↓</kbd> Select</span><span><kbd>Tab</kbd> Section</span><span><kbd>Esc</kbd> Close</span>';
        let act = '';
        if (s === 'commands') act = '<span><kbd>←</kbd> Preview</span><span><kbd>→</kbd> Block</span>';
        else if (s === 'players') act = '<span><kbd>↵</kbd> Toggle mute</span>';
        else act = '<span><kbd>↵</kbd> Delete msg</span><span><kbd>C</kbd> Clear all</span>';
        el.adminFoot.innerHTML = act + nav;
    }

    // Re-filter + re-render whichever section is active.
    function applyAdminFilter() {
        const q = el.adminFilter.value.replace(/^\//, '').toLowerCase();
        if (state.adminSection === 'commands') {
            state.adminView = state.adminAll.filter((c) => c.name.slice(1).toLowerCase().includes(q));
            state.adminSel = Math.min(state.adminSel, Math.max(0, state.adminView.length - 1));
            renderCommands();
        } else if (state.adminSection === 'players') {
            state.playersView = state.players.filter((p) =>
                String(p.id).includes(q) || (p.name || '').toLowerCase().includes(q) ||
                (p.nick || '').toLowerCase().includes(q));
            state.playerSel = Math.min(state.playerSel, Math.max(0, state.playersView.length - 1));
            renderPlayers();
        } else {
            state.recentView = state.recent.filter((m) =>
                (m.text || '').toLowerCase().includes(q) || (m.name || '').toLowerCase().includes(q));
            state.recentSel = Math.min(state.recentSel, Math.max(0, state.recentView.length - 1));
            renderMessages();
        }
    }

    function renderCommands() {
        if (!state.adminView.length) {
            el.adminList.innerHTML = `<div class="admin-empty">No matching commands</div>`;
            return;
        }
        el.adminList.innerHTML = state.adminView.map((c, i) =>
            `<div class="acmd cols-cmd ${i === state.adminSel ? 'sel' : ''}">` +
            `<span class="acmd-name">${esc(c.name)}</span>` +
            `<span class="tgl ${c.noPreview ? 'on' : ''}">${c.noPreview ? 'HIDDEN' : 'shown'}</span>` +
            `<span class="tgl block ${c.blockChat ? 'on' : ''}">${c.blockChat ? 'BLOCKED' : 'allowed'}</span>` +
            `</div>`).join('');
        const sel = el.adminList.querySelector('.acmd.sel');
        if (sel) sel.scrollIntoView({ block: 'nearest' });
    }

    function renderPlayers() {
        if (!state.playersView.length) {
            el.playerList.innerHTML = `<div class="admin-empty">No players</div>`;
            return;
        }
        el.playerList.innerHTML = state.playersView.map((p, i) =>
            `<div class="acmd cols-ply ${i === state.playerSel ? 'sel' : ''}">` +
            `<span class="acmd-name">[${esc(p.id)}] ${esc(p.name)}` +
            (p.nick ? ` <span class="ply-nick">“${esc(p.nick)}”</span>` : '') + `</span>` +
            `<span class="tgl block ${p.muted ? 'on' : ''}">${p.muted ? 'MUTED' : 'active'}</span>` +
            `</div>`).join('');
        const sel = el.playerList.querySelector('.acmd.sel');
        if (sel) sel.scrollIntoView({ block: 'nearest' });
    }

    function renderMessages() {
        if (!state.recentView.length) {
            el.msgList.innerHTML = `<div class="admin-empty">No recent public messages</div>`;
            return;
        }
        // newest first for the admin view
        const rows = state.recentView.slice().reverse();
        el.msgList.innerHTML = rows.map((m, i) =>
            `<div class="acmd cols-msg ${i === state.recentSel ? 'sel' : ''}">` +
            `<span class="acmd-name"><span class="ts">${esc(m.stamp || '')}</span> ` +
            `<b>${esc(m.name || '')}</b>: ${esc(m.text || '')}</span>` +
            `<span class="tgl block">DELETE</span>` +
            `</div>`).join('');
        const sel = el.msgList.querySelector('.acmd.sel');
        if (sel) sel.scrollIntoView({ block: 'nearest' });
    }

    function adminMove(dir) {
        if (state.adminSection === 'commands') {
            if (!state.adminView.length) return;
            state.adminSel = (state.adminSel + dir + state.adminView.length) % state.adminView.length;
            renderCommands();
        } else if (state.adminSection === 'players') {
            if (!state.playersView.length) return;
            state.playerSel = (state.playerSel + dir + state.playersView.length) % state.playersView.length;
            renderPlayers();
        } else {
            if (!state.recentView.length) return;
            state.recentSel = (state.recentSel + dir + state.recentView.length) % state.recentView.length;
            renderMessages();
        }
    }

    // Command section: ← toggles preview, → toggles block.
    function adminToggle(which) {
        if (state.adminSection !== 'commands') return;
        const c = state.adminView[state.adminSel];
        if (!c) return;
        if (which === 'preview') c.noPreview = !c.noPreview;
        else c.blockChat = !c.blockChat;
        post('setCmd', { command: c.name, noPreview: c.noPreview, blockChat: c.blockChat });
        renderCommands();
    }

    // Clear-all needs a confirm (press C twice). Arm on first press, disarm after
    // a few seconds so a stray C doesn't wipe chat.
    let confirmClearArmed = false;
    let clearArmTimer = null;
    function armClearConfirm() {
        confirmClearArmed = true;
        const btn = document.getElementById('clearAllBtn');
        if (btn) { btn.classList.add('armed'); btn.textContent = 'PRESS C AGAIN TO CONFIRM WIPE'; }
        if (clearArmTimer) clearTimeout(clearArmTimer);
        clearArmTimer = setTimeout(() => {
            confirmClearArmed = false;
            const b = document.getElementById('clearAllBtn');
            if (b) { b.classList.remove('armed'); b.textContent = 'CLEAR ALL CHAT + HISTORY  (press C)'; }
        }, 3000);
    }

    // Enter: context action for the active section.
    function adminEnter() {
        if (state.adminSection === 'players') {
            const p = state.playersView[state.playerSel];
            if (p) post('toggleMute', { id: p.id });   // server refreshes moddata
        } else if (state.adminSection === 'messages') {
            const rows = state.recentView.slice().reverse();
            const m = rows[state.recentSel];
            if (m && m.mid != null) post('removeMsg', { mid: m.mid });
        }
    }

    /* ── input history recall (terminal-style up/down) ─────────────── */
    // Remember a submitted line (skip blanks and exact consecutive repeats).
    function recordHistory(text) {
        if (!text) return;
        const h = state.sentHistory;
        if (h[h.length - 1] === text) return;
        h.push(text);
        if (h.length > state.HIST_MAX) h.shift();
    }

    // Move through past inputs. dir -1 = older (Up), +1 = newer (Down).
    function recallHistory(dir) {
        const h = state.sentHistory;
        if (!h.length) return;

        if (state.histIndex === -1) {
            // Starting to browse: only on Up, and stash the current draft.
            if (dir !== -1) return;
            state.histDraft = el.input.value;
            state.histIndex = h.length - 1;
        } else {
            state.histIndex += dir;
        }

        if (state.histIndex >= h.length) {
            // Past the newest → restore the draft and stop browsing.
            state.histIndex = -1;
            el.input.value = state.histDraft;
        } else if (state.histIndex < 0) {
            state.histIndex = 0;
            el.input.value = h[0];
        } else {
            el.input.value = h[state.histIndex];
        }
        // Move caret to end + refresh palette/preview for the recalled text.
        const end = el.input.value.length;
        el.input.setSelectionRange(end, end);
        updatePalette();
    }

    function resetHistoryBrowsing() {
        state.histIndex = -1;
        state.histDraft = '';
    }

    /* ── send cooldown (anti-spam) ─────────────────────────────────── */
    function cooldownActive() {
        return performance.now() < state.cooldownUntil;
    }

    // Start/refresh the grey-out for `ms` and run a live countdown in the bar.
    function startCooldown(ms) {
        if (!ms || ms <= 0) return;
        state.cooldownUntil = performance.now() + ms;
        el.inputRow.classList.add('cooldown');
        el.input.setAttribute('readonly', 'readonly');
        if (state.cooldownTimer) clearInterval(state.cooldownTimer);
        const tick = () => {
            const left = state.cooldownUntil - performance.now();
            if (left <= 0) {
                clearInterval(state.cooldownTimer);
                state.cooldownTimer = null;
                state.cooldownUntil = 0;
                el.inputRow.classList.remove('cooldown');
                el.input.removeAttribute('readonly');
                updateInputForTab();          // restore normal placeholder
                if (state.open) el.input.focus();
            } else {
                el.input.placeholder = `Cooling down… ${(left / 1000).toFixed(1)}s`;
            }
        };
        tick();
        state.cooldownTimer = setInterval(tick, 100);
    }

    /* ── keyboard: chat input ──────────────────────────────────── */
    // `input` fires only on real typing (not on programmatic .value from
    // recallHistory), so editing a line exits history-browsing cleanly.
    el.input.addEventListener('input', () => {
        resetHistoryBrowsing();
        // Command safety: the moment a "/" starts the line, jump to the GAMEPLAY
        // tab (read-only). Commands still execute from any tab, but if the slash
        // is fumbled/dropped, the leftover text lands on a read-only channel and
        // can't broadcast — so an admin's "/tpm …" never leaks as public chat.
        if (el.input.value[0] === '/' && state.activeTab !== 'gameplay'
            && !cmdJumpTab && currentTabDef() && currentTabDef().post !== 'none') {
            cmdJumpTab = state.activeTab;   // remember where to return
            setTab('gameplay');
        } else if (el.input.value[0] !== '/' && cmdJumpTab) {
            // They cleared the slash before sending → return to the prior tab.
            const back = cmdJumpTab; cmdJumpTab = null; setTab(back);
        }
        updatePalette();
    });

    // Document-level so keys work even when the input isn't the focus target
    // (fixes the "clicked away, Esc/Enter dead" bug — there's no mouse now).
    document.addEventListener('keydown', (e) => {
        // Admin panel owns keys while open.
        if (state.adminOpen) {
            switch (e.key) {
                case 'Escape':     e.preventDefault(); closeAdmin(); break;
                case 'ArrowUp':    e.preventDefault(); adminMove(-1); break;
                case 'ArrowDown':  e.preventDefault(); adminMove(1); break;
                case 'ArrowLeft':  e.preventDefault(); adminToggle('preview'); break;
                case 'ArrowRight': e.preventDefault(); adminToggle('block'); break;
                case 'Tab':        e.preventDefault(); cycleAdminSection(e.shiftKey ? -1 : 1); break;
                case 'Enter':      e.preventDefault(); adminEnter(); break;
                default:
                    // "C" clears all chat — only from the MESSAGES section, and
                    // only when the filter box isn't where you're typing letters.
                    if ((e.key === 'c' || e.key === 'C') && state.adminSection === 'messages'
                        && el.adminFilter.value === '') {
                        e.preventDefault();
                        if (confirmClearArmed) { post('clearAll', {}); confirmClearArmed = false; }
                        else { armClearConfirm(); }
                    }
            }
            return;
        }

        if (!state.open) return;   // panel closed → let the game have the keys

        switch (e.key) {
            case 'Enter': {
                e.preventDefault();
                const msg = el.input.value.trim();
                // While cooling down, refuse to SEND (chat or command) but still
                // allow an empty Enter to close the panel. Server also enforces.
                if (msg !== '' && cooldownActive()) break;
                // Read-only tab (Gameplay/Whisper) + a PLAIN line = nothing to
                // send (whisper shorthand is handled server-side via /w). Instead
                // of silently dropping it (looks broken), keep the panel open and
                // show a hint — but let /commands and whisper shorthand through.
                const def = currentTabDef();
                const readonly = def && def.post === 'none';
                const isCmd = msg[0] === '/';
                const isWhisperShorthand = state.activeTab === 'whisper';
                if (msg !== '' && readonly && !isCmd && !isWhisperShorthand) {
                    flashInputHint('This channel is read-only');
                    break;   // keep panel open, keep their text
                }
                if (msg !== '') recordHistory(msg);
                resetHistoryBrowsing();
                closePanel(msg === '', msg);
                break;
            }
            case 'Escape':
                e.preventDefault();
                // First Escape dismisses the command palette (a transient popup)
                // WITHOUT losing your typed line; a second Escape closes the panel.
                if (paletteVisible()) { hidePalette(); }
                else { closePanel(true); }
                break;
            case 'Tab':
                e.preventDefault();
                if (paletteVisible()) paletteComplete();
                else cycleTab(e.shiftKey ? -1 : 1);
                break;
            case 'ArrowUp':
                // Up/Down ALWAYS recall previously-sent lines. The command
                // palette is preview-only now — no arrow navigation in it (Tab
                // completes the top match instead).
                e.preventDefault();
                recallHistory(-1);
                break;
            case 'ArrowDown':
                e.preventDefault();
                recallHistory(1);
                break;
            case 'PageUp':
                e.preventDefault();
                scrollStream(-1);
                break;
            case 'PageDown':
                e.preventDefault();
                scrollStream(1);
                break;
            case 'Home':
                e.preventDefault();
                el.stream.scrollTop = 0;
                break;
            case 'End':
                e.preventDefault();
                el.stream.scrollTop = el.stream.scrollHeight;
                break;
        }
    });

    el.adminFilter.addEventListener('input', () => {
        state.adminSel = 0; state.playerSel = 0; state.recentSel = 0;
        applyAdminFilter();
    });

    /* ── inbound messages (Lua → NUI) ──────────────────────────── */
    window.addEventListener('message', (ev) => {
        const d = ev.data || {};
        switch (d.type) {
            case 'CONFIG':
                state.cfg = d;
                state.tabs = (d.tabs || []).filter((t) => !t.phase2 || d.enableGroups);
                state.aggregates = d.globalAggregates || [];
                state.showTs = d.showTimestamps !== false;
                if (d.maxLength) el.input.maxLength = d.maxLength;
                setSelfId(d.selfId);
                renderTabs();
                setTab('global');
                break;

            case 'SELFID':
                setSelfId(d.id);
                break;

            case 'PALETTE':
                state.commands = d.commands || [];
                if (state.open) updatePalette();
                break;

            case 'CMDSETTINGS':
                state.isAdmin = !!d.isAdmin;
                state.adminAll = d.commands || [];
                if (state.adminOpen) applyAdminFilter();
                break;

            case 'MODDATA':
                state.players = d.players || [];
                state.recent = d.recent || [];
                if (state.adminOpen) applyAdminFilter();
                break;

            case 'REMOVEMSG':
                removeByMid(d.mid);
                break;

            case 'OPEN_ADMIN':
                openAdmin();
                break;

            case 'RECV':
                pushMessage(d.message || {});
                break;

            case 'HISTORY':
                (d.messages || []).forEach((m) => pushMessage(m));
                break;

            case 'NICK':
                if (d.id != null) state.nicks[d.id] = d.nick;
                break;

            case 'ROSTER':
                state.roster = { room: d.room, list: d.roster || [] };
                renderRoster();
                break;

            case 'COOLDOWN':
                // Server is authoritative on the cooldown; it only sends this to
                // non-exempt players, so exempt jobs are never greyed out.
                startCooldown(d.ms);
                break;

            case 'JOBROOM':
                state.jobRoom = d.room;
                break;

            case 'OPEN':
                openPanel();
                break;

            case 'CLEAR':
                state.messages = {};
                renderStream();
                break;

            case 'SCREEN':
                el.chat.classList.toggle('screen-hidden', !!d.hide);
                break;
        }
    });

    /* ── boot ──────────────────────────────────────────────────── */
    el.chat.classList.add('idle');
    post('loaded', {});
})();
