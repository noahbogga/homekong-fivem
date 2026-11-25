// ============================================================
// Control definitions per preset.
//  slider min/max = the USEFUL zone (fine steps for micro-adjust)
//  hardMin/hardMax = absolute limits the number box still accepts
// ============================================================
const CONTROL_DEFS = {
    chase: [
        { key: 'distanceTrim',     label: 'Distance Trim',        min: -2.0, max: 2.0,  step: 0.05, hardMin: -5, hardMax: 5 },
        { key: 'minExtraDistance', label: 'Start Dist (idle)',    min: 0.0, max: 15.0, step: 0.05, hardMin: 0, hardMax: 40 },
        { key: 'maxExtraDistance', label: 'Accel Zoom-Out (top)', min: 0.0, max: 15.0, step: 0.05, hardMin: 0, hardMax: 40 },
        { key: 'baseDistance',     label: 'Base Distance (fallbk)',min: 0.0, max: 10.0, step: 0.05, hardMin: 0, hardMax: 50 },
        { key: 'maxBaseDistance',  label: 'Max Distance (cap)',   min: 0.0, max: 15.0, step: 0.05, hardMin: 0, hardMax: 50 },
        { key: 'baseHeight',       label: 'Base Height',          min: 0.0, max: 10.0, step: 0.02, hardMin: 0, hardMax: 30 },
        { key: 'minHeight',        label: 'Min Height (floor)',   min: 0.0, max: 10.0, step: 0.02, hardMin: 0, hardMax: 30 },
        { key: 'heightLift',       label: 'Height Lift',          min: 0.0, max: 4.0,  step: 0.02, hardMin: 0, hardMax: 10 },
        { key: 'fovMin',           label: 'FOV (idle/low gear)',  min: 30.0, max: 65.0, step: 0.5, hardMin: 0, hardMax: 65 },
        { key: 'fovMax',           label: 'FOV (top gear)',       min: 30.0, max: 65.0, step: 0.5, hardMin: 0, hardMax: 65 },
        { key: 'lookAheadBase',    label: 'Idle Look-Ahead',      min: -2.0, max: 5.0, step: 0.05, hardMin: -10, hardMax: 20 },
        { key: 'rampMaxSpeedKmh',  label: 'Dist Ramp Speed (kmh)',min: 20.0, max: 200.0, step: 1.0, hardMin: 5, hardMax: 400 },
        { key: 'smoothness',       label: 'Move Lag (sec)',       min: 0.0, max: 1.0,  step: 0.01, hardMin: 0, hardMax: 2 },
        { key: 'fovSmoothness',    label: 'Zoom Lag (sec)',       min: 0.0, max: 1.0,  step: 0.01, hardMin: 0, hardMax: 2 },
    ],
    hood: [
        { key: 'offsetX',    label: 'Offset X (Right)',   min: -2.0, max: 2.0, step: 0.02, hardMin: -10, hardMax: 10 },
        { key: 'offsetY',    label: 'Offset Y (Forward)', min: 0.0, max: 5.0,  step: 0.02, hardMin: -10, hardMax: 10 },
        { key: 'offsetZ',    label: 'Offset Z (Up)',      min: 0.0, max: 3.0,  step: 0.02, hardMin: -5, hardMax: 10 },
        { key: 'rotX',       label: 'Pitch (deg)',        min: -45.0, max: 45.0, step: 0.5, hardMin: -90, hardMax: 90 },
        { key: 'fov',        label: 'FOV',                min: 0.0, max: 65.0, step: 0.5, hardMin: 0, hardMax: 65 },
        { key: 'smoothness', label: 'Move Lag (sec)',     min: 0.0, max: 1.0,  step: 0.01, hardMin: 0, hardMax: 2 },
    ],
};

let currentPreset = 'chase';
let currentViewMode = 1;   // tracks which V-key mode the menu is editing
const VIEW_MODE_NAMES = { 0: 'NEAR (V2)', 1: 'MEDIUM (V3)', 2: 'FAR (V4)', 4: 'FIRST-PERSON' };

