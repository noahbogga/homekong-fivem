/* ═══════════════════════════════════════════════════════════════
   HK-GARAGE NUI — left dock (sectioned list) + right-side 3D render
   with a floating detail card. Three sections:
     here   → cars in THIS garage (full controls + preview)
     other  → your cars in OTHER garages (greyed, locate only)
     street → cars parked on the street (greyed, locate only)
   ═══════════════════════════════════════════════════════════════ */
let currentVehicles = [];
let selectedIdx = null;
let searchTerm = "";           // active list filter (name/brand/colour/drivetrain/plate)
let pendingCondition = null;   // condition bar targets, filled when async data lands
let impoundMode = null;        // 'police'|'depot' when opened at an impound point
let impoundSpawn = null;       // where a retrieved impound car spawns
let adminMode = false;         // true when opened via /adminparking (adds Delete)
let previewToken = 0;          // bumped per selection; echoed back to reject stale async data
// Default collapse state: only the current garage's cars expanded; everything
// else (other garages / impound / depot / street) starts collapsed. Re-asserted
// on every menu open so it's always a fresh start page.
const collapsed = { here: false, other: true, police: true, depot: true, street: true };

const RES = "hk-parking";

// Escape user/DB-sourced strings before putting them in innerHTML (plates,
// brands, street names, mod labels can contain <>&" — breaks markup / CEF XSS).
function esc(s) {
    return String(s == null ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function post(path, body, cb) {
    fetch(`https://${RES}/${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(body || {}),
    })
        .then((r) => r.json().catch(() => null))
        .then((d) => cb && cb(d))
        .catch(() => {});
}

window.addEventListener("message", function (e) {
    const d = e.data;
    if (d.action === "VehicleList") {
        currentVehicles = d.vehicles || [];
        impoundMode = d.impound || null;         // 'police' | 'depot' | null(normal garage)
        impoundSpawn = d.impoundSpawn || null;
        adminMode = d.admin === true;            // /adminparking → show Delete action
        document.getElementById("garage-title").textContent = d.garageLabel || "Garage";
        document.getElementById("garage-sub").textContent = d.garageSub || "HOMEKONG";
        selectedIdx = null;
        // reset search each time the menu opens
        searchTerm = "";
        const sw = document.getElementById("search-wrap");
        const si = document.getElementById("search-input");
        if (sw) sw.classList.add("hidden");
        if (si) si.value = "";
        // FRESH START each open: only "此車庫 · This Garage" expanded, every other
        // section (other garages / impound / depot / street) collapsed.
        collapsed.here = false;
        collapsed.other = true;
        collapsed.police = true;
        collapsed.depot = true;
        collapsed.street = true;
        hideCard();
        buildList();
        // scroll the list back to the top so it never opens mid-way down.
        const vl = document.getElementById("vehicle-list");
        if (vl) vl.scrollTop = 0;
        document.getElementById("panel").classList.remove("hidden");
    } else if (d.action === "PreviewMods") {
        // Ignore stale async data for a car you've already clicked away from.
        if (d.token !== undefined && d.token !== previewToken) return;
        renderModSections(d.sections || []);
    } else if (d.action === "PreviewPerf") {
        if (d.token !== undefined && d.token !== previewToken) return;
        renderPerf(d.perf || null);
    } else if (d.action === "PreviewTier") {
        if (d.token !== undefined && d.token !== previewToken) return;
        renderTier(d.tier || null);
    } else if (d.action === "PreviewDrive") {
        if (d.token !== undefined && d.token !== previewToken) return;
        renderDrive(d.drive || null);
    }
});

document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeGarage();
});

document.addEventListener("DOMContentLoaded", function () {
    document.getElementById("btn-close").onclick = closeGarage;
    setupDragRotate();
    // Search: the magnifier toggles the input; typing live-filters the list.
    const wrap = document.getElementById("search-wrap");
    const input = document.getElementById("search-input");
    const btn = document.getElementById("btn-search");
    if (btn && wrap && input) {
        btn.onclick = () => {
            wrap.classList.toggle("hidden");
            if (!wrap.classList.contains("hidden")) {
                input.focus();
            } else {
                input.value = ""; searchTerm = ""; buildList();
            }
        };
        input.addEventListener("input", () => {
            searchTerm = input.value.trim().toLowerCase();
            buildList();
        });
    }
});

/* Drag-to-rotate the 3D preview: mousedown+move over the open (non-card, non-list)
   area posts a heading delta to Lua, which turns the turntable. */
function setupDragRotate() {
    let dragging = false, lastX = 0;
    const onCard = (t) => t.closest("#detail-card") || t.closest(".list-dock");
    const panelOpen = () => !document.getElementById("panel").classList.contains("hidden");
    document.addEventListener("mousedown", (e) => {
        if (e.button !== 0 || !panelOpen() || onCard(e.target)) return;   // LMB, menu open, not on card
        dragging = true; lastX = e.clientX;
    });
    document.addEventListener("mousemove", (e) => {
        if (!dragging) return;
        // If no primary button is actually held (a mouseup was missed / released
        // off-surface), stop — prevents the model spinning with no button down.
        if ((e.buttons & 1) === 0 || !panelOpen()) { dragging = false; return; }
        const dx = e.clientX - lastX;
        lastX = e.clientX;
        if (dx !== 0) post("previewRotate", { delta: dx * 0.5 });
    });
    document.addEventListener("mouseup", () => { dragging = false; });
}

function closeGarage() {
    if (previewTimer) { clearTimeout(previewTimer); previewTimer = null; }
    selectedIdx = null;
    pendingCondition = null;
    impoundMode = null;
    impoundSpawn = null;
    adminMode = false;
    document.getElementById("panel").classList.add("hidden");
    hideCard();
    post("closePreview");
    post("closeGarage");
}

function hideCard() {
    document.getElementById("detail-card").classList.add("hidden");
    const pc = document.getElementById("preview-controls");
    if (pc) pc.classList.add("hidden");
}

/* ── status mapping ─────────────────────────────────────────────────────
   state 1 stored · 2 police impound · 3 street parked · 4 mechanic depot */
function statusInfo(v) {
    if (v.state === 2) return { label: "警察扣押 Police Impound", dot: "s-impound", drivable: false };
    if (v.state === 4) return { label: "維修廠扣車 Depot", dot: "s-depot", drivable: false };
    if (v.state === 3) return { label: "泊咗喺街 Parked", dot: "s-parked", drivable: false };
    if (v.state === 1) return { label: "已停泊 Stored", dot: "s-garaged", drivable: true };
    return { label: "已駛出 Out", dot: "s-out", drivable: false };
}

/* section a vehicle belongs to (server tags v.section; fallback by state) */
function sectionOf(v) {
    if (v.section) return v.section;
    if (v.state === 2) return "police";
    if (v.state === 4) return "depot";
    if (v.state === 3) return "street";
    return "here";
}
/* ── build the sectioned list ───────────────────────────────── */
const SECTIONS = [
    { key: "here", title: "此車庫 · This Garage", cls: "here" },
    { key: "other", title: "其他車庫 · Other Garages", cls: "" },
    { key: "police", title: "警察扣車場 · Police Impound", cls: "impound" },
    { key: "depot", title: "維修廠扣車場 · Mechanic Depot", cls: "impound" },
    { key: "street", title: "街上泊車 · Parked Outside", cls: "" },
];

/* AND-search across the fields we expose per car. Empty term = match all. */
function matchesSearch(v) {
    if (!searchTerm) return true;
    const hay = [
        v.vehicleLabel, v.vehicle, v.brand, v.colour, v.drivetrain, v.plate,
    ].filter(Boolean).join(" ").toLowerCase();
    return searchTerm.split(/\s+/).every((tok) => hay.indexOf(tok) !== -1);
}

function buildList() {
    const list = document.getElementById("vehicle-list");
    list.innerHTML = "";

    // group indices by section (respecting the active search filter)
    const groups = { here: [], other: [], police: [], depot: [], street: [] };
    currentVehicles.forEach((v, i) => {
        if (!matchesSearch(v)) return;
        (groups[sectionOf(v)] || groups.other).push(i);
    });

    SECTIONS.forEach((sec) => {
        const idxs = groups[sec.key];
        if (idxs.length === 0) return;

        // ADMIN PANEL: sort by brand, then model (so the same car sticks together),
        // then plate — makes a big personal fleet easy to scan. Normal garage keeps
        // its original (server distance/state) ordering.
        if (adminMode) {
            const key = (v) => [
                (v.brand || "").toLowerCase(),
                (v.vehicleLabel || v.vehicle || "").toLowerCase(),
                (v.plate || "").toLowerCase(),
            ];
            idxs.sort((a, b) => {
                const ka = key(currentVehicles[a]), kb = key(currentVehicles[b]);
                for (let n = 0; n < ka.length; n++) {
                    if (ka[n] < kb[n]) return -1;
                    if (ka[n] > kb[n]) return 1;
                }
                return 0;
            });
        }

        const head = document.createElement("div");
        head.className = "sec-head " + sec.cls + (collapsed[sec.key] ? " collapsed" : "");
        head.innerHTML =
            '<span class="sec-caret">▼</span>' +
            '<span class="sec-title">' + sec.title + "</span>" +
            '<span class="sec-count">' + idxs.length + "</span>";

        const body = document.createElement("div");
        body.className = "sec-body" + (collapsed[sec.key] ? " collapsed" : "");

        head.onclick = () => {
            collapsed[sec.key] = !collapsed[sec.key];
            head.classList.toggle("collapsed", collapsed[sec.key]);
            body.classList.toggle("collapsed", collapsed[sec.key]);
        };

        idxs.forEach((i) => body.appendChild(buildRow(i, sec.key)));
        list.appendChild(head);
        list.appendChild(body);
    });
}

function buildRow(i, sectionKey) {
    const v = currentVehicles[i];
    const si = statusInfo(v);
    // available is undefined for impound/depot lists (server doesn't send it there) —
    // treat missing as available so only an EXPLICIT false marks a car unavailable.
    const gone = v.available === false;
    const dim = gone || sectionKey !== "here"; // greyed (other/impound/street/gone)

    const row = document.createElement("div");
    row.className = "veh-row" + (dim ? " dim" : "") + (gone ? " unavailable" : "");
    row.dataset.idx = i;

    const whereLine = dim && v.garageLabelOf
        ? '<div class="vr-where">' + esc(v.garageLabelOf) + (v.distance ? " · " + esc(v.distance) + "m" : "") + "</div>"
        : "";

    // A removed-model car shows an explicit "unavailable" tag in place of the status dot.
    const goneLine = gone
        ? '<div class="vr-gone">🚫 車輛不可用 · Unavailable</div>'
        : "";

    const brandLine = v.brand ? '<div class="vr-brand">' + esc(v.brand) + "</div>" : "";
    row.innerHTML =
        '<div class="vr-icon">🚗</div>' +
        '<div class="vr-body">' +
        '<div class="vr-name">' + esc(v.vehicleLabel || v.vehicle) + "</div>" +
        brandLine +
        '<div class="vr-plate">' + esc(v.plate || "") + "</div>" +
        whereLine +
        goneLine +
        "</div>" +
        (gone ? "" : '<div class="vr-dot ' + si.dot + '" title="' + esc(si.label) + '"></div>');

    // Every row opens the detail card WITH 3D preview. The action inside the
    // card differs (drive / pay-impound / locate) based on section + status.
    // Unavailable cars still open the card (to view mods/info) but the take-out
    // button is disabled there.
    row.onclick = () => selectVehicle(i);
    return row;
}

function locate(v) {
    post("locateVehicle", { plate: v.plate, waypoint: v.waypoint });
    closeSoft();
}
function barClass(p) { return p >= 75 ? "bar-green" : p >= 50 ? "bar-yellow" : "bar-red"; }

function buildData(v) {
    return {
        vehicle: v.vehicle, vehicleLabel: v.vehicleLabel, brand: v.brand, garage: v.garage,
        index: v.index, plate: v.plate, type: v.type, depotPrice: v.depotPrice,
        stats: { fuel: v.fuel, engine: v.engine, body: v.body },
    };
}

/* ── select a "here" car → 3D preview + floating card ───────── */
let previewTimer = null;      // debounce handle for the actual spawn
function selectVehicle(i) {
    const v = currentVehicles[i];
    if (!v) return;
    // Already showing this exact car → ignore (no flicker on re-click).
    if (i === selectedIdx) return;
    selectedIdx = i;

    document.querySelectorAll(".veh-row").forEach((r) => {
        r.classList.toggle("active", Number(r.dataset.idx) === i);
    });

    const si = statusInfo(v);
    const sec = sectionOf(v);
    const nameEl = document.getElementById("dc-name");
    nameEl.innerHTML = (v.brand ? '<span class="dc-brand">' + esc(v.brand) + "</span>" : "") +
                       esc(v.vehicleLabel || v.vehicle);
    document.getElementById("dc-plate").textContent = v.plate || "";

    const metaParts = ['<span class="dm-status">' + esc(si.label) + "</span>"];
    metaParts.push('<span id="dc-tier-slot"></span>');   // filled async by PreviewTier
    metaParts.push('<span id="dc-drive-slot"></span>');  // filled async by PreviewDrive
    if (v.drivetrain) metaParts.push("<span>" + esc(v.drivetrain) + "</span>");
    if (v.colour) metaParts.push("<span>" + esc(v.colour) + "</span>");
    if (sec !== "here" && v.garageLabelOf) metaParts.push("<span>" + esc(v.garageLabelOf) + "</span>");
    if (v.distance) metaParts.push("<span>" + esc(v.distance) + "m</span>");
    document.getElementById("dc-meta").innerHTML = metaParts.join("");

    // Condition bars — drawn at 0 width, then animated to value (rAF) so they
    // juice in the same as the performance bars, even though the data is instant.
    const maxV = { fuel: 100, engine: 1000, body: 1000 };
    let statsHtml = "";
    const targets = [];
    ["fuel", "engine", "body"].forEach((k) => {
        const raw = Number(v[k]);                       // NaN-safe (undefined → 0)
        const pct = isFinite(raw) ? Math.max(0, Math.min(100, (raw / maxV[k]) * 100)) : 0;
        const lbl = { fuel: "Fuel", engine: "Engine", body: "Body" }[k];
        targets.push({ k: k, pct: pct });
        statsHtml +=
            '<div class="dc-stat"><span class="ds-label">' + lbl + "</span>" +
            '<div class="ds-bar"><span class="' + barClass(pct) + '" data-stat="' + k + '" style="width:0%"></span></div></div>';
    });
    const statsEl = document.getElementById("dc-stats");
    statsEl.innerHTML = statsHtml;
    // Condition data is LOCAL/instant — fill it right away (own rAF) so the bars
    // never get stuck at 0% if PreviewPerf never arrives (hk-race down, etc.).
    pendingCondition = targets;
    requestAnimationFrame(() => {
        targets.forEach((t) => {
            const bar = statsEl.querySelector('[data-stat="' + t.k + '"]');
            if (bar) bar.style.width = t.pct + "%";
        });
    });

    // Perf + mods scaffolds are drawn IMMEDIATELY (so the layout never reflows as
    // async data trickles in). Bars start at 0 and animate to their value when the
    // PreviewPerf / PreviewMods messages arrive.
    scaffoldPerf();
    scaffoldMods();
    // Show the floating drag-to-rotate hint.
    document.getElementById("preview-controls").classList.remove("hidden");

    const fin = document.getElementById("dc-finance");
    if (v.balance && v.balance > 0) { fin.className = "dc-finance owed"; fin.textContent = "未付清 Balance: $" + Math.round(v.balance); }
    else { fin.className = "dc-finance"; fin.textContent = ""; }

    // Action button, context-aware.
    const data = buildData(v);
    const actions = document.getElementById("dc-actions");
    actions.innerHTML = "";
    let primary;
    if (impoundMode) {
        // Opened AT a depot/police point → Retrieve (pay + spawn the car here).
        const price = v.depotPrice || 12000;
        primary = btn("俾錢取車 Retrieve · $" + price.toLocaleString(), "btn-primary");
        primary.onclick = () => {
            post("retrieveImpound", { plate: v.plate, kind: impoundMode, spawn: impoundSpawn });
            closeSoft();
        };
    } else if (v.available === false) {
        // Model removed from the server (car pack pulled). Keep the entry visible
        // but block take-out until it's re-added; no drive/locate action.
        primary = btn("🚫 車輛不可用 · Unavailable", "btn-primary");
        primary.disabled = true;
        primary.classList.add("btn-disabled");
    } else if (sec === "here") {
        primary = btn("駕駛 Drive", "btn-primary");
        primary.onclick = () => { post("drivePreview", data); closeSoft(); };
    } else {
        // In the normal garage menu, impound/other/street cars are locate-only.
        const label = (sec === "police") ? "導航去警察扣車場 · Locate Impound"
                    : (sec === "depot")  ? "導航去扣車場 · Locate Depot"
                    : "導航 Locate";
        primary = btn(label, "btn-primary");
        primary.onclick = () => locate(v);
    }
    const back = btn("✕", "btn-ghost");
    back.onclick = closeGarage;
    actions.appendChild(primary);
    // ADMIN ONLY: two-step Delete. First click arms (turns red + relabels), a
    // second click within 4s permanently deletes the DB row; otherwise it disarms.
    if (adminMode) {
        const del = btn("🗑 刪除 Delete", "btn-danger");
        let armed = false, armTimer = null;
        const disarm = () => {
            armed = false;
            if (armTimer) { clearTimeout(armTimer); armTimer = null; }
            del.textContent = "🗑 刪除 Delete";
            del.classList.remove("btn-danger-armed");
        };
        del.onclick = () => {
            if (!armed) {
                armed = true;
                del.textContent = "⚠ 確認刪除? Confirm";
                del.classList.add("btn-danger-armed");
                armTimer = setTimeout(disarm, 4000);
                return;
            }
            disarm();
            post("adminDeleteVehicle", { plate: v.plate });
            closeSoft();
        };
        actions.appendChild(del);
    }
    actions.appendChild(back);

    document.getElementById("detail-card").classList.remove("hidden");

    // Debounced spawn: when spamming through cars, only the LAST selection (after
    // a short settle) actually spawns — avoids ramping every intermediate car.
    // A per-selection token is echoed back by the async Preview* messages so late
    // responses for a previous car are rejected (won't paint the wrong card).
    previewToken++;
    const myToken = previewToken;
    if (previewTimer) clearTimeout(previewTimer);
    const wantIdx = i;
    previewTimer = setTimeout(() => {
        previewTimer = null;
        if (wantIdx !== selectedIdx) return;   // selection moved on; skip stale
        data.token = myToken;
        post("previewVehicle", data);
    }, 220);
}

/* ── Performance panel ───────────────────────────────────────────────────
   Scaffold is drawn immediately (labels + empty bars); renderPerf fills the
   widths so the CSS transition animates them in. No numbers. */
const PERF_ROWS = [
    ["accel", "加速 Accel"],
    ["topspeed", "極速 Top Speed"],
    ["braking", "剎車 Braking"],
    ["traction", "抓地 Traction"],
];
function scaffoldPerf() {
    const el = document.getElementById("dc-perf");
    if (!el) return;
    let html = '<div class="section-label">性能 · Performance</div>';
    PERF_ROWS.forEach(([key, label]) => {
        html += '<div class="perf-row"><span class="perf-label">' + label + "</span>" +
                '<div class="perf-bar"><span data-perf="' + key + '" style="width:0%"></span></div></div>';
    });
    el.innerHTML = html;
}
/* Tier badge — arrives async from hk-race's real classifier on the preview car. */
function renderTier(tier) {
    const slot = document.getElementById("dc-tier-slot");
    if (!slot) return;
    if (!tier) { slot.outerHTML = '<span id="dc-tier-slot"></span>'; return; }
    slot.className = "dm-tier tier-" + tier.toLowerCase();
    slot.textContent = tier;
}

// Drive layout badge (RWD/AWD/FWD) from hk-handling's GetDriveClass. Async like
// the tier badge — resets to an empty slot when cleared so a stale value from a
// previously-selected car can never linger.
function renderDrive(drive) {
    const slot = document.getElementById("dc-drive-slot");
    if (!slot) return;
    if (!drive) { slot.outerHTML = '<span id="dc-drive-slot"></span>'; return; }
    slot.className = "dm-drive drive-" + drive.toLowerCase();
    slot.textContent = drive;
}

function renderPerf(perf) {
    if (!perf) return;
    // rAF so the 0% scaffold paints first, then the transition animates to value.
    requestAnimationFrame(() => {
        PERF_ROWS.forEach(([key]) => {
            const bar = document.querySelector('#dc-perf [data-perf="' + key + '"]');
            const raw = Number(perf[key]);
            const pct = isFinite(raw) ? Math.max(0, Math.min(100, raw * 100)) : 0;
            if (bar) bar.style.width = pct + "%";
        });
    });
}

/* ── Mods panel ──────────────────────────────────────────────────────────
   Generic systems (Engine / Drivetrain / Chassis / Wheels) are ALWAYS shown,
   defaulting to "Stock" until real data arrives. Non-generic groups (Power /
   Style) only appear if the car actually has those mods. */
const GENERIC_GROUPS = [
    ["引擎 · Engine", "Engine"],
    ["傳動 · Drivetrain", "Drivetrain"],
    ["底盤 · Chassis", "Chassis"],
    ["輪圈 · Wheels", "Wheels"],
];
function scaffoldMods() {
    const el = document.getElementById("dc-mods");
    if (!el) return;
    let html = '<div class="section-label">改裝 · Modifications</div>';
    GENERIC_GROUPS.forEach(([title]) => {
        html += '<div class="mod-group" data-group="' + title + '">' +
                '<div class="mod-group-title">' + title + "</div>" +
                '<div class="mod-line"><span class="ml-name">原廠 Stock</span><span class="ml-val">—</span></div>' +
                "</div>";
    });
    el.innerHTML = html;
}
function renderModSections(sections) {
    const el = document.getElementById("dc-mods");
    if (!el || !sections) return;
    // Map incoming sections by title so we can fill the generic scaffolds and
    // append any extra (Power/Style) groups.
    const byTitle = {};
    sections.forEach((s) => { byTitle[s.title] = s.items || []; });

    // Fill generic groups (match by the CN·EN title we scaffolded — the server
    // sends the same titles; fall back to keyword match).
    const genericTitles = GENERIC_GROUPS.map((g) => g[0]);
    genericTitles.forEach((title) => {
        const grp = el.querySelector('.mod-group[data-group="' + title + '"]');
        if (!grp) return;
        const items = byTitle[title] || [];
        let inner = '<div class="mod-group-title">' + title + "</div>";
        if (items.length) {
            items.forEach((it) => {
                inner += '<div class="mod-line"><span class="ml-name">' + esc(it.label) +
                         '</span><span class="ml-val">' + esc(it.value) + "</span></div>";
            });
        } else {
            inner += '<div class="mod-line"><span class="ml-name">原廠 Stock</span><span class="ml-val">—</span></div>';
        }
        grp.innerHTML = inner;
    });

    // Append non-generic groups (Power / Style / anything else) that have items.
    sections.forEach((s) => {
        if (genericTitles.indexOf(s.title) !== -1) return;
        if (!s.items || !s.items.length) return;
        const grp = document.createElement("div");
        grp.className = "mod-group";
        let inner = '<div class="mod-group-title">' + esc(s.title) + "</div>";
        s.items.forEach((it) => {
            inner += '<div class="mod-line"><span class="ml-name">' + esc(it.label) +
                     '</span><span class="ml-val">' + esc(it.value) + "</span></div>";
        });
        grp.innerHTML = inner;
        el.appendChild(grp);
    });
}

function btn(text, cls) { const b = document.createElement("button"); b.className = "btn " + cls; b.textContent = text; return b; }

/* close after an action that hands control back to the game (Lua releases focus) */
function closeSoft() {
    // Cancel any pending debounced spawn so a preview car doesn't appear AFTER
    // the player has driven off / left the menu (ghost spawn). The action's own
    // Lua callback (drivePreview/retrieveImpound/locateVehicle) stops the preview
    // + releases focus; this just hides the DOM + kills the timer.
    if (previewTimer) { clearTimeout(previewTimer); previewTimer = null; }
    selectedIdx = null;
    previewToken++;   // invalidate any in-flight async responses
    document.getElementById("panel").classList.add("hidden");
    hideCard();
}
