// hk-hub — squad panel (vanilla, HK design tokens)
// Rendered inside #squad-body. Talks to client/squad.lua NUI callbacks via the
// shared window.HKHubAPI bridge exposed by app.js. Two states:
//   • no squad  → create / join-by-code
//   • in squad  → roster + roles + actions, radio toggle, invite, atlas map
// The client Lua pushes squadState / squadPositions / squadWaypointsChanged /
// squadInvite messages which app.js forwards to the on* handlers here.
(function () {
    const API = () => window.HKHubAPI || { post: () => {}, postJson: async () => null, esc: (s) => String(s == null ? '' : s) };
    const esc = (s) => API().esc(s);

    // Player blip-colour swatches: GTA blip index → display hex. Must match the
    // server's ALLOWED_BLIP_COLORS whitelist and the client's BLIP_RGB table.
    // ONLY "safe" blip IDs — never any with an (enemy)/(friendly) flag variant
    // (2,3,4,5,49,66,67,68,69), which the game recolours red/blue.
    // CRITICAL: each hex is the ACTUAL colour GTA renders for that blip ID (from
    // the FiveM blips doc), so the swatch is WYSIWYG against the minimap blip, the
    // over-head 3D tag, and the overlay ring. Do NOT eyeball these — a wrong hex
    // (e.g. ID 48 is "Brilliant Rose"/pink, ID 50 is "Medium Purple") makes the
    // picker lie about what shows in-game.
    const BLIP_COLORS = [
        { idx: 1,  hex: '#e03232', name: 'Red' },
        { idx: 17, hex: '#ea8e50', name: 'Orange' },
        { idx: 46, hex: '#ecf029', name: 'Gold' },
        { idx: 11, hex: '#8dcea7', name: 'Green' },
        { idx: 26, hex: '#7ac3fe', name: 'Light Blue' },
        { idx: 38, hex: '#2c6db8', name: 'Blue' },
        { idx: 27, hex: '#ab3ce6', name: 'Purple' },
        { idx: 8,  hex: '#fe7ac3', name: 'Pink' },
        { idx: 0,  hex: '#fefefe', name: 'White' },
    ];
    // Waypoint colours (stored as-is in the DB color column, drawn on the canvas).
    // These are the ACTUAL GTA blip hexes so the canvas dot matches the minimap
    // blip the server maps it to (see WP_HEX_TO_BLIP in client/squad.lua — the two
    // lists MUST stay in lockstep, one hex per safe blip ID).
    const WP_COLORS = ['#7ac3fe', '#e03232', '#ea8e50', '#ecf029', '#8dcea7', '#ab3ce6', '#fe7ac3', '#fefefe'];

    let root = null;         // #squad-body
    // Squad name + action chips live in the flyout's TOP BAR (next to "小隊 Squad")
    // rather than a row inside the body — frees vertical space so the map/waypoints
    // get more height. squad.js owns this slot's contents; app.js toggles the view.
    const headSlot = () => document.getElementById('flyout-squad-head');
    let opened = false;
    let selfBlipColor = null;   // this player's chosen blip index (from roster)
    let wpColorPick = '#7ac3fe';  // currently-selected waypoint colour (WP_COLORS[0])
    let wpPreview = null;         // live add-waypoint marker { nx, ny, name, color } drawn on the atlas
    // Atlas viewport: zoom + top-left corner in normalized (0..1) atlas space.
    // Visible region spans 1/zoom in each axis; x/y are clamped so it stays in bounds.
    let mapView = { zoom: 1, x: 0, y: 0 };
    let wasdBound = false;      // guard so the document WASD handler binds once
    let dragMoveBound = false;   // guard so the window drag move/up handlers bind once
    let drag = null;             // active drag-pan: {mx,my,vx,vy} or null
    let chatMsgs = [];           // squad chat backlog (loaded on open / squad change)
    let chatLoadedFor = 0;       // squadID the current chatMsgs belong to
    let chatSeen = {};           // message ids already rendered (dedupe live vs history)
    let wpBlipModes = {};        // [waypointId] = 0 hidden | 1 shown | 2 flashing
    let chatLastDay = null;      // day-key of the last rendered message (date dividers)
    let state = { squadID: 0, isLeader: false, name: '', code: null, radio: null, radioOn: false, limit: 4, members: [], squadCount: 0, maxSquads: 3 };
    let switcherOpen = false;   // squad-switcher modal open?
    let positions = [];      // latest live member positions (world coords)
    let waypoints = [];
    let atlasCfg = null;
    let pendingInvite = null;
    let poll = null;         // periodic roster refresh timer
    let lastRenderSig = null; // signature of last full render (poll change-detection)
    let rosterModalOpen = false;  // members popup open? (re-opened across re-renders)

    // ---- server round-trips (via shared postJson) ----
    async function call(name, payload) { return API().postJson(name, payload); }

    // ==== lifecycle ====
    function open(el) {
        root = el;
        opened = true;
        refreshState();
        if (!atlasCfg) call('squadGetAtlasCfg').then((c) => { atlasCfg = c || {}; });
        // Light periodic refresh so roster online/offline stays current — but
        // never while the user has a popover/form open or a field focused (else
        // the innerHTML rebuild wipes it out from under them mid-type).
        clearInterval(poll);
        poll = setInterval(() => { if (opened && !isInteracting()) refreshState({ poll: true }); }, 5000);
        bindWasd();
    }

    // WASD map panning — active only while the squad panel is open, the map is
    // zoomed in, and focus is NOT in a text field (so typing still works).
    function bindWasd() {
        if (wasdBound) return;
        wasdBound = true;
        document.addEventListener('keydown', (e) => {
            if (!opened || state.squadID <= 0) return;
            const t = e.target;
            if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
            const k = e.key.toLowerCase();
            if (k !== 'w' && k !== 'a' && k !== 's' && k !== 'd') return;
            if (mapView.zoom <= MAP_MIN_ZOOM) return;   // nothing to pan at 1x
            e.preventDefault();
            const step = 0.06 / mapView.zoom;   // pan a fraction of the visible span
            if (k === 'w') mapView.y -= step;
            else if (k === 's') mapView.y += step;
            else if (k === 'a') mapView.x -= step;
            else if (k === 'd') mapView.x += step;
            clampView();
            drawAtlas();
        });
    }

    // Window-level drag pan handlers, bound exactly once. They resolve the LIVE
    // canvas each move so they never touch a detached element from an old render.
    function bindDragMove() {
        if (dragMoveBound) return;
        dragMoveBound = true;
        window.addEventListener('mousemove', (e) => {
            if (!drag) return;
            const cv = document.getElementById('sq-map-canvas');
            if (!cv) { drag = null; return; }
            const rect = cv.getBoundingClientRect();
            if (!rect.width || !rect.height) return;   // guard against 0-size → Infinity snap
            const span = 1 / mapView.zoom;
            mapView.x = drag.vx - ((e.clientX - drag.mx) / rect.width) * span;
            mapView.y = drag.vy - ((e.clientY - drag.my) / rect.height) * span;
            clampView();
            drawAtlas();
        });
        window.addEventListener('mouseup', () => {
            if (!drag) return;
            drag = null;
            const cv = document.getElementById('sq-map-canvas');
            if (cv) cv.classList.remove('dragging');
        });
    }

    function close() {
        opened = false;
        rosterModalOpen = false;   // don't re-open the members popup on next open()
        switcherOpen = false;      // nor the squad switcher
        wpPreview = null;          // kill any add-preview marker + its anim loop
        clearSquadHead();          // strip the squad name/chips out of the flyout top bar
        clearInterval(poll);
        poll = null;
    }

    // True when the user is mid-interaction and a full re-render would be
    // destructive: a popover/form is open, or focus is in a text field. The
    // periodic poll skips render() in those windows so nothing vanishes.
    function isInteracting() {
        if (!root) return false;
        if (anySqPop()) return true;
        const wp = root.querySelector('#sq-wp-form');
        if (wp && !wp.classList.contains('hidden')) return true;
        if (root.querySelector('.sq-confirm')) return true;
        // The members popup re-opens itself across re-renders, but skip the poll's
        // render while it's up so the list never flickers under the user.
        if (rosterModalOpen && root.querySelector('.sq-roster-modal')) return true;
        if (switcherOpen && root.querySelector('.sq-switcher-modal')) return true;
        const a = document.activeElement;
        if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.isContentEditable)) return true;
        return false;
    }

    // Signature of everything render() actually draws in the panel body. The 5s
    // poll compares this before rebuilding the DOM — if nothing visible changed
    // we skip the innerHTML wipe (which was resetting scroll + eating clicks and
    // flickering every 5s). Live member DOT positions live on the atlas canvas
    // and repaint separately, so they don't need a full render.
    function renderSig() {
        const roster = (state.members || []).map((m) =>
            [m.citizenid, m.online ? 1 : 0, m.role, m.isOwner ? 1 : 0, m.nickname || '',
             m.blipColor == null ? '' : m.blipColor, m.name].join(':')).join('|');
        const wps = (waypoints || []).map((w) =>
            [w.id, w.name, w.color, w.iconKey, w.mapMode == null ? '' : w.mapMode].join(':')).join('|');
        return [state.squadID, state.name, state.code, state.radio, state.radioOn ? 1 : 0,
                state.isLeader ? 1 : 0, pendingInvite ? 1 : 0, state.squadCount || 0, roster, wps].join('~');
    }

    async function refreshState(opts) {
        const s = await call('squadGetState');
        if (s) {
            state = Object.assign(state, s);
            if (state.squadID > 0) await loadWaypoints();
        }
        if (!opened) return;
        // On the periodic poll, only rebuild the panel if something visible
        // actually changed. Otherwise just refresh the live atlas dots so we
        // never yank the user's scroll / interrupt a click for nothing.
        if (opts && opts.poll) {
            const sig = renderSig();
            if (sig === lastRenderSig) { if (state.squadID > 0) drawAtlas(); return; }
        }
        render();
    }

    async function loadWaypoints() {
        if (state.squadID <= 0) { waypoints = []; wpBlipModes = {}; return; }
        const w = await call('squadGetWaypoints', { squadID: state.squadID });
        waypoints = Array.isArray(w) ? w : [];
        // Blip mode is a SHARED status now — read it straight off each row's
        // server-authoritative mapMode (no separate client-local lookup).
        wpBlipModes = {};
        waypoints.forEach((wp) => { wpBlipModes[String(wp.id)] = Number(wp.mapMode) || 0; });
    }

    // ==== pushes from Lua ====
    function onState(s) {
        if (!s) return;
        const prevSquad = state.squadID;
        state.squadID = s.squadID || 0;
        state.isLeader = !!s.isLeader;
        state.name = s.name || '';
        state.code = s.code || null;
        state.radio = s.radio || null;
        state.radioOn = !!s.radioOn;
        // Squad changed (joined/left/switched) → drop stale chat so the new squad
        // reloads its own backlog and we never leak messages across squads.
        if (state.squadID !== prevSquad) { chatMsgs = []; chatSeen = {}; chatLoadedFor = 0; }
        // Don't rebuild the DOM out from under an open popover/form/field.
        if (opened && !isInteracting()) refreshState();
    }
    function onPositions(rows) { positions = Array.isArray(rows) ? rows : []; if (opened) drawAtlas(); }
    // Live chat message pushed from the server — append without a full re-render.
    function onChatMessage(msg) {
        if (!msg || !msg.id) return;
        if (chatSeen[msg.id]) return;
        chatSeen[msg.id] = true;
        chatMsgs.push(msg);
        if (chatMsgs.length > 200) chatMsgs.shift();
        appendChatMessage(msg, true);
    }
    function onWaypointsChanged() { if (opened) loadWaypoints().then(() => { if (opened) drawAtlas(); }); }
    function onInvite(inv) { pendingInvite = inv || null; if (opened) render(); }

    // ==== always-on member overlay (top-right HUD) ====
    // Fed by client/squad.lua on a fast tick with per-online-member health,
    // distance and mic state. Diffs against existing cards so the portrait <img>
    // isn't reloaded every tick (which would flicker) — only text/bars/rings.
    let overlayCards = {};   // [serverId] = { root, img, bar, dist, name, talking }

    function onOverlay(data) {
        const box = document.getElementById('squad-overlay');
        if (!box) return;
        const show = data && data.show;
        const members = (data && Array.isArray(data.members)) ? data.members : [];
        if (!show || members.length === 0) {
            box.classList.add('hidden');
            box.innerHTML = '';
            overlayCards = {};
            return;
        }
        box.classList.remove('hidden');

        const seen = {};
        // Owner first, then nearest, so the leader stays pinned at the top.
        members.sort((a, b) => {
            if (!!b.owner !== !!a.owner) return b.owner ? 1 : -1;
            const da = a.dist == null || a.dist < 0 ? 1e9 : a.dist;
            const db = b.dist == null || b.dist < 0 ? 1e9 : b.dist;
            return da - db;
        });

        members.forEach((m) => {
            const id = String(m.id);
            seen[id] = true;
            let c = overlayCards[id];
            if (!c) c = overlayCards[id] = buildOverlayCard(m);
            paintOverlayCard(c, m);
            box.appendChild(c.root);   // re-append keeps DOM order == sorted order
        });

        // Drop cards for members no longer online / in range set.
        Object.keys(overlayCards).forEach((id) => {
            if (!seen[id]) {
                const c = overlayCards[id];
                if (c && c.root && c.root.parentNode) c.root.parentNode.removeChild(c.root);
                delete overlayCards[id];
            }
        });
    }

    function buildOverlayCard(m) {
        const root = el('div', 'sqo-card');
        const av = el('div', 'sqo-av');
        const ring = el('div', 'sqo-av-ring');
        const img = el('img', 'sqo-av-img');
        img.onerror = () => { img.style.display = 'none'; ph.style.display = ''; };
        const ph = el('i', 'fa-solid fa-user sqo-av-ph');
        av.appendChild(ring); av.appendChild(ph); av.appendChild(img);
        const mic = el('i', 'fa-solid fa-walkie-talkie sqo-mic');
        av.appendChild(mic);

        const body = el('div', 'sqo-body');
        const name = el('span', 'sqo-name');
        const dist = el('span', 'sqo-dist');
        body.appendChild(name); body.appendChild(dist);

        root.appendChild(av); root.appendChild(body);
        return { root, img, ph, ring, mic, name, dist, _av: null, _dist: -2, _talk: null };
    }

    function paintOverlayCard(c, m) {
        // Fallbacks (no chosen colour) match the ACTUAL blip: leader = gold 46
        // (#ecf029), member = blue 38 (#2c6db8).
        const hex = m.blipColor != null ? (hexForBlip(m.blipColor) || '#2c6db8')
            : (m.owner ? '#ecf029' : '#2c6db8');

        // Avatar (only swap src when it actually changes — avoids reload flicker).
        if (m.avatar && c._av !== m.avatar) {
            c._av = m.avatar;
            c.img.style.display = '';
            c.ph.style.display = 'none';
            c.img.src = m.avatar;
        } else if (!m.avatar && c._av !== null) {
            c._av = null;
            c.img.style.display = 'none';
            c.ph.style.display = '';
        }

        // Name (first token). Ring carries the member's blip colour; name stays
        // white for legibility over the game world.
        const first = String(m.name || 'Squad').split(/\s+/)[0];
        if (c.name.textContent !== first) c.name.textContent = first;
        c.ring.style.borderColor = hex;

        // Distance: nil => "…", -1 => "far", else "Nm".
        let dtxt = '…';
        if (m.dist === -1) dtxt = 'far';
        else if (typeof m.dist === 'number') dtxt = m.dist >= 1000 ? (m.dist / 1000).toFixed(1) + 'km' : m.dist + 'm';
        if (c._dist !== dtxt) { c.dist.textContent = dtxt; c._dist = dtxt; }

        // Mic: card gets .sqo-talking; the badge + ring glow are pure CSS.
        const talk = !!m.talking;
        if (c._talk !== talk) {
            c._talk = talk;
            c.root.classList.toggle('sqo-talking', talk);
        }
    }

    // ==== render ====
    function render() {
        if (!root) return;
        lastRenderSig = renderSig();
        root.innerHTML = '';
        const wrap = document.createElement('div');
        wrap.className = 'sq-wrap';

        if (pendingInvite) wrap.appendChild(renderInvite());

        if (state.squadID > 0) {
            wrap.appendChild(renderSquad());   // renderSquad() fills the top-bar head slot
        } else {
            clearSquadHead();                  // hub view: no name/chips in the top bar
            wrap.appendChild(renderNoSquad());
        }
        root.appendChild(wrap);
        if (state.squadID > 0) drawAtlas();
    }

    function el(tag, cls, html) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html != null) e.innerHTML = html;
        return e;
    }

    // Incoming-invite banner (accept / decline).
    function renderInvite() {
        const inv = pendingInvite;
        const box = el('div', 'sq-invite');
        box.innerHTML =
            '<div class="sq-invite-txt"><i class="fa-solid fa-user-plus"></i> ' +
            '<b>' + esc(inv.inviterName) + '</b> 邀請你加入 <b>' + esc(inv.squadName) + '</b></div>';
        const btns = el('div', 'sq-invite-btns');
        const yes = el('button', 'sq-btn sq-btn-go', '<i class="fa-solid fa-check"></i> 接受 Accept');
        const no = el('button', 'sq-btn sq-btn-ghost', '拒絕 Decline');
        yes.addEventListener('click', () => respondInvite(true));
        no.addEventListener('click', () => respondInvite(false));
        btns.appendChild(yes); btns.appendChild(no);
        box.appendChild(btns);
        return box;
    }

    function respondInvite(accepted) {
        if (!pendingInvite) return;
        API().post('squadRespondInvite', {
            squadID: pendingInvite.squadID,
            inviterSource: pendingInvite.inviterSource,
            accepted: accepted,
        });
        pendingInvite = null;
        render();
        if (accepted) setTimeout(refreshState, 600);
    }

    // No squad: create + join-by-code.
    // Hub / entry page: your squads (up to 3) + create + join. Shown when you have
    // no ACTIVE squad (you may still belong to squads — pick one to enter).
    function renderNoSquad() {
        const box = el('div', 'sq-empty');
        const atCap = (state.squadCount || 0) >= (state.maxSquads || 3);
        box.innerHTML =
            '<div class="sq-empty-ico"><i class="fa-solid fa-users"></i></div>' +
            '<div class="sq-empty-title">小隊中心 · Squad hub</div>' +
            '<div class="sq-empty-sub">選擇要啟用的小隊，或建立 / 加入新的（最多 ' + esc(state.maxSquads || 3) +
            ' 個）。<br>Pick a squad to activate, or create / join one (up to ' + esc(state.maxSquads || 3) + ' squads).</div>';

        // Your existing squads (async-loaded list, rendered into a placeholder).
        const myWrap = el('div', 'sq-hub-list');
        box.appendChild(myWrap);
        renderMyList(myWrap, false);

        // Create + Join. When at the 3-squad cap, disable both with a hint.
        box.appendChild(buildCreateCard(atCap));
        box.appendChild(buildJoinCard(atCap));
        return box;
    }

    // Build the "Create squad" card. disabled=true greys it out (at squad cap).
    function buildCreateCard(disabled) {
        const createCard = el('div', 'sq-card');
        createCard.appendChild(el('div', 'sq-card-title', '<i class="fa-solid fa-flag"></i> 建立小隊 · Create'));
        const nameIn = el('input', 'sq-input');
        nameIn.type = 'text'; nameIn.maxLength = 32; nameIn.placeholder = '小隊名稱 (選填) · Squad name (optional)';
        if (disabled) nameIn.disabled = true;
        createCard.appendChild(nameIn);
        const createBtn = el('button', 'sq-btn sq-btn-go', '<i class="fa-solid fa-plus"></i> 建立 · Create Squad');
        if (disabled) { createBtn.disabled = true; createBtn.title = '已達 3 個小隊上限 · At the 3-squad limit'; }
        createBtn.addEventListener('click', async () => {
            createBtn.disabled = true;
            const res = await call('squadCreate', { name: nameIn.value });
            createBtn.disabled = false;
            if (res && res.ok) { switcherOpen = false; setTimeout(refreshState, 400); }
            else toast(errText(res), 'err');
        });
        createCard.appendChild(createBtn);
        return createCard;
    }

    // Build the "Join by code" card (OTP-style boxes). disabled=true at squad cap.
    function buildJoinCard(disabled) {
        // Join by code — segmented OTP-style boxes (way cooler than a plain field).
        const joinCard = el('div', 'sq-card');
        joinCard.appendChild(el('div', 'sq-card-title', '<i class="fa-solid fa-hashtag"></i> 加入 · Join by code'));

        const CODE_LEN = 5;
        const boxes = el('div', 'sq-code-boxes');
        const cells = [];
        function currentCode() { return cells.map((c) => c.value).join(''); }
        for (let i = 0; i < CODE_LEN; i++) {
            const cell = el('input', 'sq-code-cell');
            cell.type = 'text'; cell.maxLength = 1; cell.inputMode = 'text';
            cell.setAttribute('aria-label', 'Code ' + (i + 1));
            cell.addEventListener('input', () => {
                cell.value = cell.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
                cell.classList.toggle('filled', cell.value !== '');
                if (cell.value && i < CODE_LEN - 1) cells[i + 1].focus();
                if (currentCode().length === CODE_LEN) tryJoin();
            });
            cell.addEventListener('keydown', (e) => {
                if (e.key === 'Backspace' && !cell.value && i > 0) { cells[i - 1].focus(); cells[i - 1].value = ''; cells[i - 1].classList.remove('filled'); e.preventDefault(); }
                else if (e.key === 'ArrowLeft' && i > 0) { cells[i - 1].focus(); e.preventDefault(); }
                else if (e.key === 'ArrowRight' && i < CODE_LEN - 1) { cells[i + 1].focus(); e.preventDefault(); }
                else if (e.key === 'Enter') { e.preventDefault(); tryJoin(); }
            });
            // Paste a whole code into any cell → spread across the boxes.
            cell.addEventListener('paste', (e) => {
                e.preventDefault();
                const txt = ((e.clipboardData || window.clipboardData).getData('text') || '')
                    .toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, CODE_LEN);
                for (let j = 0; j < CODE_LEN; j++) {
                    cells[j].value = txt[j] || '';
                    cells[j].classList.toggle('filled', !!txt[j]);
                }
                (cells[Math.min(txt.length, CODE_LEN - 1)] || cells[0]).focus();
                if (txt.length === CODE_LEN) tryJoin();
            });
            cells.push(cell);
            boxes.appendChild(cell);
        }
        joinCard.appendChild(boxes);

        const joinBtn = el('button', 'sq-btn sq-btn-go', '<i class="fa-solid fa-right-to-bracket"></i> 加入 · Join');
        let joining = false;
        async function tryJoin() {
            const code = currentCode();
            if (code.length < 4) { toast('請輸入邀請碼。 Enter a join code.', 'err'); return; }
            if (joining) return;
            joining = true; joinBtn.disabled = true;
            const res = await call('squadJoinByCode', { code: code });
            joining = false; joinBtn.disabled = false;
            if (res && res.ok) { switcherOpen = false; setTimeout(refreshState, 400); }
            else {
                toast(errText(res), 'err');
                cells.forEach((c) => { c.value = ''; c.classList.remove('filled'); });
                boxes.classList.remove('shake'); void boxes.offsetWidth; boxes.classList.add('shake');
                cells[0].focus();
            }
        }
        joinBtn.addEventListener('click', tryJoin);
        joinCard.appendChild(joinBtn);
        if (disabled) {
            boxes.querySelectorAll('.sq-code-cell').forEach((c) => { c.disabled = true; });
            joinBtn.disabled = true; joinBtn.title = '已達 3 個小隊上限 · At the 3-squad limit';
        }
        return joinCard;
    }

    // Render the "my squads" list into a container: one card per squad with an
    // Activate/Enter action. `compact` tunes styling for the switcher modal.
    async function renderMyList(container, compact) {
        if (!container) return;
        container.innerHTML = '<div class="sq-hub-loading">載入中… · Loading…</div>';
        const res = await call('squadMyList');
        const squads = (res && Array.isArray(res.squads)) ? res.squads : [];
        container.innerHTML = '';
        if (!squads.length) {
            container.appendChild(el('div', 'sq-hub-empty', '你還沒有任何小隊。 You have no squads yet.'));
            return;
        }
        const roleLabel = (r) => r === 'owner' ? '隊長 Leader' : (r === 'vice' ? '副手 Vice' : '隊員 Member');
        squads.forEach((sq) => {
            const card = el('div', 'sq-hub-item' + (sq.isActive ? ' active' : ''));
            const meta = '<div class="sq-hub-item-main">' +
                    '<span class="sq-hub-item-name">' + esc(sq.name || 'Squad') + '</span>' +
                    '<span class="sq-hub-item-sub">' +
                        '<span class="sq-hub-role ' + esc(sq.role) + '">' + esc(roleLabel(sq.role)) + '</span>' +
                        '<span class="sq-hub-count"><i class="fa-solid fa-user-group"></i> ' + esc(sq.members) + ' / ' + esc(sq.limit) + '</span>' +
                        (sq.isActive ? '<span class="sq-hub-active-tag">啟用中 · Active</span>' : '') +
                    '</span></div>';
            card.innerHTML = meta;
            const enter = el('button', 'sq-btn ' + (sq.isActive ? 'sq-btn-ghost' : 'sq-btn-go') + ' sq-hub-enter',
                sq.isActive ? '<i class="fa-solid fa-check"></i> 已啟用 Active' : '<i class="fa-solid fa-right-to-bracket"></i> 進入 Enter');
            if (sq.isActive) enter.disabled = true;
            enter.addEventListener('click', async () => {
                enter.disabled = true;
                const r = await call('squadSetActive', { squadID: sq.squadID });
                if (r && r.ok) { switcherOpen = false; setTimeout(refreshState, 300); }
                else { enter.disabled = false; toast(errText(r), 'err'); }
            });
            card.appendChild(enter);
            container.appendChild(card);
        });
    }

    // Empty + hide the flyout top-bar squad slot (no active squad / view closed).
    function clearSquadHead() {
        const slot = headSlot();
        if (slot) { slot.innerHTML = ''; slot.classList.add('hidden'); }
    }

    // Squad name (+rename for leader) and the action chips — code / radio / switch /
    // exit / leave — rendered INTO the flyout header bar (#flyout-squad-head), next
    // to the "小隊 Squad" title. Kept out of the body so the map/waypoints get the
    // height back. Rebuilt on every render() so it tracks state like the rest.
    function renderSquadHead(count) {
        const slot = headSlot();
        if (!slot) return;
        slot.innerHTML = '';
        slot.classList.remove('hidden');

        const nameWrap = el('div', 'sq-name-wrap');
        const nameEl = el('div', 'sq-name' + (state.isLeader ? ' sq-name-clickable' : ''), esc(state.name || 'Squad'));
        nameWrap.appendChild(nameEl);
        if (state.isLeader) {
            nameEl.title = '點擊重新命名 · Click to rename';
            nameEl.addEventListener('click', (e) => { e.stopPropagation(); openRenamePopover(nameWrap); });
            const renameBtn = el('button', 'sq-icon-btn sq-name-edit', '<i class="fa-solid fa-pen"></i>');
            renameBtn.title = '重新命名小隊 · Rename squad';
            renameBtn.addEventListener('click', (e) => { e.stopPropagation(); openRenamePopover(nameWrap); });
            nameWrap.appendChild(renameBtn);
        }
        slot.appendChild(nameWrap);

        const headActions = el('div', 'sq-head-actions');

        // Join code — everyone in the squad sees it so they can share/invite.
        if (state.code) {
            const codeChip = el('button', 'sq-chip sq-chip-code',
                '<i class="fa-solid fa-hashtag"></i> <span class="sq-code-val">' + esc(state.code) + '</span>');
            codeChip.title = '點擊複製邀請碼 · Click to copy join code';
            codeChip.addEventListener('click', () => {
                copyText(state.code);
                toast('已複製邀請碼 ' + state.code + ' · Code copied.', 'ok');
            });
            headActions.appendChild(codeChip);
        }

        // Radio toggle (only if the server assigned a channel)
        if (state.radio) {
            const radioBtn = el('button', 'sq-chip' + (state.radioOn ? ' on' : ''),
                '<i class="fa-solid fa-walkie-talkie"></i> 對講機 Radio');
            radioBtn.title = 'PTT 使用 pma-voice 的按鍵。 Push-to-talk uses your pma-voice key.';
            radioBtn.addEventListener('click', async () => {
                const res = await call('squadRadio', { on: !state.radioOn });
                if (res) state.radioOn = !!res.radioOn;
                render();
            });
            headActions.appendChild(radioBtn);
        }

        // Switch squads — opens the switcher modal (your other squads + create/join).
        // Always available so you can add a squad (up to 3) or hop to another.
        const switchBtn = el('button', 'sq-chip',
            '<i class="fa-solid fa-repeat"></i> 切換 Switch' +
            ((state.squadCount || 1) > 1 ? ' <span class="sq-chip-badge">' + esc(state.squadCount) + '</span>' : ''));
        switchBtn.title = '切換或加入其他小隊（最多 3） · Switch or join another squad (up to 3)';
        switchBtn.addEventListener('click', (e) => { e.stopPropagation(); openSwitcher(); });
        headActions.appendChild(switchBtn);

        // Exit — temp-leave to the hub WITHOUT giving up membership. You go
        // hidden/offline to this squad until you re-activate it.
        const deacBtn = el('button', 'sq-chip',
            '<i class="fa-solid fa-moon"></i> 暫離 Exit');
        deacBtn.title = '暫時離開（保留成員資格，對此隊隱身） · Temporarily leave — stay a member but hidden';
        deacBtn.addEventListener('click', async () => {
            const res = await call('squadDeactivate');
            if (res && res.ok) { positions = []; setTimeout(refreshState, 300); }
            else toast(errText(res), 'err');
        });
        headActions.appendChild(deacBtn);

        const isDisband = count <= 1;
        const leaveLabel = isDisband ? '解散 Disband' : '離開 Leave';
        const leaveBtn = el('button', 'sq-chip sq-chip-danger',
            '<i class="fa-solid fa-right-from-bracket"></i> ' + leaveLabel);
        leaveBtn.addEventListener('click', () => {
            confirmDialog({
                title: isDisband ? '解散小隊？ · Disband squad?' : '離開小隊？ · Leave squad?',
                body: isDisband
                    ? '你是最後一名成員，離開將解散小隊並清除聊天記錄。 You are the last member — leaving disbands the squad and clears its chat.'
                    : '你確定要離開此小隊嗎？ Are you sure you want to leave this squad?',
                okLabel: leaveLabel,
                onOk: async () => {
                    const res = await call('squadLeave');
                    if (res && res.ok) { positions = []; setTimeout(refreshState, 400); }
                },
            });
        });
        headActions.appendChild(leaveBtn);
        slot.appendChild(headActions);
    }

    // In a squad: header + roster + actions + map.
    function renderSquad() {
        const box = el('div', 'sq-team');
        const members = state.members || [];
        const count = members.length;
        const limit = state.limit || 4;

        // Remember my own chosen blip colour (for the picker's active swatch).
        const me = members.filter((m) => m.isSelf)[0];
        if (me && me.blipColor != null) selfBlipColor = me.blipColor;
        // Shared-map editing (add/edit/delete/ping waypoints) is vice+leader
        // only now. Members are view-only. Drive the UI gates off this.
        state.canEditWp = !!(me && (me.isOwner || me.role === 'vice'));

        // Name + rename + action chips (code/radio/switch/exit/leave) render into
        // the flyout TOP BAR, not the body — see renderSquadHead(). Frees this whole
        // row of height so the map + waypoint list can push upward.
        renderSquadHead(count);

        // Two-column split: map/waypoints on the left, roster + chat on the right.
        const split = el('div', 'sq-split');
        const colL = el('div', 'sq-col sq-col-left');
        const colR = el('div', 'sq-col sq-col-right');

        // ---- LEFT: map (atlas) + standalone waypoint list ----
        colL.appendChild(renderMapCard());
        colL.appendChild(renderWpCard());

        // ---- RIGHT: members bar-button (opens a roomy popup) + chat ----
        // The roster used to be a cramped scroll strip wedged above the chat.
        // Now it's a single bar that opens a centered modal with full-size rows —
        // frees the column height for chat and makes members easy to read.
        const online = members.filter((m) => m.online).length;
        const membersBtn = el('button', 'sq-members-bar');
        membersBtn.innerHTML =
            '<span class="sq-members-bar-main"><i class="fa-solid fa-users"></i> 隊員 · Members</span>' +
            '<span class="sq-members-bar-meta">' +
                '<span class="sq-members-bar-online"><span class="sq-dot on"></span>' + online + ' 在線</span>' +
                '<span class="sq-members-bar-count">' + count + ' / ' + limit + '</span>' +
                '<i class="fa-solid fa-chevron-right"></i>' +
            '</span>';
        membersBtn.addEventListener('click', (e) => { e.stopPropagation(); openRosterModal(); });
        colR.appendChild(membersBtn);
        // Re-open the modal after a re-render (management action / poll) so kicking
        // or promoting refreshes the list in place instead of closing it.
        if (rosterModalOpen) setTimeout(openRosterModal, 0);
        if (switcherOpen) setTimeout(openSwitcher, 0);
        // (Colour picker + rename open on-demand from the self row — see
        //  renderMember / openColorPopover / openNickPopover. Invite lives inside
        //  the roster modal now.)

        // Squad-only chat room (backlog + live). Separate from hk-chat.
        colR.appendChild(renderChat());

        split.appendChild(colL);
        split.appendChild(colR);
        box.appendChild(split);

        // Load chat backlog once per squad (new members see all prior messages).
        if (chatLoadedFor !== state.squadID) { loadChat(); }
        else { setTimeout(() => paintChat(), 0); }

        return box;
    }

    // ---- Squad chat ----
    function renderChat() {
        const card = el('div', 'sq-chat-card');
        card.appendChild(el('div', 'sq-card-title',
            '<i class="fa-solid fa-comments"></i> 小隊聊天 · Squad chat'));

        const log = el('div', 'sq-chat-log');
        log.id = 'sq-chat-log';
        card.appendChild(log);

        const row = el('div', 'sq-chat-input-row');
        // Image button: opens a picker of the player's phone gallery photos.
        const photo = el('button', 'sq-btn sq-btn-ghost sq-chat-photo', '<i class="fa-solid fa-image"></i>');
        photo.title = '傳送相片 · Send a photo from your phone gallery';
        const input = el('input', 'sq-input sq-chat-input');
        input.type = 'text'; input.maxLength = 512;
        input.placeholder = '輸入訊息… · Message your squad…';
        const send = el('button', 'sq-btn sq-btn-go sq-chat-send', '<i class="fa-solid fa-paper-plane"></i>');
        send.title = '傳送 · Send';

        async function submit() {
            const body = (input.value || '').trim();
            if (!body) return;
            input.value = '';
            const res = await call('squadSendMessage', { body: body });
            if (!res || !res.ok) { toast(errText(res), 'err'); input.value = body; }
            // The message paints via the server's live push (squadChatMessage).
        }
        send.addEventListener('click', (e) => { e.stopPropagation(); submit(); });
        photo.addEventListener('click', (e) => { e.stopPropagation(); openGalleryPicker(photo); });
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); submit(); }
        });

        row.appendChild(photo); row.appendChild(input); row.appendChild(send);
        card.appendChild(row);
        return card;
    }

    // Phone-gallery picker: a popover of the player's photos; click one to send
    // it into the squad chat as an image message.
    async function openGalleryPicker(anchorBtn) {
        if (root.querySelector('.sq-gallery-pop')) { closePopovers(); return; }
        closePopovers();

        const pop = el('div', 'sq-pop sq-pop-up sq-gallery-pop');
        pop.appendChild(el('div', 'sq-pop-title', '相簿 · Phone gallery'));
        const grid = el('div', 'sq-gallery-grid');
        grid.appendChild(el('div', 'sq-gallery-loading', '載入中… · Loading…'));
        pop.appendChild(grid);
        pop.addEventListener('click', (e) => e.stopPropagation());

        // Anchor above the photo button, like the waypoint edit popover.
        pop.style.position = 'fixed';
        pop.style.zIndex = '60';
        pop.style.bottom = 'auto'; pop.style.right = 'auto';
        root.appendChild(pop);
        const r = anchorBtn.getBoundingClientRect();
        const pw = pop.offsetWidth || 300, ph = pop.offsetHeight || 260;
        let left = r.left, top = r.top - ph - 8;
        if (top < 8) top = r.bottom + 8;
        if (left + pw > window.innerWidth - 8) left = window.innerWidth - pw - 8;
        if (left < 8) left = 8;
        pop.style.left = Math.round(left) + 'px';
        pop.style.top = Math.round(top) + 'px';
        armPopoverDismiss();

        const res = await call('squadGetGallery');
        grid.innerHTML = '';
        const imgs = (res && res.ok && Array.isArray(res.images)) ? res.images : [];
        if (!imgs.length) {
            grid.appendChild(el('div', 'sq-gallery-empty', '相簿是空的。用手機相機拍照後再傳。 No photos yet — take some with your phone camera.'));
            return;
        }
        imgs.forEach((it) => {
            const cell = el('button', 'sq-gallery-cell');
            const im = el('img', 'sq-gallery-thumb');
            im.src = it.url; im.loading = 'lazy';
            cell.appendChild(im);
            cell.addEventListener('click', async (e) => {
                e.stopPropagation();
                closePopovers();
                const r2 = await call('squadSendImage', { url: it.url });
                if (!r2 || !r2.ok) toast(errText(r2), 'err');
                // Paints via the live push (squadChatMessage).
            });
            grid.appendChild(cell);
        });
    }

    async function loadChat() {
        if (state.squadID <= 0) { chatMsgs = []; chatSeen = {}; return; }
        const res = await call('squadGetMessages');
        chatMsgs = (res && res.ok && Array.isArray(res.messages)) ? res.messages : [];
        chatSeen = {};
        chatMsgs.forEach((m) => { if (m.id) chatSeen[m.id] = true; });
        chatLoadedFor = state.squadID;
        paintChat();
    }

    // Repaint the whole log from chatMsgs (used after (re)load / re-render).
    function paintChat() {
        const log = document.getElementById('sq-chat-log');
        if (!log) return;
        log.innerHTML = '';
        chatLastDay = null;
        if (!chatMsgs.length) {
            log.appendChild(el('div', 'sq-chat-empty', '還沒有訊息。 No messages yet — say hi.'));
            return;
        }
        chatMsgs.forEach((m) => appendChatMessage(m, false));
        log.scrollTop = log.scrollHeight;
    }

    // Insert a centered date divider (WhatsApp/Telegram style) when the day rolls
    // over between messages.
    function maybeDayDivider(log, ts) {
        const key = dayKey(ts);
        if (key === null || key === chatLastDay) return;
        chatLastDay = key;
        const sep = el('div', 'sq-chat-day');
        sep.appendChild(el('span', 'sq-chat-day-label', esc(dayLabel(ts))));
        log.appendChild(sep);
    }

    // Append one message row. scroll=true keeps the log pinned to the bottom.
    function appendChatMessage(m, scroll) {
        const log = document.getElementById('sq-chat-log');
        if (!log) return;
        const empty = log.querySelector('.sq-chat-empty');
        if (empty) log.removeChild(empty);

        maybeDayDivider(log, m.ts);

        // Activity-log line (create / join / rename / waypoint events …). Rendered
        // centered like a date divider, not as a chat bubble.
        if (m.kind === 'system') {
            const row = renderSystemLine(m);
            if (row) {
                log.appendChild(row);
                if (scroll) {
                    const near = (log.scrollHeight - log.scrollTop - log.clientHeight) < 80;
                    if (near) log.scrollTop = log.scrollHeight;
                }
            }
            return;
        }

        const wrap = el('div', 'sq-msg' + (m.isSelf ? ' sq-msg-self' : ''));
        const meta = el('div', 'sq-msg-meta');
        meta.innerHTML = '<span class="sq-msg-author">' + esc(m.author || '?') + '</span>' +
            '<span class="sq-msg-time">' + esc(fmtTime(m.ts)) + '</span>';
        wrap.appendChild(meta);
        if (m.kind === 'image') {
            // Image message: thumbnail bubble; click to view full size.
            const im = el('img', 'sq-msg-img');
            im.src = m.url; im.loading = 'lazy';
            im.addEventListener('click', (e) => { e.stopPropagation(); openImageViewer(m.url); });
            wrap.appendChild(im);
        } else {
            wrap.appendChild(el('div', 'sq-msg-body', esc(m.body || '')));
        }
        log.appendChild(wrap);

        // Only auto-scroll if the user is already near the bottom (don't yank them
        // away while they're reading backlog).
        if (scroll) {
            const nearBottom = (log.scrollHeight - log.scrollTop - log.clientHeight) < 80;
            if (nearBottom) log.scrollTop = log.scrollHeight;
        }
    }

    // ---- Activity log rendering ------------------------------------------
    // Bold the actor / target / name tokens; everything else is plain text.
    function actorTag(name) { return '<b class="sq-sys-who">' + esc(name || '?') + '</b>'; }
    function nameTag(s, color) {
        const dot = color ? '<i class="sq-sys-dot" style="background:' + esc(color) + '"></i>' : '';
        return dot + '<b class="sq-sys-name">' + esc(s || '') + '</b>';
    }

    // verb → { icon (FA class), html(event) → sentence }. Bilingual, matches the
    // rest of the NUI (中文 first, English after).
    const SYS_VERBS = {
        create:    { icon: 'fa-flag',           html: (e) => actorTag(e.actor) + ' 建立了小隊 ' + nameTag(e.name) + ' · created the squad' },
        rename:    { icon: 'fa-pen',            html: (e) => actorTag(e.actor) + ' 改名為 ' + nameTag(e.name) + ' · renamed the squad' + (e.old ? ' (from ' + esc(e.old) + ')' : '') },
        join:      { icon: 'fa-right-to-bracket', html: (e) => actorTag(e.actor) + ' 加入了 · joined' + (e.via === 'invite' && e.by ? ' (invited by ' + esc(e.by) + ')' : (e.via === 'code' ? ' (via code)' : '')) },
        leave:     { icon: 'fa-right-from-bracket', html: (e) => actorTag(e.actor) + ' 離開了小隊 · left the squad' },
        transfer:  { icon: 'fa-crown',          html: (e) => actorTag(e.actor) + ' 將隊長轉給 ' + actorTag(e.target) + ' · handed leadership over' },
        kick:      { icon: 'fa-user-xmark',     html: (e) => actorTag(e.actor) + ' 踢出了 ' + actorTag(e.target) + ' · removed a member' },
        promote:   { icon: 'fa-crown',          html: (e) => actorTag(e.actor) + ' 升 ' + actorTag(e.target) + ' 為隊長 · promoted to leader' },
        promote_officer: { icon: 'fa-angles-up', html: (e) => actorTag(e.actor) + ' 升 ' + actorTag(e.target) + ' 為副手 · promoted to Vice' },
        demote:    { icon: 'fa-arrow-down',     html: (e) => actorTag(e.actor) + ' 將 ' + actorTag(e.target) + ' 降為隊員 · demoted to member' },
        wp_add:    { icon: 'fa-map-pin',        html: (e) => actorTag(e.actor) + ' 新增航點 ' + nameTag(e.name, e.color) + ' · added a waypoint' },
        wp_remove: { icon: 'fa-trash',          html: (e) => actorTag(e.actor) + ' 移除航點 ' + nameTag(e.name, e.color) + ' · removed a waypoint' },
        wp_rename: { icon: 'fa-pen',            html: (e) => actorTag(e.actor) + ' 航點改名為 ' + nameTag(e.name, e.color) + ' · renamed a waypoint' + (e.old ? ' (from ' + esc(e.old) + ')' : '') },
        wp_recolor:{ icon: 'fa-palette',        html: (e) => actorTag(e.actor) + ' 更改航點顏色 ' + nameTag(e.name, e.color) + ' · recoloured a waypoint' },
    };

    function renderSystemLine(m) {
        const e = m.event || {};
        const def = SYS_VERBS[e.verb];
        const row = el('div', 'sq-sys');
        const icon = el('i', 'fa-solid ' + ((def && def.icon) || 'fa-circle-info') + ' sq-sys-ico');
        const text = el('span', 'sq-sys-text');
        text.innerHTML = def ? def.html(e) : (actorTag(e.actor) + ' · ' + esc(e.verb || 'event'));
        const time = el('span', 'sq-sys-time', fmtTime(m.ts));
        row.appendChild(icon); row.appendChild(text); row.appendChild(time);
        return row;
    }

    function fmtTime(ts) {
        const n = Number(ts);
        if (!n) return '';
        const d = new Date(n * 1000);
        const hh = ('0' + d.getHours()).slice(-2);
        const mm = ('0' + d.getMinutes()).slice(-2);
        return hh + ':' + mm;
    }

    // Local calendar-day key (YYYY-MM-DD) for grouping messages by date.
    function dayKey(ts) {
        const n = Number(ts);
        if (!n) return null;
        const d = new Date(n * 1000);
        return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
    }
    // Human date-divider label: Today / Yesterday, else e.g. "24 Aug 2026".
    function dayLabel(ts) {
        const n = Number(ts);
        if (!n) return '';
        const d = new Date(n * 1000);
        const now = new Date();
        const startOf = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
        const diffDays = Math.round((startOf(now) - startOf(d)) / 86400000);
        if (diffDays === 0) return '今天 · Today';
        if (diffDays === 1) return '昨天 · Yesterday';
        const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        return d.getDate() + ' ' + months[d.getMonth()] + ' ' + d.getFullYear();
    }

    // Members popup: a centered modal with full-size member rows. Opened from the
    // "Members" bar in the right column. Scrolls internally only if it overflows
    // (won't happen at ≤6). Survives re-renders via rosterModalOpen (management
    // actions re-open it fresh so the list updates in place).
    function closeRosterModal() {
        rosterModalOpen = false;
        if (!root) return;
        const prev = root.querySelector('.sq-roster-modal');
        if (prev && prev.parentNode) prev.parentNode.removeChild(prev);
    }
    function openRosterModal() {
        if (!root || state.squadID <= 0) return;
        rosterModalOpen = true;
        const prev = root.querySelector('.sq-roster-modal');
        if (prev && prev.parentNode) prev.parentNode.removeChild(prev);

        const members = state.members || [];
        const count = members.length;
        const limit = state.limit || 4;
        const online = members.filter((m) => m.online).length;

        const overlay = el('div', 'sq-roster-modal');
        const boxEl = el('div', 'sq-roster-box');
        boxEl.addEventListener('click', (e) => e.stopPropagation());

        // Header: title + online/total + close.
        const head = el('div', 'sq-roster-modal-head');
        head.innerHTML =
            '<div class="sq-roster-modal-title"><i class="fa-solid fa-users"></i> 隊員 · Members</div>' +
            '<div class="sq-roster-modal-meta"><span class="sq-dot on"></span>' + online +
            ' 在線 · ' + count + ' / ' + limit + '</div>';
        const closeBtn = el('button', 'sq-icon-btn sq-roster-close', '<i class="fa-solid fa-xmark"></i>');
        closeBtn.title = '關閉 · Close';
        closeBtn.addEventListener('click', (e) => { e.stopPropagation(); closeRosterModal(); });
        head.appendChild(closeBtn);
        boxEl.appendChild(head);

        // Body: the member rows (reuses renderMember). Server already sorts
        // online-first then Leader > Vice > Member.
        const list = el('div', 'sq-roster-modal-list');
        members.forEach((m) => list.appendChild(renderMember(m)));
        boxEl.appendChild(list);

        // Leader invite row (only if there's room).
        if (state.isLeader && count < limit) boxEl.appendChild(buildInviteRow());

        overlay.appendChild(boxEl);
        overlay.addEventListener('click', (e) => { if (e.target === overlay) closeRosterModal(); });
        root.appendChild(overlay);
    }

    // ---- Squad switcher modal (switch active squad / create / join another) ----
    function closeSwitcher() {
        switcherOpen = false;
        if (!root) return;
        const prev = root.querySelector('.sq-switcher-modal');
        if (prev && prev.parentNode) prev.parentNode.removeChild(prev);
    }
    function openSwitcher() {
        if (!root) return;
        switcherOpen = true;
        const prev = root.querySelector('.sq-switcher-modal');
        if (prev && prev.parentNode) prev.parentNode.removeChild(prev);

        const atCap = (state.squadCount || 0) >= (state.maxSquads || 3);
        const overlay = el('div', 'sq-switcher-modal');
        const boxEl = el('div', 'sq-roster-box');
        boxEl.addEventListener('click', (e) => e.stopPropagation());

        const head = el('div', 'sq-roster-modal-head');
        head.innerHTML =
            '<div class="sq-roster-modal-title"><i class="fa-solid fa-repeat"></i> 切換小隊 · Switch squad</div>' +
            '<div class="sq-roster-modal-meta">' + esc(state.squadCount || 1) + ' / ' + esc(state.maxSquads || 3) + ' 小隊</div>';
        const closeBtn = el('button', 'sq-icon-btn sq-roster-close', '<i class="fa-solid fa-xmark"></i>');
        closeBtn.title = '關閉 · Close';
        closeBtn.addEventListener('click', (e) => { e.stopPropagation(); closeSwitcher(); });
        head.appendChild(closeBtn);
        boxEl.appendChild(head);

        const body = el('div', 'sq-switcher-body');
        const listWrap = el('div', 'sq-hub-list');
        body.appendChild(listWrap);
        renderMyList(listWrap, true);
        body.appendChild(buildCreateCard(atCap));
        body.appendChild(buildJoinCard(atCap));
        boxEl.appendChild(body);

        overlay.appendChild(boxEl);
        overlay.addEventListener('click', (e) => { if (e.target === overlay) closeSwitcher(); });
        root.appendChild(overlay);
    }

    // Invite-by-ID row (leader). Extracted so both the modal and any future spot
    // can reuse it.
    function buildInviteRow() {
        const inviteRow = el('div', 'sq-invite-row');
        const idIn = el('input', 'sq-input sq-input-id');
        // type=text (not number — the CEF number spinner renders too narrow to
        // read); filter to digits on input instead.
        idIn.type = 'text'; idIn.inputMode = 'numeric'; idIn.maxLength = 4;
        idIn.placeholder = '玩家 ID · Player server ID';
        idIn.addEventListener('input', () => { idIn.value = idIn.value.replace(/[^0-9]/g, ''); });
        const btn = el('button', 'sq-btn sq-btn-go', '<i class="fa-solid fa-user-plus"></i> 邀請 Invite');
        btn.addEventListener('click', async () => {
            const id = parseInt(idIn.value, 10);
            if (!id || id <= 0) { toast('請輸入玩家 ID。 Enter a player ID.', 'err'); return; }
            btn.disabled = true;
            const res = await call('squadInvite', { targetId: id });
            btn.disabled = false;
            if (res && res.ok) { idIn.value = ''; toast('已送出邀請。 Invite sent.', 'ok'); }
            else toast(errText(res), 'err');
        });
        inviteRow.appendChild(idIn);
        inviteRow.appendChild(btn);
        return inviteRow;
    }

    // Modal confirmation (NOT window.confirm — the CEF blocking dialog freezes
    // the NUI with focus stuck). Renders an overlay inside the panel; the poll
    // skips render() while .sq-confirm is present so it can't be wiped away.
    function confirmDialog(opts) {
        if (!root) return;
        const prev = root.querySelector('.sq-confirm-overlay');
        if (prev) prev.parentNode.removeChild(prev);

        const overlay = el('div', 'sq-confirm-overlay');
        const box = el('div', 'sq-confirm');
        box.appendChild(el('div', 'sq-confirm-title', esc(opts.title || '確認 · Confirm')));
        if (opts.body) box.appendChild(el('div', 'sq-confirm-body', esc(opts.body)));
        const btns = el('div', 'sq-confirm-btns');
        const cancel = el('button', 'sq-btn sq-btn-ghost', opts.cancelLabel || '取消 Cancel');
        const ok = el('button', 'sq-btn sq-btn-danger', esc(opts.okLabel || '確定 OK'));
        btns.appendChild(cancel); btns.appendChild(ok);
        box.appendChild(btns);
        overlay.appendChild(box);

        function done() { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }
        cancel.addEventListener('click', (e) => { e.stopPropagation(); done(); });
        ok.addEventListener('click', (e) => { e.stopPropagation(); done(); if (opts.onOk) opts.onOk(); });
        overlay.addEventListener('click', (e) => { if (e.target === overlay) done(); });
        box.addEventListener('click', (e) => e.stopPropagation());
        root.appendChild(overlay);
    }

    // Full-size image lightbox (click a chat image). Click anywhere to close.
    function openImageViewer(url) {
        if (!root || !url) return;
        const prev = root.querySelector('.sq-imgview');
        if (prev) prev.parentNode.removeChild(prev);
        const overlay = el('div', 'sq-imgview');
        const im = el('img', 'sq-imgview-img');
        im.src = url;
        overlay.appendChild(im);
        overlay.addEventListener('click', () => { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); });
        root.appendChild(overlay);
    }

    // Remove any open self-popover (colour or nickname).
    // The rename popover anchors to the squad name, which now lives in the flyout
    // TOP BAR (outside #squad-body). So popover queries must sweep both root AND the
    // header slot — otherwise a top-bar popover can't be toggled/closed/dismissed.
    function anySqPop() {
        if (root && root.querySelector('.sq-pop')) return true;
        const slot = headSlot();
        return !!(slot && slot.querySelector('.sq-pop'));
    }
    function closePopovers() {
        if (root) root.querySelectorAll('.sq-pop').forEach((p) => p.parentNode.removeChild(p));
        const slot = headSlot();
        if (slot) slot.querySelectorAll('.sq-pop').forEach((p) => p.parentNode.removeChild(p));
    }
    function closeColorPopover() { closePopovers(); }

    function openColorPopover(anchorRow) {
        // toggle: if one is already open, close it
        if (root.querySelector('.sq-color-pop')) { closePopovers(); return; }
        closePopovers();

        const pop = el('div', 'sq-pop sq-color-pop');
        pop.appendChild(el('div', 'sq-pop-title', '選擇地圖顏色 · Choose map colour'));
        const grid = el('div', 'sq-swatches');
        BLIP_COLORS.forEach((c) => {
            const sw = el('button', 'sq-swatch' + (selfBlipColor === c.idx ? ' active' : ''));
            sw.style.background = c.hex;
            sw.title = c.name;
            sw.addEventListener('click', async (ev) => {
                ev.stopPropagation();
                selfBlipColor = c.idx;
                grid.querySelectorAll('.sq-swatch').forEach((n) => n.classList.remove('active'));
                sw.classList.add('active');
                const res = await call('squadSetBlipColor', { color: c.idx });
                if (res && res.ok) toast('已更新地圖顏色 · Map colour updated.', 'ok');
                else toast(errText(res), 'err');
                closePopovers();
            });
            grid.appendChild(sw);
        });
        pop.appendChild(grid);
        pop.addEventListener('click', (e) => e.stopPropagation());
        anchorRow.appendChild(pop);
        armPopoverDismiss();
    }

    // Deferred outside-click dismiss shared by both self popovers.
    function armPopoverDismiss() {
        setTimeout(() => {
            const off = () => { closePopovers(); document.removeEventListener('click', off); };
            document.addEventListener('click', off);
        }, 0);
    }

    // Nickname popover: text input + Save / Clear. Team-only, clears on leave.
    function openNickPopover(anchorRow, m) {
        if (root.querySelector('.sq-nick-pop')) { closePopovers(); return; }
        closePopovers();

        const pop = el('div', 'sq-pop sq-nick-pop');
        pop.appendChild(el('div', 'sq-pop-title', '隊內暱稱 · Team nickname'));
        const rowEl = el('div', 'sq-nick-row');
        const input = el('input', 'sq-input');
        input.type = 'text'; input.maxLength = 32;
        input.placeholder = (m && m.realName) ? m.realName : 'Nickname';
        input.value = (m && m.nickname) ? m.nickname : '';
        const save = el('button', 'sq-btn sq-btn-go', '儲存 Save');
        rowEl.appendChild(input); rowEl.appendChild(save);
        pop.appendChild(rowEl);
        const clear = el('button', 'sq-btn sq-btn-ghost sq-nick-clear', '清除暱稱 · Clear (use real name)');
        pop.appendChild(clear);

        async function commit(nick) {
            const res = await call('squadSetNickname', { nickname: nick });
            if (res && res.ok) {
                toast(nick ? ('暱稱已設定 · Nickname set.') : ('已清除暱稱 · Nickname cleared.'), 'ok');
                closePopovers();
                setTimeout(refreshState, 250);
            } else toast(errText(res), 'err');
        }
        save.addEventListener('click', (e) => { e.stopPropagation(); commit((input.value || '').trim()); });
        clear.addEventListener('click', (e) => { e.stopPropagation(); commit(''); });
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit((input.value || '').trim()); }
            else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePopovers(); }
        });

        pop.addEventListener('click', (e) => e.stopPropagation());
        anchorRow.appendChild(pop);
        input.focus();
        armPopoverDismiss();
    }

    // Rename-squad popover (leader only): text input + Save.
    function openRenamePopover(anchorEl) {
        const slot = headSlot();
        if (slot && slot.querySelector('.sq-rename-pop')) { closePopovers(); return; }
        closePopovers();

        const pop = el('div', 'sq-pop sq-rename-pop');
        pop.appendChild(el('div', 'sq-pop-title', '小隊名稱 · Squad name'));
        const rowEl = el('div', 'sq-nick-row');
        const input = el('input', 'sq-input');
        input.type = 'text'; input.maxLength = 64;
        input.placeholder = 'Squad name';
        input.value = state.name || '';
        const save = el('button', 'sq-btn sq-btn-go', '儲存 Save');
        rowEl.appendChild(input); rowEl.appendChild(save);
        pop.appendChild(rowEl);

        async function commit() {
            const name = (input.value || '').trim();
            if (!name) { toast('請輸入名稱。 Enter a name.', 'err'); return; }
            const res = await call('squadRename', { name: name });
            if (res && res.ok) {
                state.name = res.name || name;
                toast('小隊已改名 · Squad renamed.', 'ok');
                closePopovers();
                render();
            } else toast(errText(res), 'err');
        }
        save.addEventListener('click', (e) => { e.stopPropagation(); commit(); });
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit(); }
            else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePopovers(); }
        });

        pop.addEventListener('click', (e) => e.stopPropagation());
        anchorEl.appendChild(pop);
        input.focus();
        armPopoverDismiss();
    }

    // One roster row: name, role badge, online dot, actions (leader-gated).
    // Every safe blip ID → its ACTUAL GTA hex (from the FiveM blips doc). Covers
    // the picker set plus legacy/config IDs so stored blipColors still resolve to
    // the true rendered colour. Keep in sync with client BLIP_RGB.
    const BLIP_HEX = {
        0: '#fefefe', 1: '#e03232', 8: '#fe7ac3', 11: '#8dcea7', 17: '#ea8e50',
        25: '#0c7b56', 26: '#7ac3fe', 27: '#ab3ce6', 38: '#2c6db8', 40: '#4c4c4c',
        46: '#ecf029', 47: '#ff9a18', 48: '#f644a5', 50: '#8a6de3',
    };
    function hexForBlip(idx) {
        for (let i = 0; i < BLIP_COLORS.length; i++) { if (BLIP_COLORS[i].idx === idx) return BLIP_COLORS[i].hex; }
        return BLIP_HEX[idx] || null;
    }

    function renderMember(m) {
        const row = el('div', 'sq-member' + (m.online ? '' : ' offline') + (m.isSelf ? ' sq-member-self' : ''));
        row.style.position = 'relative';   // anchor for self popovers
        const roleLabel = m.isOwner ? '隊長 Leader' : (m.role === 'vice' ? '副手 Vice' : '隊員 Member');
        // Dot tinted to the member's chosen map colour (falls back to online green).
        const chosenHex = m.blipColor != null ? hexForBlip(m.blipColor) : null;
        const dotStyle = chosenHex ? (' style="background:' + chosenHex + '"') : '';
        const dot = '<span class="sq-dot' + (m.online ? ' on' : '') + '"' + dotStyle + '></span>';
        // Show the nickname (m.name) with the registered char name underneath when
        // a nickname is set, so it's clear who's who.
        const hasNick = m.nickname != null && m.nickname !== '';
        const subName = (hasNick && m.realName) ? ('<span class="sq-m-realname">' + esc(m.realName) + '</span>') : '';
        const info = el('div', 'sq-m-info');
        info.innerHTML = dot +
            '<span class="sq-m-name-wrap"><span class="sq-m-name">' + esc(m.name) +
            (m.isSelf ? ' <span class="sq-you">你 You</span>' : '') + '</span>' + subName + '</span>' +
            '<span class="sq-m-role ' + (m.isOwner ? 'owner' : (m.role === 'vice' ? 'vice' : '')) + '">' + esc(roleLabel) + '</span>';
        row.appendChild(info);

        const acts = el('div', 'sq-m-acts');

        // Self-only: colour picker (palette icon) + rename (pencil icon).
        if (m.isSelf) {
            const colorBtn = el('button', 'sq-icon-btn', '<i class="fa-solid fa-palette"></i>');
            colorBtn.title = '選擇地圖顏色 · Pick map colour';
            colorBtn.addEventListener('click', (e) => { e.stopPropagation(); openColorPopover(row); });
            acts.appendChild(colorBtn);

            const nickBtn = el('button', 'sq-icon-btn', '<i class="fa-solid fa-pen"></i>');
            nickBtn.title = '設定隊內暱稱 · Set team nickname';
            nickBtn.addEventListener('click', (e) => { e.stopPropagation(); openNickPopover(row, m); });
            acts.appendChild(nickBtn);
        }

        // Locate (set GTA waypoint) — available for online members that aren't you.
        if (m.online && !m.isSelf) {
            const loc = el('button', 'sq-icon-btn', '<i class="fa-solid fa-location-crosshairs"></i>');
            loc.title = '在地圖標記 · Set map waypoint';
            loc.addEventListener('click', () => { API().post('squadWaypointToMember', { memberId: m.id }); toast('已標記位置。 Waypoint set.', 'ok'); });
            acts.appendChild(loc);
        }

        // Leader-only management (not on self, not on other owners).
        if (state.isLeader && !m.isSelf && !m.isOwner) {
            if (m.role === 'vice') {
                // Vice → demote back to member.
                const dem = el('button', 'sq-icon-btn', '<i class="fa-solid fa-angles-down"></i>');
                dem.title = '降為隊員 · Demote to member';
                dem.addEventListener('click', () => act('squadDemote', m));
                acts.appendChild(dem);
            } else {
                // Member → manual promote to Vice (the only path up).
                const promOff = el('button', 'sq-icon-btn', '<i class="fa-solid fa-angles-up"></i>');
                promOff.title = '升為副手 · Promote to Vice';
                promOff.addEventListener('click', () => act('squadPromoteOfficer', m));
                acts.appendChild(promOff);
            }

            // Transfer leadership (crown) — steps you down to a plain member.
            const prom = el('button', 'sq-icon-btn', '<i class="fa-solid fa-crown"></i>');
            prom.title = '轉讓隊長 · Transfer leadership';
            prom.addEventListener('click', () => {
                confirmDialog({
                    title: '轉讓隊長？ · Transfer leadership?',
                    body: '將隊長身分轉給 ' + esc(m.name) + '？你會變回一般隊員。 Hand leadership to ' + esc(m.name) + '? You will become a regular member.',
                    okLabel: '轉讓 Transfer',
                    onOk: () => act('squadPromote', m),
                });
            });
            acts.appendChild(prom);

            const kick = el('button', 'sq-icon-btn sq-icon-danger', '<i class="fa-solid fa-user-xmark"></i>');
            kick.title = '踢出 · Kick';
            kick.addEventListener('click', () => act('squadKick', m));
            acts.appendChild(kick);
        }

        row.appendChild(acts);
        return row;
    }

    async function act(name, m) {
        const res = await call(name, { squadID: state.squadID, memberCitizenId: m.citizenid, memberId: m.id });
        if (res && res.ok) setTimeout(refreshState, 300);
        else toast('操作失敗。 Action failed.', 'err');
    }

    // ==== atlas map ====
    function renderMapCard() {
        const card = el('div', 'sq-map-card');
        const title = el('div', 'sq-card-title', '<i class="fa-solid fa-map-location-dot"></i> 隊伍地圖 · Squad Map');
        const hintTxt = state.canEditWp
            ? '滾輪縮放 · 拖曳/WASD 平移 · 雙擊新增 · Scroll zoom · drag/WASD pan · dbl-click add'
            : '滾輪縮放 · 拖曳/WASD 平移 · Scroll zoom · drag/WASD pan';
        const hint = el('span', 'sq-map-hint', hintTxt);
        title.appendChild(hint);
        card.appendChild(title);

        const mapWrap = el('div', 'sq-map');
        const cv = el('canvas', 'sq-map-canvas');
        cv.id = 'sq-map-canvas';
        // Match the atlas aspect ratio (1920:2377) at a crisp backing resolution.
        // CSS stretches width to the panel; keeping backing store proportional
        // avoids the blurry/squished look from a fixed 520x640 store.
        cv.width = 480; cv.height = 594;
        mapWrap.appendChild(cv);

        // Overlay control cluster (zoom, reset, focus/add my location).
        const ctrls = el('div', 'sq-map-ctrls');
        function mkCtrl(icon, tip, fn) {
            const b = el('button', 'sq-map-btn', '<i class="fa-solid ' + icon + '"></i>');
            b.title = tip;
            b.addEventListener('click', (e) => { e.stopPropagation(); fn(); });
            ctrls.appendChild(b);
            return b;
        }
        mkCtrl('fa-plus', '放大 · Zoom in', () => { mapView.zoom *= 1.3; clampView(); drawAtlas(); });
        mkCtrl('fa-minus', '縮小 · Zoom out', () => { mapView.zoom /= 1.3; clampView(); drawAtlas(); });
        mkCtrl('fa-expand', '重置 · Reset view', () => { mapView = { zoom: 1, x: 0, y: 0 }; drawAtlas(); });
        mkCtrl('fa-location-arrow', '定位我 · Focus my location', async () => {
            const pos = await call('squadMyPos');
            const a = pos && worldToAtlas(pos.x, pos.y);
            if (!a) { toast('無法定位 · Location unavailable.', 'err'); return; }
            if (mapView.zoom < 2.5) mapView.zoom = 2.5;
            centerViewOn(a.nx, a.ny);
            drawAtlas();
        });
        // Add-waypoint controls: vice + leader only (members are view-only).
        if (state.canEditWp) {
            mkCtrl('fa-map-pin', '新增我的位置為路點 · Add my location as waypoint', async () => {
                const pos = await call('squadMyPos');
                const a = pos && worldToAtlas(pos.x, pos.y);
                if (!a) { toast('無法定位 · Location unavailable.', 'err'); return; }
                openWpForm(a.nx, a.ny, { x: pos.x, y: pos.y });
            });
        }
        mapWrap.appendChild(ctrls);
        card.appendChild(mapWrap);

        // Inline label prompt (NOT window.prompt — the CEF blocking dialog can't
        // be dismissed and freezes the whole NUI with focus stuck). Double-click
        // reveals this row pre-filled with the clicked spot; Enter/Add commits.
        const wpForm = el('div', 'sq-wp-form hidden');
        wpForm.id = 'sq-wp-form';
        const wpRow = el('div', 'sq-wp-form-row');
        const wpInput = el('input', 'sq-input');
        wpInput.type = 'text'; wpInput.maxLength = 96; wpInput.placeholder = '路點名稱 · Waypoint label';
        const wpAdd = el('button', 'sq-btn sq-btn-go sq-wp-add', '<i class="fa-solid fa-map-pin"></i> 新增 Add');
        const wpCancel = el('button', 'sq-btn sq-btn-ghost sq-wp-cancel', '取消 Cancel');
        wpRow.appendChild(wpInput); wpRow.appendChild(wpAdd); wpRow.appendChild(wpCancel);
        // Waypoint colour swatches.
        const wpColors = el('div', 'sq-swatches sq-wp-swatches');
        WP_COLORS.forEach((hex) => {
            const sw = el('button', 'sq-swatch' + (wpColorPick === hex ? ' active' : ''));
            sw.style.background = hex;
            sw.addEventListener('click', () => {
                wpColorPick = hex;
                wpColors.querySelectorAll('.sq-swatch').forEach((n) => n.classList.remove('active'));
                sw.classList.add('active');
                // Reflect the colour choice into the live preview marker.
                if (wpPreview) { wpPreview.color = hex; drawAtlas(); }
            });
            wpColors.appendChild(sw);
        });
        wpForm.appendChild(wpRow);
        wpForm.appendChild(wpColors);
        // Overlay the form on the map (absolute, inside .sq-map) so revealing it
        // never grows the card or reflows/pushes the waypoint list below it.
        mapWrap.appendChild(wpForm);

        let pendingPt = null;  // { nx, ny, world? } from the last double-click / add-my-location
        let previewRaf = null;  // rAF handle for the pulsing add-preview marker

        // Keep the preview marker breathing while the add form is open. Cheap:
        // one rAF that just re-draws the atlas; stops the moment the form closes.
        function startPreviewAnim() {
            if (previewRaf != null) return;
            const tick = () => {
                if (!wpPreview) { previewRaf = null; return; }
                drawAtlas(true);   // repaint marker pulse only, don't rebuild the list
                previewRaf = requestAnimationFrame(tick);
            };
            previewRaf = requestAnimationFrame(tick);
        }
        function stopPreviewAnim() {
            if (previewRaf != null) { cancelAnimationFrame(previewRaf); previewRaf = null; }
        }

        // worldOverride (optional) = exact world coords, used by "add my location"
        // so the waypoint matches the player's real position, not a reprojection.
        function openWpForm(nx, ny, worldOverride) {
            pendingPt = { nx: nx, ny: ny, world: worldOverride || null };
            wpForm.classList.remove('hidden');
            wpInput.value = '';
            // Show a live marker at the spot immediately, tracking colour + name.
            wpPreview = { nx: nx, ny: ny, name: '', color: wpColorPick };
            startPreviewAnim();
            drawAtlas();
            wpInput.focus();
        }
        function closeWpForm() {
            pendingPt = null;
            wpForm.classList.add('hidden');
            wpInput.value = '';
            wpPreview = null;
            stopPreviewAnim();
            drawAtlas();
        }
        async function commitWp() {
            if (!pendingPt) return;
            const label = (wpInput.value || '').trim() || '目標 Objective';
            const world = pendingPt.world || atlasToWorld(pendingPt.nx, pendingPt.ny);
            const payload = {
                squadID: state.squadID, name: label.slice(0, 96), color: wpColorPick,
                nx: pendingPt.nx, ny: pendingPt.ny,
                wx: world ? world.x : null, wy: world ? world.y : null,
            };
            closeWpForm();
            const res = await call('squadAddWaypoint', payload);
            if (res && res.ok) loadWaypoints().then(() => { if (opened) drawAtlas(); });
            else toast(errText(res), 'err');
        }

        // Double-click on the map → open the inline label row at that spot
        // (translated through the current zoom/pan viewport).
        cv.addEventListener('dblclick', (e) => {
            if (!state.canEditWp) return;   // members can't add waypoints
            const rect = cv.getBoundingClientRect();
            const px = (e.clientX - rect.left) / rect.width * cv.width;
            const py = (e.clientY - rect.top) / rect.height * cv.height;
            const v = canvasToView(px, py, cv.width, cv.height);
            openWpForm(clamp01(v.nx), clamp01(v.ny));
        });

        // Scroll-wheel zoom, centered on the cursor.
        cv.addEventListener('wheel', (e) => {
            e.preventDefault();
            const rect = cv.getBoundingClientRect();
            const px = (e.clientX - rect.left) / rect.width * cv.width;
            const py = (e.clientY - rect.top) / rect.height * cv.height;
            const before = canvasToView(px, py, cv.width, cv.height);
            const factor = e.deltaY < 0 ? 1.2 : (1 / 1.2);
            mapView.zoom *= factor;
            clampView();
            // keep the point under the cursor fixed
            const after = canvasToView(px, py, cv.width, cv.height);
            mapView.x += before.nx - after.nx;
            mapView.y += before.ny - after.ny;
            clampView();
            drawAtlas();
        }, { passive: false });

        // Drag to pan (only when zoomed in). A real drag suppresses the dblclick-add
        // because it requires pointer movement past a small threshold.
        // Only the mousedown binds here (fresh per card); the window-level
        // move/up handlers are bound ONCE (see bindDragMove) so re-renders don't
        // stack stale closures pointing at detached canvases — those returned a
        // zero-width rect, dividing to Infinity and snapping the map to an edge.
        cv.addEventListener('mousedown', (e) => {
            if (mapView.zoom <= MAP_MIN_ZOOM) return;
            drag = { mx: e.clientX, my: e.clientY, vx: mapView.x, vy: mapView.y };
            cv.classList.add('dragging');
        });
        bindDragMove();
        wpAdd.addEventListener('click', commitWp);
        wpCancel.addEventListener('click', closeWpForm);
        wpInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); commitWp(); }
            else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeWpForm(); }
        });
        // Live-update the preview label as the user types the waypoint name.
        wpInput.addEventListener('input', () => {
            if (wpPreview) { wpPreview.name = wpInput.value || ''; drawAtlas(); }
        });

        // set the atlas background once the image is available
        setTimeout(drawAtlas, 0);
        return card;
    }

    // Standalone waypoint panel (below the map): its own scrollable box so a long
    // list scrolls internally on hover instead of stretching the whole column.
    function renderWpCard() {
        const card = el('div', 'sq-wp-card');
        card.appendChild(el('div', 'sq-card-title',
            '<i class="fa-solid fa-location-dot"></i> 路點 · Waypoints'));
        const list = el('div', 'sq-wp-list');
        list.id = 'sq-wp-list';
        card.appendChild(list);
        setTimeout(renderWpList, 0);
        return card;
    }

    // ---- viewport (zoom + pan) ----
    const MAP_MIN_ZOOM = 1, MAP_MAX_ZOOM = 6;
    function clampView() {
        if (mapView.zoom < MAP_MIN_ZOOM) mapView.zoom = MAP_MIN_ZOOM;
        if (mapView.zoom > MAP_MAX_ZOOM) mapView.zoom = MAP_MAX_ZOOM;
        const span = 1 / mapView.zoom;           // visible fraction of the atlas
        const maxOff = 1 - span;                 // furthest top-left corner
        if (mapView.x < 0) mapView.x = 0; else if (mapView.x > maxOff) mapView.x = maxOff;
        if (mapView.y < 0) mapView.y = 0; else if (mapView.y > maxOff) mapView.y = maxOff;
    }
    // normalized atlas (0..1) → canvas pixel, honoring zoom/pan.
    function viewToCanvas(nx, ny, W, H) {
        const span = 1 / mapView.zoom;
        return { x: ((nx - mapView.x) / span) * W, y: ((ny - mapView.y) / span) * H };
    }
    // canvas pixel → normalized atlas (0..1), honoring zoom/pan.
    function canvasToView(px, py, W, H) {
        const span = 1 / mapView.zoom;
        return { nx: mapView.x + (px / W) * span, ny: mapView.y + (py / H) * span };
    }
    // Recenter the view on a normalized point (used by "focus my location").
    function centerViewOn(nx, ny) {
        const span = 1 / mapView.zoom;
        mapView.x = nx - span / 2;
        mapView.y = ny - span / 2;
        clampView();
    }

    // Convert world coords → normalized atlas (0..1) using the config calibration.
    function worldToAtlas(x, y) {
        const c = atlasCfg;
        if (!c || !c.widthPx) return null;
        const sx = c.invertX ? -1 : 1;
        const sy = c.invertY ? -1 : 1;
        const px = c.zeroXPx + (x * c.scaleX * sx);
        const py = c.zeroYPx + (y * c.scaleY * sy);
        return { nx: clamp01(px / c.widthPx), ny: clamp01(py / c.heightPx) };
    }
    // Inverse: normalized atlas → world (for placing waypoints by clicking).
    function atlasToWorld(nx, ny) {
        const c = atlasCfg;
        if (!c || !c.widthPx) return null;
        const sx = c.invertX ? -1 : 1;
        const sy = c.invertY ? -1 : 1;
        const px = nx * c.widthPx;
        const py = ny * c.heightPx;
        return { x: (px - c.zeroXPx) / (c.scaleX * sx), y: (py - c.zeroYPx) / (c.scaleY * sy) };
    }
    function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

    let atlasImg = null;
    // skipList=true is used by the add-preview animation loop: it repaints the
    // canvas (marker pulse) without rebuilding the waypoint list every frame.
    function drawAtlas(skipList) {
        const cv = document.getElementById('sq-map-canvas');
        if (!cv) return;
        const ctx = cv.getContext('2d');
        const W = cv.width, H = cv.height;
        ctx.clearRect(0, 0, W, H);

        // Background image (atlas). Load lazily; fall back to a flat panel.
        const src = (atlasCfg && atlasCfg.image) ? atlasCfg.image.replace(/^html\//, '') : 'atlas1.webp';
        if (!atlasImg) {
            atlasImg = new Image();
            atlasImg.onload = () => { if (opened) drawAtlas(); };
            atlasImg.onerror = () => { atlasImg = 'failed'; if (opened) drawAtlas(); };
            atlasImg.src = src;
        }
        clampView();
        const span = 1 / mapView.zoom;
        if (atlasImg && atlasImg !== 'failed' && atlasImg.complete && atlasImg.naturalWidth) {
            // Source sub-rectangle of the atlas → full canvas (zoom/pan).
            const iw = atlasImg.naturalWidth, ih = atlasImg.naturalHeight;
            ctx.drawImage(atlasImg, mapView.x * iw, mapView.y * ih, span * iw, span * ih, 0, 0, W, H);
        } else {
            ctx.fillStyle = '#0a1017';
            ctx.fillRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(0,200,255,0.12)';
            for (let gx = 0; gx <= W; gx += 40) { ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, H); ctx.stroke(); }
            for (let gy = 0; gy <= H; gy += 40) { ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(W, gy); ctx.stroke(); }
        }

        // Waypoints
        waypoints.forEach((w) => {
            const pt = viewToCanvas(w.nx || 0, w.ny || 0, W, H);
            if (pt.x < -20 || pt.x > W + 20 || pt.y < -20 || pt.y > H + 20) return;
            ctx.beginPath();
            ctx.fillStyle = w.color || '#00c8ff';
            ctx.arc(pt.x, pt.y, 5, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = 'rgba(0,0,0,0.7)'; ctx.lineWidth = 1.5; ctx.stroke();
            if (w.name) {
                ctx.font = '11px "JetBrains Mono", monospace';
                // Dark outline so the coloured label stays readable on any terrain.
                ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0,0,0,0.85)';
                ctx.lineJoin = 'round';
                ctx.strokeText(String(w.name), pt.x + 8, pt.y + 4);
                ctx.fillStyle = w.color || '#00c8ff';   // label matches the blip colour
                ctx.fillText(String(w.name), pt.x + 8, pt.y + 4);
            }
        });

        // Live preview of the point being added (double-click → add form open).
        // Mirrors the saved-waypoint look but with a dashed halo so it reads as
        // "placing", and tracks the chosen colour + typed name in real time.
        if (wpPreview) {
            const pt = viewToCanvas(wpPreview.nx || 0, wpPreview.ny || 0, W, H);
            const col = wpPreview.color || wpColorPick || '#00c8ff';
            // Pulsing dashed ring around the spot.
            const t = (Date.now() % 1000) / 1000;              // 0..1
            const r = 8 + Math.sin(t * Math.PI * 2) * 2;       // gentle breathe
            ctx.save();
            ctx.setLineDash([4, 3]);
            ctx.lineWidth = 2; ctx.strokeStyle = col;
            ctx.beginPath(); ctx.arc(pt.x, pt.y, r + 4, 0, Math.PI * 2); ctx.stroke();
            ctx.restore();
            // Solid centre dot (same as a real waypoint).
            ctx.beginPath();
            ctx.fillStyle = col;
            ctx.arc(pt.x, pt.y, 5, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = 'rgba(0,0,0,0.7)'; ctx.lineWidth = 1.5; ctx.stroke();
            const label = (wpPreview.name && wpPreview.name.trim()) || '目標 Objective';
            ctx.font = '11px "JetBrains Mono", monospace';
            ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0,0,0,0.85)'; ctx.lineJoin = 'round';
            ctx.strokeText(label, pt.x + 8, pt.y + 4);
            ctx.fillStyle = col;
            ctx.fillText(label, pt.x + 8, pt.y + 4);
        }

        // Members (live positions from Lua) + you at center-ish (self not in list).
        positions.forEach((p) => {
            const a = worldToAtlas(p.x, p.y);
            if (!a) return;
            const pt = viewToCanvas(a.nx, a.ny, W, H);
            if (pt.x < -20 || pt.x > W + 20 || pt.y < -20 || pt.y > H + 20) return;
            ctx.beginPath();
            // Match the member's real blip: chosen colour, else leader gold / member blue.
            ctx.fillStyle = (p.blipColor != null ? hexForBlip(p.blipColor) : null)
                || (p.owner ? '#ecf029' : '#2c6db8');
            ctx.arc(pt.x, pt.y, 6, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = '#04121c'; ctx.lineWidth = 2; ctx.stroke();
            if (p.name) {
                const fn = String(p.name).split(/\s+/)[0];
                ctx.fillStyle = '#ffffff'; ctx.font = 'bold 11px "Inter", sans-serif';
                ctx.fillText(fn, pt.x + 9, pt.y + 4);
            }
        });

        if (!skipList) renderWpList();
    }

    function renderWpList() {
        const list = document.getElementById('sq-wp-list');
        if (!list) return;
        // drawAtlas() (and thus this) fires on every ~1.3s position poll. Don't
        // rebuild the list while an edit popover is open — that destroys the row
        // it's anchored to (the popover now lives on `root`, not in the list).
        if (list.querySelector('.sq-pop') || root.querySelector('.sq-wpedit-pop')) return;
        list.innerHTML = '';
        if (!waypoints.length) {
            const emptyMsg = state.canEditWp
                ? '尚無路點。雙擊地圖新增。 No waypoints — double-click the map to add.'
                : '尚無路點。僅副手/隊長可新增。 No waypoints — only Vice/Leader can add them.';
            list.appendChild(el('div', 'sq-wp-empty', emptyMsg));
            return;
        }
        waypoints.forEach((w) => {
            const row = el('div', 'sq-wp');
            row.innerHTML = '<span class="sq-wp-dot" style="background:' + esc(w.color || '#00c8ff') + '"></span>' +
                '<span class="sq-wp-name">' + esc(w.name || '路點') + '</span>';

            row.style.position = 'relative';   // anchor for the edit popover

            const hasWorld = (w.wx != null && w.wy != null);

            // Single 3-state minimap toggle: hidden → shown → flashing → hidden.
            const mode = wpBlipModes[String(w.id)] || 0;
            const blipBtn = el('button', 'sq-icon-btn sq-wp-blip mode-' + mode);
            const blipMeta = [
                { icon: 'fa-eye-slash', tip: '在地圖顯示 · Show on map' },
                { icon: 'fa-map-pin',   tip: '閃爍顯示 · Flash on map' },
                { icon: 'fa-tower-broadcast', tip: '從地圖隱藏 · Hide from map' },
            ][mode];
            blipBtn.innerHTML = '<i class="fa-solid ' + blipMeta.icon + '"></i>';
            blipBtn.title = blipMeta.tip;
            // The show/flash/hide toggle is a SHARED team ping (put this spot on
            // everyone's minimap), NOT a waypoint edit — so ALL members may use it.
            // (Add/edit/delete stay vice+leader only.)
            if (!hasWorld) { blipBtn.disabled = true; blipBtn.title = '此路點沒有世界座標 · No world coords'; }
            blipBtn.addEventListener('click', async (e) => {
                e.stopPropagation();
                if (!hasWorld) return;
                const res = await call('squadCycleWaypointBlip', {
                    waypointId: String(w.id), wx: w.wx, wy: w.wy, wz: w.wz, color: w.color, name: w.name,
                });
                if (res && res.ok) {
                    // Fall back to a local cycle if the server didn't echo a mode,
                    // so the icon never sticks / goes blank on a repeat press.
                    const cur = wpBlipModes[String(w.id)] || 0;
                    const newMode = (res.mode == null) ? ((cur + 1) % 3) : res.mode;
                    wpBlipModes[String(w.id)] = newMode;
                    // Shared status — say so, since it changes for the whole team.
                    const nm = [
                        '已為全隊從地圖隱藏 · Hidden for the whole squad',
                        '已為全隊在地圖顯示 · Shown for the whole squad',
                        '全隊地圖上閃爍 · Flashing for the whole squad',
                    ][newMode];
                    toast(nm, 'ok');
                    // The server broadcast re-renders via squadWaypointsChanged; this
                    // just updates the icon instantly for the clicker.
                    renderWpList();
                } else {
                    toast(errText(res), 'err');
                }
            });
            row.appendChild(blipBtn);

            // Fast waypoint: drop a GTA route marker on this saved point.
            const go = el('button', 'sq-icon-btn', '<i class="fa-solid fa-route"></i>');
            go.title = hasWorld ? '設定路線 · Set GPS route' : '此路點沒有世界座標 · No world coords for this point';
            if (!hasWorld) go.disabled = true;
            go.addEventListener('click', () => {
                if (!hasWorld) return;
                API().post('squadWaypointGoto', { wx: w.wx, wy: w.wy });
                toast('已設定路線 · Route set.', 'ok');
            });
            row.appendChild(go);

            // Edit + delete: vice + leader only. Members see the point and can
            // route to it, but can't rename/recolour/remove it.
            if (state.canEditWp) {
                const edit = el('button', 'sq-icon-btn', '<i class="fa-solid fa-pen"></i>');
                edit.title = '編輯路點 · Edit waypoint';
                edit.addEventListener('click', (e) => { e.stopPropagation(); openWpEditPopover(row, w); });
                row.appendChild(edit);

                const rm = el('button', 'sq-icon-btn sq-icon-danger', '<i class="fa-solid fa-xmark"></i>');
                rm.title = '刪除 · Remove';
                rm.addEventListener('click', (e) => {
                    e.stopPropagation();
                    confirmDialog({
                        title: '刪除路點 · Delete waypoint',
                        body: '確定要刪除「' + (w.name || '路點') + '」嗎？此操作會為全隊移除，無法復原。 Delete "' + (w.name || 'waypoint') + '" for the whole squad? This can\'t be undone.',
                        okLabel: '刪除 Delete',
                        onOk: async () => {
                            const res = await call('squadRemoveWaypoint', { squadID: state.squadID, waypointId: parseInt(w.id, 10) });
                            if (res && res.ok) { toast('已刪除路點 · Waypoint deleted.', 'ok'); loadWaypoints().then(() => { if (opened) drawAtlas(); }); }
                            else toast(errText(res), 'err');
                        },
                    });
                });
                row.appendChild(rm);
            }
            list.appendChild(row);
        });
    }

    // Edit-waypoint popover: rename + recolour an existing point (anchored on its
    // list row). Coords stay put — this is not a move.
    function openWpEditPopover(anchorRow, w) {
        if (root.querySelector('.sq-wpedit-pop')) { closePopovers(); return; }
        closePopovers();

        let pickColor = w.color || '#00c8ff';
        const pop = el('div', 'sq-pop sq-pop-up sq-wpedit-pop');
        pop.appendChild(el('div', 'sq-pop-title', '編輯路點 · Edit waypoint'));
        const rowEl = el('div', 'sq-nick-row');
        const input = el('input', 'sq-input');
        input.type = 'text'; input.maxLength = 96;
        input.placeholder = '路點名稱 · Waypoint label';
        input.value = w.name || '';
        const save = el('button', 'sq-btn sq-btn-go', '儲存 Save');
        rowEl.appendChild(input); rowEl.appendChild(save);
        pop.appendChild(rowEl);

        const swatches = el('div', 'sq-swatches');
        WP_COLORS.forEach((hex) => {
            const sw = el('button', 'sq-swatch' + (pickColor === hex ? ' active' : ''));
            sw.style.background = hex;
            sw.addEventListener('click', (ev) => {
                ev.stopPropagation();
                pickColor = hex;
                swatches.querySelectorAll('.sq-swatch').forEach((n) => n.classList.remove('active'));
                sw.classList.add('active');
            });
            swatches.appendChild(sw);
        });
        pop.appendChild(swatches);

        async function commit() {
            const res = await call('squadEditWaypoint', {
                squadID: state.squadID, waypointId: parseInt(w.id, 10),
                name: (input.value || '').trim(), color: pickColor,
            });
            if (res && res.ok) {
                toast('路點已更新 · Waypoint updated.', 'ok');
                closePopovers();
                loadWaypoints().then(() => { if (opened) drawAtlas(); });
            } else toast(errText(res), 'err');
        }
        save.addEventListener('click', (e) => { e.stopPropagation(); commit(); });
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit(); }
            else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closePopovers(); }
        });

        pop.addEventListener('click', (e) => e.stopPropagation());

        // Render on `root` with fixed positioning instead of inside the row —
        // the .sq-wp-list scroll box has overflow:auto, which clipped the popover
        // when it was a child. Anchor it just above the row, right-aligned.
        pop.style.position = 'fixed';
        pop.style.zIndex = '60';
        pop.style.bottom = 'auto'; pop.style.right = 'auto';   // override .sq-pop-up
        root.appendChild(pop);
        positionWpEditPop(pop, anchorRow);
        input.focus();
        armPopoverDismiss();
    }

    // Place the (fixed) edit popover above the anchor row, clamped to the viewport.
    function positionWpEditPop(pop, anchorRow) {
        if (!pop || !anchorRow) return;
        const r = anchorRow.getBoundingClientRect();
        const pw = pop.offsetWidth || 260;
        const ph = pop.offsetHeight || 180;
        let left = r.right - pw;                 // right-align to the row
        let top = r.top - ph - 6;                // open upward
        if (top < 8) top = r.bottom + 6;         // not enough room up → flip down
        if (left < 8) left = 8;
        const maxLeft = window.innerWidth - pw - 8;
        if (left > maxLeft) left = maxLeft;
        pop.style.left = Math.round(left) + 'px';
        pop.style.top = Math.round(top) + 'px';
    }

    // ==== small helpers ====
    // Old CEF has no navigator.clipboard — fall back to a hidden textarea + execCommand.
    function copyText(txt) {
        try {
            const ta = document.createElement('textarea');
            ta.value = String(txt == null ? '' : txt);
            ta.style.position = 'fixed'; ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            document.execCommand('copy');
            document.body.removeChild(ta);
        } catch (e) { /* best-effort */ }
    }

    function toast(text, kind) {
        if (!root) return;
        let t = root.querySelector('.sq-toast');
        if (!t) { t = el('div', 'sq-toast'); root.appendChild(t); }
        t.className = 'sq-toast show ' + (kind === 'err' ? 'err' : 'ok');
        t.textContent = text;
        clearTimeout(t._h);
        t._h = setTimeout(() => { t.className = 'sq-toast'; }, 2600);
    }

    function errText(res) {
        const e = res && res.err;
        switch (e) {
            case 'already':          return '你已經在一個小隊裡。 You are already in a squad.';
            case 'full':             return '小隊已滿。 Squad is full.';
            case 'not_found':        return '找不到該邀請碼。 No squad with that code.';
            case 'bad_code':         return '邀請碼無效。 Invalid code.';
            case 'bad_id':           return '玩家 ID 無效。 Invalid player ID.';
            case 'offline':          return '該玩家不在線上。 That player is offline.';
            case 'target_in_squad':  return '該玩家已在此小隊。 That player is already in this squad.';
            case 'max_squads':       return '你最多只能加入 3 個小隊。 You can only be in 3 squads.';
            case 'target_max_squads': return '該玩家已加入 3 個小隊。 That player is already in 3 squads.';
            case 'not_member':       return '你不是該小隊成員。 You are not a member of that squad.';
            case 'not_leader':       return '只有隊長可以邀請。 Only the leader can invite.';
            case 'self':             return '不能邀請自己。 You can\'t invite yourself.';
            case 'no_squad':         return '你沒有小隊。 You are not in a squad.';
            case 'no_char':          return '角色尚未載入。 Character not loaded.';
            case 'not_owned':        return '那張相片不在你的相簿裡。 That photo isn\'t in your gallery.';
            default:                 return '操作失敗，請重試。 Something went wrong — try again.';
        }
    }

    // Escape handling: if the members popup, a confirm dialog, or a popover is
    // open, close THAT first and report handled=true so the hub doesn't close the
    // whole squad view out from under it. Returns false when nothing was open.
    function onEscape() {
        if (!root) return false;
        if (root.querySelector('.sq-switcher-modal')) { closeSwitcher(); return true; }
        if (root.querySelector('.sq-roster-modal')) { closeRosterModal(); return true; }
        if (root.querySelector('.sq-confirm-overlay')) {
            const o = root.querySelector('.sq-confirm-overlay'); if (o && o.parentNode) o.parentNode.removeChild(o);
            return true;
        }
        if (anySqPop()) { closePopovers(); return true; }
        const wp = root.querySelector('#sq-wp-form');
        if (wp && !wp.classList.contains('hidden')) { wp.classList.add('hidden'); return true; }
        return false;
    }

    window.HKSquad = { open, close, onState, onPositions, onWaypointsChanged, onInvite, onChatMessage, onOverlay, onEscape };
})();