// ============================================================
// Build the control panels dynamically.
//
// Each control is a compact widget:
//   - a number box (the SOURCE OF TRUTH for getVal/setVal)
//   - a thin "scope bar" with two draggable endpoints (◖ ◗) that set
//     the working range, with the hard-limit numbers shown at the ends
//   - a value slider whose full left→right travel maps to [rangeLo,rangeHi]
//     so narrowing the scope gives you fine resolution where you need it
// ============================================================
const WIDGETS = {};   // id -> { def, rangeLo, rangeHi, value, els }

function snap(v, step) {
    const s = step || 0.01;
    return Math.round(v / s) * s;
}
function fmt(v) {
    return (Math.round(v * 1000) / 1000).toString();
}

function buildControls() {
    const container = document.querySelector('.controls-container');
    container.innerHTML = '';

    // Clear stale widget references
    for (const id in WIDGETS) {
        delete WIDGETS[id];
    }

    for (const preset in CONTROL_DEFS) {
        const panel = document.createElement('div');
        panel.className = 'preset-controls' + (preset === currentPreset ? ' active' : '');
        panel.dataset.preset = preset;

        CONTROL_DEFS[preset].forEach(def => {
            const id = `${preset}-${def.key}`;
            const group = document.createElement('div');
            group.className = 'control-group';
            group.innerHTML = `
                <div class="control-label-row">
                    <label>${def.label}</label>
                    <input type="number" class="num-input" id="${id}-num"
                           min="${def.hardMin}" max="${def.hardMax}" step="${def.step}" value="${def.min}">
                </div>
                <div class="scope" id="${id}-scope">
                    <span class="scope-cap scope-lo-cap">${fmt(def.hardMin)}</span>
                    <div class="scope-bar">
                        <div class="scope-active"></div>
                        <div class="scope-end scope-end-lo" title="drag to set range start"></div>
                        <div class="scope-end scope-end-hi" title="drag to set range end"></div>
                    </div>
                    <span class="scope-cap scope-hi-cap">${fmt(def.hardMax)}</span>
                </div>
                <div class="vslider" id="${id}-vslider">
                    <div class="vslider-track"></div>
                    <div class="vslider-fill"></div>
                    <div class="vslider-thumb"></div>
                    <span class="vslider-lo">${fmt(def.min)}</span>
                    <span class="vslider-hi">${fmt(def.max)}</span>
                </div>
            `;
            panel.appendChild(group);

            WIDGETS[id] = {
                def,
                rangeLo: def.min,
                rangeHi: def.max,
                value: def.min,
                num: group.querySelector(`#${CSS.escape(id)}-num`),
                scope: group.querySelector(`#${CSS.escape(id)}-scope`),
                vslider: group.querySelector(`#${CSS.escape(id)}-vslider`),
            };
        });

        container.appendChild(panel);
    }

    // Wire all widgets AFTER all DOM elements are appended
    for (const id in WIDGETS) {
        wireWidget(id);
    }
}

// Redraw a widget's scope endpoints, value thumb, and labels from its state.
function renderWidget(id) {
    const w = WIDGETS[id];
    if (!w) return;
    const span = (w.def.hardMax - w.def.hardMin) || 1;
    const loPct = ((w.rangeLo - w.def.hardMin) / span) * 100;
    const hiPct = ((w.rangeHi - w.def.hardMin) / span) * 100;

    const endLo = w.scope.querySelector('.scope-end-lo');
    const endHi = w.scope.querySelector('.scope-end-hi');
    const active = w.scope.querySelector('.scope-active');
    endLo.style.left = loPct + '%';
    endHi.style.left = hiPct + '%';
    active.style.left = loPct + '%';
    active.style.width = (hiPct - loPct) + '%';

    // Value thumb position within the chosen range
    const rspan = (w.rangeHi - w.rangeLo) || 1;
    let vPct = ((w.value - w.rangeLo) / rspan) * 100;
    vPct = Math.max(0, Math.min(100, vPct));
    w.vslider.querySelector('.vslider-thumb').style.left = vPct + '%';
    w.vslider.querySelector('.vslider-fill').style.width = vPct + '%';
    w.vslider.querySelector('.vslider-lo').textContent = fmt(w.rangeLo);
    w.vslider.querySelector('.vslider-hi').textContent = fmt(w.rangeHi);

    if (document.activeElement !== w.num) w.num.value = fmt(w.value);
}

