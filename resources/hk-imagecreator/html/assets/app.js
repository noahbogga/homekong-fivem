// HOMEKONG Image Creator - NUI App
let currentMode = null;
let presets = [];
let lastUrl = '';

// ============================================================
// NUI MESSAGE HANDLER
// ============================================================
window.addEventListener('message', (event) => {
    const data = event.data;

    switch (data.action) {
        case 'openStudio':
            currentMode = 'studio';
            presets = data.presets || [];
            showPanel('studio-panel');
            renderPresets(data.presets, data.currentPreset || 1);
            break;

        case 'openPhoto':
            currentMode = 'photo';
            showPanel('photo-panel');
            renderFovPresets(data.presets || []);
            break;

        case 'close':
            hideAll();
            break;

        case 'hideUI':
            document.getElementById('app').classList.add('hidden');
            break;

        case 'showUI':
            document.getElementById('app').classList.remove('hidden');
            break;

        case 'screenshotResult':
            if (data.success && data.url) {
                lastUrl = data.url;
                showResult(data.url);
            }
            break;
    }
});

// ============================================================
// UI FUNCTIONS
// ============================================================
function showPanel(id) {
    document.getElementById('app').classList.remove('hidden');
    document.querySelectorAll('.panel').forEach(p => p.classList.add('hidden'));
    document.getElementById(id).classList.remove('hidden');
}

function hideAll() {
    document.getElementById('app').classList.add('hidden');
    document.querySelectorAll('.panel').forEach(p => p.classList.add('hidden'));
    currentMode = null;
}

function renderPresets(list, active) {
    const container = document.getElementById('preset-list');
    container.innerHTML = '';
    list.forEach((p, i) => {
        const btn = document.createElement('div');
        btn.className = 'preset-btn' + (i + 1 === active ? ' active' : '');
        btn.textContent = p.name;
        btn.onclick = () => selectPreset(i + 1);
        container.appendChild(btn);
    });
}

function renderFovPresets(list) {
    const container = document.getElementById('fov-list');
    container.innerHTML = '';
    list.forEach((p) => {
        const btn = document.createElement('div');
        btn.className = 'preset-btn';
        btn.textContent = p.name + ' (' + p.fov + ')';
        btn.onclick = () => setFov(p.fov);
        container.appendChild(btn);
    });
}
function showResult(url) {
    if (currentMode === 'studio') {
        const section = document.getElementById('result-section');
        section.classList.remove('hidden');
        document.getElementById('result-url').value = url;
        document.getElementById('result-preview').src = url;
    } else {
        const section = document.getElementById('photo-result');
        section.classList.remove('hidden');
        document.getElementById('photo-url').value = url;
    }
}

// ============================================================
// ACTIONS -> NUI CALLBACKS
// ============================================================
function selectPreset(index) {
    // Update UI
    document.querySelectorAll('#preset-list .preset-btn').forEach((btn, i) => {
        btn.classList.toggle('active', i + 1 === index);
    });
    fetch(`https://hk-imagecreator/changePreset`, {
        method: 'POST',
        body: JSON.stringify({ index: index }),
    });
}

function setFov(fov) {
    document.getElementById('fov-slider').value = fov;
    fetch(`https://hk-imagecreator/changeFov`, {
        method: 'POST',
        body: JSON.stringify({ fov: fov }),
    });
}

function takeScreenshot() {
    fetch(`https://hk-imagecreator/takeScreenshot`, {
        method: 'POST',
        body: JSON.stringify({}),
    });
}

function spawnModel() {
    const model = document.getElementById('model-input').value.trim();
    if (!model) return;
    fetch(`https://hk-imagecreator/spawnModel`, {
        method: 'POST',
        body: JSON.stringify({ model: model }),
    });
}

function copyUrl() {
    const url = document.getElementById('result-url').value;
    if (url) {
        navigator.clipboard.writeText(url);
        fetch(`https://hk-imagecreator/copyUrl`, {
            method: 'POST',
            body: JSON.stringify({ url: url }),
        });
    }
}

function copyPhotoUrl() {
    const url = document.getElementById('photo-url').value;
    if (url) {
        navigator.clipboard.writeText(url);
        fetch(`https://hk-imagecreator/copyUrl`, {
            method: 'POST',
            body: JSON.stringify({ url: url }),
        });
    }
}

function closeUI() {
    fetch(`https://hk-imagecreator/close`, {
        method: 'POST',
        body: JSON.stringify({}),
    });
    hideAll();
}

// ============================================================
// SLIDER EVENTS
// ============================================================
document.getElementById('zoom-slider').addEventListener('input', (e) => {
    fetch(`https://hk-imagecreator/zoomCam`, {
        method: 'POST',
        body: JSON.stringify({ delta: parseFloat(e.target.value) - 6.0 }),
    });
});

document.getElementById('fov-slider').addEventListener('input', (e) => {
    setFov(parseFloat(e.target.value));
});

// ============================================================
// KEYBOARD - ESC to close
// ============================================================
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        closeUI();
    }
});

// Mouse drag for camera rotation in studio
let isDragging = false;
let lastX = 0, lastY = 0;

document.addEventListener('mousedown', (e) => {
    if (e.target.closest('.panel')) return;
    if (currentMode === 'studio') {
        isDragging = true;
        lastX = e.clientX;
        lastY = e.clientY;
    }
});

document.addEventListener('mousemove', (e) => {
    if (!isDragging) return;
    const deltaX = (e.clientX - lastX) * 0.5;
    const deltaY = (e.clientY - lastY) * 0.3;
    lastX = e.clientX;
    lastY = e.clientY;
    fetch(`https://hk-imagecreator/rotateCam`, {
        method: 'POST',
        body: JSON.stringify({ deltaX, deltaY }),
    });
});

document.addEventListener('mouseup', () => { isDragging = false; });

// Scroll to zoom
document.addEventListener('wheel', (e) => {
    if (e.target.closest('.panel')) return;
    if (currentMode === 'studio') {
        const delta = e.deltaY > 0 ? 0.5 : -0.5;
        const slider = document.getElementById('zoom-slider');
        slider.value = parseFloat(slider.value) + delta;
        fetch(`https://hk-imagecreator/zoomCam`, {
            method: 'POST',
            body: JSON.stringify({ delta: delta }),
        });
    } else if (currentMode === 'photo') {
        const delta = e.deltaY > 0 ? 2 : -2;
        const slider = document.getElementById('fov-slider');
        const newVal = Math.max(15, Math.min(100, parseFloat(slider.value) + delta));
        slider.value = newVal;
        setFov(newVal);
    }
});
