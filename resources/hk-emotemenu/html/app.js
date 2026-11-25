(function () {
    'use strict';
    const RESOURCE = 'hk-emotemenu';

    const overlay   = document.getElementById('overlay');
    const tabsEl    = document.getElementById('tabs');
    const contentEl = document.getElementById('content');
    const searchEl  = document.getElementById('search');
    const clearEl   = document.getElementById('search-clear');
    const btnClose  = document.getElementById('btn-close');
    const btnCancel = document.getElementById('btn-cancel');
    const btnGroup  = document.getElementById('btn-group');
    const groupBadge = document.getElementById('group-badge');
    const modeChip  = document.getElementById('mode-chip');

    let catalog   = null;      // payload from Lua
    let favorites = [];        // array of emote keys (DP.Emotes)
    let recent    = [];        // array of emote keys
    let isOpen    = false;
    let activeTab = 'emotes';
    let query     = '';
    let flat      = [];        // current render order (for keyboard nav)
    let focusIdx  = 0;
    let mouseMode = false;     // false = keyboard-drive (ped free), true = cursor
    let zone      = 'content'; // 'rail' | 'content' — which column arrows drive
    let tabIdx    = 0;         // focused tab index while zone === 'rail'
    let groupOpen = false;     // group panel shown (mouse-only button, not a tab)

    // Static tab definitions. `kind` is what the play callback receives.
    const TABS = [
        { id: 'favorites', kind: 'emote', en: 'Favorites', zh: '收藏', icon: '⭐', virtual: true },
        { id: 'recent',    kind: 'emote', en: 'Recent',    zh: '最近', icon: '🕘', virtual: true },
        { id: 'emotes',    kind: 'emote', en: 'Emotes',    zh: '動作', icon: '😀', grouped: true },
        { id: 'dances',    kind: 'dance', en: 'Dances',    zh: '舞蹈', icon: '🕺' },
        { id: 'props',     kind: 'prop',  en: 'Props',     zh: '道具', icon: '📦' },
        { id: 'walks',     kind: 'walk',  en: 'Walks',     zh: '步姿', icon: '🚶', cfg: 'walks' },
        { id: 'moods',     kind: 'mood',  en: 'Moods',     zh: '心情', icon: '🙂', cfg: 'moods' },
        { id: 'shared',    kind: 'share', en: 'Shared',    zh: '雙人', icon: '👫', cfg: 'shared' },
    ];
    // NOTE: Group is intentionally NOT a tab — it's a mouse-only rail button
    // (#btn-group) so keyboard nav can never land on it. See openGroup()/closeGroup().

    // Live group state, mirrored from Lua (see the 'group' message handler).
    let groupState = { active: false, isLeader: false, leader: null, members: [], nearby: [] };
    // Server ids we've invited this session, so the Invite button stays disabled
    // across panel re-renders (avoids the leader spam-clicking a duplicate invite).
    // Entries auto-clear after ~20s (matches the server invite timeout).
    const invited = new Map();   // src -> timeout id

    function post(name, payload) {
        return fetch(`https://${RESOURCE}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload || {}),
        }).then((r) => r.json().catch(() => ({}))).catch(() => ({}));
    }

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }

    function isFav(id) { return favorites.indexOf(id) !== -1; }

    // Resolve a bare key (favorites/recent store only keys) to its {label, kind}
    // by scanning every catalog category. Recent can hold emote/dance/prop keys,
    // so we must find the REAL kind — playing a dance key as kind 'emote' looks
    // it up in the wrong table and fails.
    function resolveKey(id) {
        if (!catalog) return { label: id, kind: 'emote' };
        for (const g of catalog.emotes) {
            for (const it of g.items) if (it.id === id) return { label: it.label, kind: 'emote' };
        }
        const flatKinds = [['dances', 'dance'], ['props', 'prop']];
        for (const [key, kind] of flatKinds) {
            for (const it of (catalog[key] || [])) if (it.id === id) return { label: it.label, kind };
        }
        return { label: id, kind: 'emote' };
    }

    // ---- tabs -------------------------------------------------------------
    function availableTabs() {
        return TABS.filter((t) => {
            if (t.cfg && catalog && catalog.config && !catalog.config[t.cfg]) return false;
            // Dual/Shared emotes teleport-pair two players — hide them while in a
            // group so 3+ players can't trigger the pairing and bug out.
            if (t.id === 'shared' && groupState.active) return false;
            return true;
        });
    }

    function tabCount(t) {
        if (!catalog) return 0;
        if (t.id === 'favorites') return favorites.length;
        if (t.id === 'recent')    return recent.length;
        if (t.id === 'emotes')    return catalog.emotes.reduce((n, g) => n + g.items.length, 0);
        return (catalog[t.id] || []).length;
    }

    function renderTabs() {
        tabsEl.innerHTML = '';
        const avail = availableTabs();
        avail.forEach((t, i) => {
            const el = document.createElement('div');
            el.className = 'tab' + (t.id === activeTab ? ' active' : '') +
                (zone === 'rail' && i === tabIdx ? ' railfocus' : '');
            el.dataset.tab = t.id;
            el.innerHTML =
                '<span class="t-ico">' + esc(t.icon) + '</span>' +
                '<span class="t-txt"><span class="t-en">' + esc(t.en) + '</span>' +
                '<span class="t-zh">' + esc(t.zh) + '</span></span>' +
                '<span class="t-count">' + tabCount(t) + '</span>';
            el.addEventListener('click', () => selectTab(t.id));
            tabsEl.appendChild(el);
        });
    }

    function selectTab(id) {
        // Selecting any category tab leaves the group panel (it's an overlay page).
        if (groupOpen) { groupOpen = false; if (btnGroup) btnGroup.classList.remove('active'); }
        activeTab = id;
        const avail = availableTabs();
        const ti = avail.findIndex((t) => t.id === id);
        if (ti !== -1) tabIdx = ti;
        renderTabs();
        contentEl.scrollTop = 0;
        renderContent();
    }

    function tabDef(id) { return TABS.find((t) => t.id === id) || TABS[0]; }

    // ---- zone / rail keyboard nav -----------------------------------------
    // Left/Right arrows move between the rail (tabs) and the content grid;
    // Up/Down move within whichever zone is active.
    function enterRail() {
        zone = 'rail';
        const avail = availableTabs();
        tabIdx = Math.max(0, avail.findIndex((t) => t.id === activeTab));
        renderTabs();
    }

    function enterContent() {
        zone = 'content';
        renderTabs();       // drop railfocus styling
        setFocus(focusIdx); // restore tile highlight
    }

    function moveTab(delta) {
        const avail = availableTabs();
        if (!avail.length) return;
        tabIdx = (tabIdx + delta + avail.length) % avail.length;
        activeTab = avail[tabIdx].id;   // live-switch content as you move
        renderTabs();
        contentEl.scrollTop = 0;
        renderContent();                // focusFirst() resets tile focus to 0
    }

    // ---- tile builder -----------------------------------------------------
    // item = {id,label}; kind drives playback; showKind adds a type pill.
    function buildTile(item, kind, showKind) {
        const idx = flat.length;
        flat.push({ id: item.id, kind });

        const tile = document.createElement('div');
        tile.className = 'tile';
        tile.dataset.idx = idx;

        // Favorite star only for emote-kind tiles (favorites store DP.Emotes keys).
        const favBtn = (kind === 'emote')
            ? '<button class="fav' + (isFav(item.id) ? ' on' : '') + '" data-fav="' +
              esc(item.id) + '" title="Favorite (F)">' + (isFav(item.id) ? '★' : '☆') + '</button>'
            : '';

        const kindPill = showKind
            ? '<span class="tile-kind">' + esc(kindLabel(kind)) + '</span>'
            : '<span class="tile-key">' + esc(item.id) + '</span>';

        tile.innerHTML =
            '<span class="tile-label">' + esc(item.label) + '</span>' +
            kindPill + favBtn;

        tile.addEventListener('click', () => activate(idx));
        tile.addEventListener('mouseenter', () => setFocus(idx));
        const fb = tile.querySelector('.fav');
        if (fb) fb.addEventListener('click', (e) => { e.stopPropagation(); toggleFav(item.id); });
        return tile;
    }

    function kindLabel(kind) {
        return { emote: 'emote', dance: 'dance', prop: 'prop', walk: 'walk',
                 mood: 'mood', share: 'shared' }[kind] || kind;
    }

    function groupHeader(icon, en, zh, count) {
        const h = document.createElement('div');
        h.className = 'group-title';
        h.innerHTML =
            (icon ? '<span class="g-ico">' + esc(icon) + '</span>' : '') +
            '<span>' + esc(en) + '</span>' +
            (zh ? '<span class="g-zh">' + esc(zh) + '</span>' : '') +
            '<span class="g-count">' + count + '</span>';
        return h;
    }

    function gridOf(items, kind, showKind) {
        const grid = document.createElement('div');
        grid.className = 'grid';
        items.forEach((it) => grid.appendChild(buildTile(it, kind, showKind)));
        return grid;
    }

    function showEmpty(msg) {
        contentEl.innerHTML =
            '<div class="empty"><span class="big">🔍</span><span>' + esc(msg) + '</span></div>';
    }

    // ---- content render ---------------------------------------------------
    function renderContent() {
        contentEl.innerHTML = '';
        flat = [];

        // Members (not the leader) can't drive playback — mark the body so the
        // grid dims/locks, and drop a persistent banner so it's obvious WHY tiles
        // don't respond, instead of them tapping dead tiles and getting a toast.
        const memberLocked = groupState.active && !groupState.isLeader;
        document.body.classList.toggle('member-locked', memberLocked);

        // Group panel (mouse-only button) overrides tab content while open.
        if (groupOpen) { renderGroup(); return; }

        if (memberLocked) {
            const banner = document.createElement('div');
            banner.className = 'member-banner';
            banner.innerHTML = '<span class="mb-ico">👑</span>' +
                '<span>隊長控制緊表情 — 你會跟住隊長一齊做<br>' +
                'The leader controls the emotes — you follow along</span>';
            contentEl.appendChild(banner);
        }

        if (query) return renderSearch();

        const t = tabDef(activeTab);

        // Virtual tabs: favorites / recent (lists of keys → tiles). Recent can
        // hold emote/dance/prop keys, so resolve each key's REAL kind and build
        // tiles individually — otherwise a dance plays via the emote table (fails)
        // and shows a fav star that would corrupt the favorites list.
        if (t.id === 'favorites' || t.id === 'recent') {
            const keys = (t.id === 'favorites' ? favorites : recent);
            if (!keys.length) {
                return showEmpty(t.id === 'favorites'
                    ? '未有收藏 — 撳動作旁邊嘅 ☆ 收藏\nNo favorites yet — tap ☆ on any emote'
                    : '未有記錄 No recent emotes yet');
            }
            const grid = document.createElement('div');
            grid.className = 'grid';
            keys.forEach((k) => {
                const r = resolveKey(k);
                // showKind pill for non-emote so the type is clear; emotes keep the star.
                grid.appendChild(buildTile({ id: k, label: r.label }, r.kind, r.kind !== 'emote'));
            });
            contentEl.appendChild(grid);
            focusFirst();
            return;
        }

        // Grouped emotes tab.
        if (t.id === 'emotes') {
            catalog.emotes.forEach((g) => {
                contentEl.appendChild(groupHeader(g.icon, g.en, g.zh, g.items.length));
                contentEl.appendChild(gridOf(g.items, 'emote', false));
            });
            focusFirst();
            return;
        }


        // Flat tabs: dances / props / walks / moods / shared.
        const items = catalog[t.id] || [];
        if (!items.length) return showEmpty('空 Empty');
        contentEl.appendChild(gridOf(items, t.kind, false));
        focusFirst();
    }

    // ---- group panel ------------------------------------------------------
    function renderGroup() {
        const g = groupState;
        const wrap = document.createElement('div');
        wrap.className = 'group-panel';

        // Panel header with a back button (returns to the emote tabs).
        const top = document.createElement('div');
        top.className = 'grp-top';
        top.innerHTML =
            '<span class="grp-title">👥 群組表情 · Group Emotes</span>' +
            '<button id="grp-back" class="grp-mini">← 返回 Back</button>';
        wrap.appendChild(top);

        // Roster (only when active)
        if (g.active) {
            const roster = document.createElement('div');
            roster.className = 'grp-roster';
            const head = document.createElement('div');
            head.className = 'grp-sec-title';
            head.innerHTML = '<span>群組成員 · Group</span>' +
                '<span class="grp-count">' + g.members.length + '</span>';
            roster.appendChild(head);

            const chips = document.createElement('div');
            chips.className = 'grp-chips';
            g.members.forEach((m) => {
                const c = document.createElement('div');
                c.className = 'grp-chip' + (m.leader ? ' leader' : '');
                c.innerHTML = (m.leader ? '<span class="crown">👑</span>' : '<span class="dot">●</span>') +
                    '<span class="nm">' + esc(m.name) + '</span>' +
                    (m.leader ? '<span class="role">隊長</span>' : '');
                chips.appendChild(c);
            });
            roster.appendChild(chips);
            wrap.appendChild(roster);

            // Leader hint / member hint
            const hint = document.createElement('div');
            hint.className = 'grp-hint';
            hint.textContent = g.isLeader
                ? '你係隊長 — 揀動作全隊一齊做 · You lead — pick any emote and the group follows'
                : '隊長控制緊表情 · The leader controls the emotes';
            wrap.appendChild(hint);
        } else {
            const intro = document.createElement('div');
            intro.className = 'grp-hint';
            intro.textContent = '邀請附近玩家組成表情群組 · Invite nearby players to start a group';
            wrap.appendChild(intro);
        }

        // Invite list — only the leader (or an ungrouped player) can invite.
        const canInvite = !g.active || g.isLeader;
        if (canInvite) {
            const sec = document.createElement('div');
            sec.className = 'grp-sec-title grp-nearby-title';
            sec.innerHTML = '<span>附近玩家 · Nearby</span>' +
                '<button id="grp-refresh" class="grp-mini">↻ 更新</button>';
            wrap.appendChild(sec);

            const list = document.createElement('div');
            list.className = 'grp-nearby';
            const near = g.nearby || [];
            if (!near.length) {
                list.innerHTML = '<div class="grp-empty">附近冇玩家 (12m 內) · No players within 12m</div>';
            } else {
                near.forEach((p) => {
                    const row = document.createElement('div');
                    row.className = 'grp-near-row';
                    const already = invited.has(p.src);
                    row.innerHTML = '<span class="nm">' + esc(p.name) + '</span>' +
                        '<span class="dist">' + esc(p.dist) + 'm</span>' +
                        '<button class="grp-invite" data-src="' + esc(p.src) + '"' +
                        (already ? ' disabled' : '') + '>' +
                        (already ? '已邀請 ✓' : '邀請 Invite') + '</button>';
                    list.appendChild(row);
                });
            }
            wrap.appendChild(list);
        }

        // Leave / Disband
        if (g.active) {
            const btn = document.createElement('button');
            btn.className = 'grp-leave';
            btn.textContent = g.isLeader ? '解散群組 · Disband Group' : '離開群組 · Leave Group';
            btn.addEventListener('click', () => post('groupLeave'));
            wrap.appendChild(btn);
        }

        contentEl.appendChild(wrap);

        // wire buttons
        const back = document.getElementById('grp-back');
        if (back) back.addEventListener('click', closeGroup);
        const refresh = document.getElementById('grp-refresh');
        if (refresh) refresh.addEventListener('click', () => post('groupNearby'));
        wrap.querySelectorAll('.grp-invite').forEach((b) => {
            b.addEventListener('click', () => {
                const src = b.dataset.src;
                if (invited.has(src)) return;
                post('groupInvite', { src });
                b.textContent = '已邀請 ✓';
                b.disabled = true;
                // remember across re-renders; auto-clear after the server timeout
                if (invited.has(src)) clearTimeout(invited.get(src));
                invited.set(src, setTimeout(() => { invited.delete(src); }, 20000));
            });
        });
    }

    // ---- search across the whole catalog ----------------------------------
    function matches(item) {
        const q = query;
        return item.id.toLowerCase().indexOf(q) !== -1 ||
               String(item.label).toLowerCase().indexOf(q) !== -1;
    }

    function renderSearch() {
        const results = [];
        catalog.emotes.forEach((g) => g.items.forEach((it) => {
            if (matches(it)) results.push({ item: it, kind: 'emote' });
        }));
        // Only search categories that are currently available as tabs — this
        // makes search honour the "Shared hidden while grouped" rule (and any
        // config-disabled tab) automatically, instead of duplicating the check.
        const avail = availableTabs();
        const isAvail = (id) => avail.some((t) => t.id === id);
        [['dances', 'dance'], ['props', 'prop'], ['walks', 'walk'],
         ['moods', 'mood'], ['shared', 'share']].forEach(([key, kind]) => {
            if (!isAvail(key)) return;
            (catalog[key] || []).forEach((it) => {
                if (matches(it)) results.push({ item: it, kind });
            });
        });

        if (!results.length) return showEmpty('搵唔到 “' + query + '”\nNo matches');

        contentEl.appendChild(groupHeader('🔍', 'Results', '搜尋結果', results.length));
        const grid = document.createElement('div');
        grid.className = 'grid';
        results.forEach((r) => grid.appendChild(buildTile(r.item, r.kind, true)));
        contentEl.appendChild(grid);
        focusFirst();
    }

    // ---- focus + keyboard nav ---------------------------------------------
    function tileEls() { return contentEl.querySelectorAll('.tile'); }

    function focusFirst() { focusIdx = 0; setFocus(0); }

    function setFocus(idx) {
        const els = tileEls();
        if (!els.length) return;
        focusIdx = Math.max(0, Math.min(idx, els.length - 1));
        els.forEach((el, i) => el.classList.toggle('focused', i === focusIdx));
        els[focusIdx].scrollIntoView({ block: 'nearest' });
    }

    // ---- actions ----------------------------------------------------------
    function activate(idx) {
        const it = flat[idx];
        if (!it) return;
        if (it.kind === 'share') {
            post('share', { id: it.id });
        } else {
            post('play', { kind: it.kind, id: it.id });
            // optimistic recent update for emote/dance/prop
            if (['emote', 'dance', 'prop'].indexOf(it.kind) !== -1) bumpRecent(it.id);
        }
    }

    function bumpRecent(id) {
        const at = recent.indexOf(id);
        if (at !== -1) recent.splice(at, 1);
        recent.unshift(id);
        if (recent.length > 24) recent.pop();
        // refresh tab counter only (avoid re-render churn while browsing)
        const rt = tabsEl.querySelector('[data-tab="recent"] .t-count');
        if (rt) rt.textContent = recent.length;
    }

    function toggleFav(id) {
        post('favorite', { id }).then((res) => {
            if (res && Array.isArray(res.favorites)) favorites = res.favorites;
            else {
                const at = favorites.indexOf(id);
                if (at !== -1) favorites.splice(at, 1); else favorites.push(id);
            }
            // update stars in place + counters
            contentEl.querySelectorAll('.fav[data-fav]').forEach((b) => {
                const on = isFav(b.dataset.fav);
                b.classList.toggle('on', on);
                b.textContent = on ? '★' : '☆';
            });
            const ft = tabsEl.querySelector('[data-tab="favorites"] .t-count');
            if (ft) ft.textContent = favorites.length;
            if (activeTab === 'favorites') renderContent();
        });
    }

    function cancelEmote() { post('play', { kind: 'cancel', id: 'c' }); }

    // ---- search input -----------------------------------------------------
    searchEl.addEventListener('input', () => {
        query = searchEl.value.trim().toLowerCase();
        clearEl.classList.toggle('hidden', !query);
        // Typing leaves the group panel (it's an overlay page over the tabs).
        if (query && groupOpen) { groupOpen = false; if (btnGroup) btnGroup.classList.remove('active'); }
        renderContent();
    });
    clearEl.addEventListener('click', () => {
        searchEl.value = ''; query = '';
        clearEl.classList.add('hidden');
        renderContent();
        searchEl.focus();
    });

    // ---- open / close -----------------------------------------------------
    btnClose.addEventListener('click', close);
    btnCancel.addEventListener('click', cancelEmote);
    overlay.addEventListener('mousedown', (e) => { if (e.target === overlay) close(); });

    // ---- group panel toggle (mouse-only rail button) ----------------------
    function openGroup() {
        groupOpen = true;
        if (btnGroup) btnGroup.classList.add('active');
        post('groupNearby');   // ask Lua for a fresh nearby scan
        renderContent();
    }
    function closeGroup() {
        groupOpen = false;
        if (btnGroup) btnGroup.classList.remove('active');
        renderContent();       // back to the current tab
    }
    if (btnGroup) btnGroup.addEventListener('click', () => (groupOpen ? closeGroup() : openGroup()));

    function close() { post('close'); }

    function open(msg) {
        catalog   = msg.catalog || { emotes: [], dances: [], props: [], walks: [], moods: [], shared: [], config: {} };
        favorites = msg.favorites || [];
        recent    = msg.recent || [];
        query = ''; searchEl.value = ''; clearEl.classList.add('hidden');
        zone = 'content';
        groupOpen = false;
        if (btnGroup) btnGroup.classList.remove('active');
        // Open on Favorites (now the first page) when the player has some;
        // otherwise fall through to the full Emotes list so it's never blank.
        activeTab = favorites.length ? 'favorites' : 'emotes';
        const avail = availableTabs();
        tabIdx = Math.max(0, avail.findIndex((t) => t.id === activeTab));
        renderTabs();
        renderContent();
        overlay.classList.remove('hidden');
        isOpen = true;
    }

    function hide() { overlay.classList.add('hidden'); isOpen = false; }

    // ---- central nav (shared by DOM keys in mouse mode + Lua msgs in kbd) --
    // action ∈ up|down|left|right|enter|fav. Left/Right cross between the rail
    // (tabs) and the content grid; Up/Down move within the active zone.
    function nav(action) {
        switch (action) {
            case 'left':
                if (zone === 'content') enterRail();
                // already in rail: stay (left edge)
                break;
            case 'right':
                if (zone === 'rail') enterContent();
                // already in content: stay (or could no-op)
                break;
            case 'up':
                if (zone === 'rail') moveTab(-1);
                else setFocus(focusIdx - 1);   // linear so every tile is reachable
                break;
            case 'down':
                if (zone === 'rail') moveTab(1);
                else setFocus(focusIdx + 1);
                break;
            case 'enter':
                if (zone === 'rail') enterContent();   // Enter on a tab dives in
                else activate(focusIdx);
                break;
            case 'fav': {
                if (zone !== 'content') break;
                const it = flat[focusIdx];
                if (it && it.kind === 'emote') toggleFav(it.id);
                break;
            }
            default: break;
        }
    }

    // ---- mode chip --------------------------------------------------------
    function setMode(mouse) {
        mouseMode = !!mouse;
        document.body.classList.toggle('mouse-mode', mouseMode);
        document.body.classList.toggle('kbd-mode', !mouseMode);
        if (modeChip) {
            // Show the CURRENT mode plus what backtick switches TO, so it's clear
            // the key toggles rather than just labelling the active mode.
            modeChip.innerHTML = mouseMode
                ? '<span class="mc-key">`</span> 滑鼠 Mouse <span class="mc-alt">→ 鍵盤</span>'
                : '<span class="mc-key">`</span> 鍵盤 Keyboard <span class="mc-alt">→ 滑鼠</span>';
        }
        // Leaving mouse mode: make sure search doesn't keep capturing keys, and
        // close the (mouse-only) group panel so keyboard nav never lands inside it.
        if (!mouseMode) {
            if (document.activeElement === searchEl) searchEl.blur();
            if (groupOpen && isOpen) closeGroup();
        }
    }

    // ---- keyboard (DOM) — only meaningful while mouse mode holds NUI focus --
    document.addEventListener('keydown', (e) => {
        if (!isOpen || !mouseMode) return;   // keyboard mode is driven from Lua
        const typing = document.activeElement === searchEl;

        // backtick toggles back to keyboard mode (Lua can't see it while NUI
        // holds focus, so we round-trip through a callback).
        if (e.key === '`' && !typing) { post('toggleMode'); e.preventDefault(); return; }

        if (e.key === 'Escape') {
            if (typing && query) { searchEl.value = ''; query = ''; clearEl.classList.add('hidden'); renderContent(); searchEl.blur(); }
            else close();
            e.preventDefault();
            return;
        }
        if (e.key === '/' && !typing) { searchEl.focus(); e.preventDefault(); return; }
        // let the search box handle its own text keys
        if (typing && e.key !== 'Enter' && e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;

        switch (e.key) {
            case 'ArrowRight': nav('right'); e.preventDefault(); break;
            case 'ArrowLeft':  nav('left');  e.preventDefault(); break;
            case 'ArrowDown':  if (typing) searchEl.blur(); nav('down'); e.preventDefault(); break;
            case 'ArrowUp':    nav('up');   e.preventDefault(); break;
            case 'Enter':      if (typing) searchEl.blur(); nav('enter'); e.preventDefault(); break;
            case 'f': case 'F': if (!typing) { nav('fav'); e.preventDefault(); } break;
            default: break;
        }
    });

    window.addEventListener('message', (ev) => {
        const msg = ev.data || {};
        if (msg.action === 'open') { open(msg); setMode(!!msg.mouse); }
        else if (msg.action === 'close') hide();
        else if (msg.action === 'mode') setMode(!!msg.mouse);
        else if (msg.action === 'nav')  nav(msg.key);
        else if (msg.action === 'group') onGroupState(msg.state);
    });

    // Group state arrived from Lua. Update the rail button badge, re-render tabs
    // (Shared may appear/vanish), and refresh the group panel if it's open.
    function updateGroupBadge() {
        if (!groupBadge || !btnGroup) return;
        const n = groupState.active ? groupState.members.length : 0;
        groupBadge.textContent = n;
        groupBadge.classList.toggle('hidden', n === 0);
        btnGroup.classList.toggle('in-group', groupState.active);
    }
    function onGroupState(state) {
        groupState = state || { active: false, isLeader: false, leader: null, members: [], nearby: [] };
        groupState.members = groupState.members || [];
        groupState.nearby  = groupState.nearby  || [];
        // Anyone who actually joined no longer needs the "invited" hold.
        groupState.members.forEach((m) => {
            if (invited.has(String(m.src))) { clearTimeout(invited.get(String(m.src))); invited.delete(String(m.src)); }
        });
        updateGroupBadge();
        if (!isOpen) return;

        // If the active tab just became unavailable (e.g. Shared hidden when a
        // group forms), move to a valid tab AND re-render its content — not just
        // the rail — so the pane can't keep showing a stale (shared) grid whose
        // tiles would still play on Enter. Also keep tabIdx in range for rail nav.
        const avail = availableTabs();
        const stillValid = avail.some((t) => t.id === activeTab);
        renderTabs();
        if (!stillValid) {
            selectTab('emotes');          // re-renders content + fixes tabIdx
        } else {
            const ti = avail.findIndex((t) => t.id === activeTab);
            if (ti !== -1) tabIdx = ti;   // keep rail focus index valid
            if (groupOpen) renderContent();
        }
    }
})();