// Set a widget's value (clamps into [hardMin,hardMax]; widens range if needed).
function setWidgetValue(id, v) {
    const w = WIDGETS[id];
    if (!w || isNaN(v)) return;
    v = Math.max(w.def.hardMin, Math.min(w.def.hardMax, v));
    w.value = v;
    // If the value falls outside the current scope, grow the scope to include it.
    if (v < w.rangeLo) w.rangeLo = v;
    if (v > w.rangeHi) w.rangeHi = v;
    renderWidget(id);
}

// Convert a clientX on an element into a 0..1 fraction along its width.
function fracFromEvent(el, clientX) {
    const r = el.getBoundingClientRect();
    return Math.max(0, Math.min(1, (clientX - r.left) / r.width));
}

function wireWidget(id) {
    const w = WIDGETS[id];
    const def = w.def;

    // --- number box: source of truth, free typing within hard limits ---
    w.num.addEventListener('input', () => {
        const v = parseFloat(w.num.value);
        if (isNaN(v)) return;
        setWidgetValue(id, v);
    });

    // --- value slider: drag the thumb anywhere along the scoped range ---
    const vTrack = w.vslider;
    let draggingVal = false;
    const applyVal = (clientX) => {
        const f = fracFromEvent(vTrack, clientX);
        const v = snap(w.rangeLo + f * (w.rangeHi - w.rangeLo), def.step);
        w.value = Math.max(w.rangeLo, Math.min(w.rangeHi, v));
        renderWidget(id);
    };
    vTrack.addEventListener('mousedown', (e) => { draggingVal = true; applyVal(e.clientX); e.preventDefault(); });

    // --- scope endpoints: drag ◖ / ◗ to rescope the working range ---
    const endLo = w.scope.querySelector('.scope-end-lo');
    const endHi = w.scope.querySelector('.scope-end-hi');
    const bar = w.scope.querySelector('.scope-bar');
    let dragEnd = null;  // 'lo' | 'hi' | null
    endLo.addEventListener('mousedown', (e) => { dragEnd = 'lo'; e.preventDefault(); e.stopPropagation(); });
    endHi.addEventListener('mousedown', (e) => { dragEnd = 'hi'; e.preventDefault(); e.stopPropagation(); });

    // Shared move/up handlers on document so dragging is smooth off-element.
    document.addEventListener('mousemove', (e) => {
        if (draggingVal) { applyVal(e.clientX); return; }
        if (!dragEnd) return;
        const f = fracFromEvent(bar, e.clientX);
        const raw = snap(def.hardMin + f * (def.hardMax - def.hardMin), def.step);
        const minGap = def.step * 4;
        if (dragEnd === 'lo') {
            w.rangeLo = Math.min(raw, w.rangeHi - minGap);
            w.rangeLo = Math.max(def.hardMin, w.rangeLo);
        } else {
            w.rangeHi = Math.max(raw, w.rangeLo + minGap);
            w.rangeHi = Math.min(def.hardMax, w.rangeHi);
        }
        // Keep the value inside the new scope.
        w.value = Math.max(w.rangeLo, Math.min(w.rangeHi, w.value));
        renderWidget(id);
    });
    document.addEventListener('mouseup', () => { draggingVal = false; dragEnd = null; });

    renderWidget(id);
}

// ============================================================
// Tab switching
// ============================================================
function setupTabs() {
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => switchPreset(btn.dataset.preset));
    });
}

function switchPreset(preset) {
    currentPreset = preset;
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.preset === preset);
    });
    document.querySelectorAll('.preset-controls').forEach(panel => {
        panel.classList.toggle('active', panel.dataset.preset === preset);
    });
}

// ============================================================
// Read current values (number box is the source of truth)
// ============================================================
function getVal(preset, key) {
    const id = `${preset}-${key}`;
    const w = WIDGETS[id];
    if (w) return w.value;
    // Fallback to the number box if the widget isn't built yet.
    const num = document.getElementById(`${id}-num`);
    return num ? parseFloat(num.value) : 0;
}

function collectCurrentValues() {
    return {
        currentViewMode: currentViewMode,
        chase: {
            distanceTrim: getVal('chase', 'distanceTrim'),
            baseDistance: getVal('chase', 'baseDistance'),
            maxBaseDistance: getVal('chase', 'maxBaseDistance'),
            minExtraDistance: getVal('chase', 'minExtraDistance'),
            maxExtraDistance: getVal('chase', 'maxExtraDistance'),
            baseHeight: getVal('chase', 'baseHeight'),
            minHeight: getVal('chase', 'minHeight'),
            heightLift: getVal('chase', 'heightLift'),
            fovMin: getVal('chase', 'fovMin'),
            fovMax: getVal('chase', 'fovMax'),
            lookAheadBase: getVal('chase', 'lookAheadBase'),
            rampMaxSpeedKmh: getVal('chase', 'rampMaxSpeedKmh'),
            smoothness: getVal('chase', 'smoothness'),
            fovSmoothness: getVal('chase', 'fovSmoothness'),
        },
        hood: {
            offsetX: getVal('hood', 'offsetX'),
            offsetY: getVal('hood', 'offsetY'),
            offsetZ: getVal('hood', 'offsetZ'),
            rotX: getVal('hood', 'rotX'),
            fov: getVal('hood', 'fov'),
            smoothness: getVal('hood', 'smoothness'),
        },
    };
}

// ============================================================
// Load values from Lua config into the controls
// ============================================================
function setVal(preset, key, value) {
    const id = `${preset}-${key}`;
    if (!WIDGETS[id] || value === undefined || value === null) return;
    setWidgetValue(id, parseFloat(value));
}

// Load the chase tab from the resolved (per-V-mode merged) preset.
function loadResolvedChase(rc) {
    if (!rc) return;
    const dTrim = (rc.distanceTrim !== undefined && rc.distanceTrim !== null) ? rc.distanceTrim : 0.0;
    setVal('chase', 'distanceTrim', dTrim);
    setVal('chase', 'baseDistance', rc.baseDistance);
    setVal('chase', 'maxBaseDistance', rc.maxBaseDistance || 6.5);
    setVal('chase', 'minExtraDistance', rc.minExtraDistance || 0);
    setVal('chase', 'maxExtraDistance', rc.maxExtraDistance);
    setVal('chase', 'baseHeight', rc.baseHeight);
    setVal('chase', 'minHeight', rc.minHeight || 0.56);
    setVal('chase', 'heightLift', rc.heightLift || 0);
    if (rc.fov) {
        setVal('chase', 'fovMin', rc.fov.min);
        setVal('chase', 'fovMax', rc.fov.max);
    }
    const lookBase = (rc.lookAheadBase !== undefined && rc.lookAheadBase !== null) ? rc.lookAheadBase : 1.2;
    setVal('chase', 'lookAheadBase', lookBase);
    setVal('chase', 'rampMaxSpeedKmh', rc.rampMaxSpeedKmh || 120);
    setVal('chase', 'smoothness', rc.smoothness);
    setVal('chase', 'fovSmoothness', rc.fovSmoothness);
}

// Update the view-mode badge in the header.
function updateViewModeBadge() {
    const badge = document.getElementById('viewmode-badge');
    if (badge) {
        badge.textContent = VIEW_MODE_NAMES[currentViewMode] || ('mode ' + currentViewMode);
    }
}

function loadPresetData(presets) {
    if (presets.chase) {
        const dTrim = (presets.chase.distanceTrim !== undefined && presets.chase.distanceTrim !== null)
                      ? presets.chase.distanceTrim : 0.0;
        setVal('chase', 'distanceTrim', dTrim);
        setVal('chase', 'baseDistance', presets.chase.baseDistance);
        setVal('chase', 'maxBaseDistance', presets.chase.maxBaseDistance || 6.5);
        setVal('chase', 'minExtraDistance', presets.chase.minExtraDistance || 0);
        setVal('chase', 'maxExtraDistance', presets.chase.maxExtraDistance);
        setVal('chase', 'baseHeight', presets.chase.baseHeight);
        setVal('chase', 'minHeight', presets.chase.minHeight || 0.56);
        setVal('chase', 'heightLift', presets.chase.heightLift || 0);
        setVal('chase', 'fovMin', presets.chase.fov.min);
        setVal('chase', 'fovMax', presets.chase.fov.max);
        const lookBase = (presets.chase.lookAheadBase !== undefined && presets.chase.lookAheadBase !== null)
                         ? presets.chase.lookAheadBase : 1.2;
        setVal('chase', 'lookAheadBase', lookBase);
        setVal('chase', 'rampMaxSpeedKmh', presets.chase.rampMaxSpeedKmh || 120);
        setVal('chase', 'smoothness', presets.chase.smoothness);
        setVal('chase', 'fovSmoothness', presets.chase.fovSmoothness);
    }
    if (presets.hood) {
        setVal('hood', 'offsetX', presets.hood.offset.x);
        setVal('hood', 'offsetY', presets.hood.offset.y);
        setVal('hood', 'offsetZ', presets.hood.offset.z);
        setVal('hood', 'rotX', presets.hood.rotOffset.x);
        setVal('hood', 'fov', presets.hood.fov);
        setVal('hood', 'smoothness', presets.hood.smoothness);
    }
}

// ============================================================
// NUI fetch helpers
// ============================================================
function post(endpoint, data) {
    fetch(`https://${GetParentResourceName()}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data || {})
    });
}

function closeMenu() {
    document.getElementById('debug-menu').classList.add('hidden');
    post('closeMenu');
}

// ============================================================
// Wire up footer buttons + window messages
// ============================================================
function setupButtons() {
    document.getElementById('close-btn').addEventListener('click', closeMenu);
    document.getElementById('refresh-btn').addEventListener('click', () => post('refreshCamera'));
    document.getElementById('apply-btn').addEventListener('click', () => post('applyChanges', collectCurrentValues()));
    document.getElementById('broadcast-btn').addEventListener('click', () => post('broadcastChanges', collectCurrentValues()));
    document.getElementById('save-btn').addEventListener('click', () => post('saveToConfig', collectCurrentValues()));
    document.getElementById('reset-btn').addEventListener('click', () => post('resetValues'));

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeMenu();
    });
}

window.addEventListener('message', (event) => {
    const data = event.data;
    if (data.action === 'openMenu') {
        document.getElementById('debug-menu').classList.remove('hidden');
        // Track the current V-mode and load the resolved chase values for that mode
        if (data.currentViewMode !== undefined) currentViewMode = data.currentViewMode;
        updateViewModeBadge();
        if (data.resolvedChase) {
            loadResolvedChase(data.resolvedChase);
        } else if (data.presets) {
            loadPresetData(data.presets);
        }
        // Still load hood from the base presets (it's not per-V-mode)
        if (data.presets && data.presets.hood) {
            setVal('hood', 'offsetX', data.presets.hood.offset.x);
            setVal('hood', 'offsetY', data.presets.hood.offset.y);
            setVal('hood', 'offsetZ', data.presets.hood.offset.z);
            setVal('hood', 'rotX', data.presets.hood.rotOffset.x);
            setVal('hood', 'fov', data.presets.hood.fov);
            setVal('hood', 'smoothness', data.presets.hood.smoothness);
        }
    } else if (data.action === 'closeMenu') {
        document.getElementById('debug-menu').classList.add('hidden');
    } else if (data.action === 'updateValues') {
        if (data.currentViewMode !== undefined) currentViewMode = data.currentViewMode;
        updateViewModeBadge();
        if (data.resolvedChase) {
            loadResolvedChase(data.resolvedChase);
        } else if (data.presets) {
            loadPresetData(data.presets);
        }
    }
});

// ============================================================
// Init
// ============================================================
buildControls();
setupTabs();
setupButtons();
