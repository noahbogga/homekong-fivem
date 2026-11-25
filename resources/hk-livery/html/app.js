/* ─────────────────────────────────────────────
   hk-livery  ·  3D Direct Paint Engine
   Mouse → Lua raycast → UV coord → hidden canvas
   ───────────────────────────────────────────── */

(function () {
    'use strict';

    const TEX_SIZE = 1024;
    const MAX_UNDO = 40;
    const PRESETS  = [
        '#ffffff','#c0c0c0','#808080','#000000',
        '#ff0000','#ff8000','#ffff00','#80ff00',
        '#00ff00','#00ff80','#00ffff','#0080ff',
        '#0000ff','#8000ff','#ff00ff','#ff0080',
        '#00c8ff','#ff4060','#00e070','#ffb020',
        '#1a1a2e','#2d2d44','#3a1f5c','#0d3b66',
    ];

    // ── State ──
    let isOpen      = false;
    let tool        = 'pen';
    let color       = '#ffffff';
    let brushSize   = 8;
    let painting    = false;  // left-click dragging to paint
    let orbiting    = false;  // right-click dragging to orbit cam
    let lastPaintU  = -1;
    let lastPaintV  = -1;
    let undoStack   = [];
    let redoStack   = [];
    let overToolbar = false;
    let pendingExport = false;

    // ── DOM ──
    const editor      = document.getElementById('editor');
    const surface     = document.getElementById('paint-surface');
    const brushCursor = document.getElementById('brush-cursor');
    const canvas      = document.getElementById('tex-canvas');
    const ctx         = canvas.getContext('2d', { willReadFrequently: true });
    const colorInput  = document.getElementById('color-input');
    const colorHex    = document.getElementById('color-hex');
    const presetWrap  = document.getElementById('color-presets');
    const sizeSlider  = document.getElementById('brush-size');
    const btnUndo     = document.getElementById('btn-undo');
    const btnRedo     = document.getElementById('btn-redo');
    const btnClear    = document.getElementById('btn-clear');
    const btnSave     = document.getElementById('btn-save');
    const btnClose    = document.getElementById('btn-close');
    const toolbar     = document.getElementById('toolbar');
    const toast       = document.getElementById('toast');

    // ── Init canvas ──
    canvas.width  = TEX_SIZE;
    canvas.height = TEX_SIZE;
    ctx.lineCap   = 'round';
    ctx.lineJoin  = 'round';

    // ── Build color presets ──
    PRESETS.forEach(c => {
        const el = document.createElement('div');
        el.className = 'color-swatch' + (c === color ? ' active' : '');
        el.style.background = c;
        el.dataset.color = c;
        el.addEventListener('click', () => setColor(c));
        presetWrap.appendChild(el);
    });

    // ── Color ──
    function setColor(c) {
        color = c;
        colorInput.value = c;
        colorHex.value = c;
        document.querySelectorAll('.color-swatch').forEach(s =>
            s.classList.toggle('active', s.dataset.color === c));
        updateBrushCursor();
    }
    colorInput.addEventListener('input', () => setColor(colorInput.value));
    colorHex.addEventListener('change', () => {
        let v = colorHex.value.trim();
        if (/^#?[0-9a-fA-F]{6}$/.test(v)) {
            if (v[0] !== '#') v = '#' + v;
            setColor(v);
        }
    });

    // ── Tools ──
    document.querySelectorAll('.tool-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelector('.tool-btn.active')?.classList.remove('active');
            btn.classList.add('active');
            tool = btn.dataset.tool;
            updateBrushCursor();
        });
    });

    // ── Size slider ──
    sizeSlider.addEventListener('input', () => {
        brushSize = parseInt(sizeSlider.value);
        updateBrushCursor();
    });

    // ── Brush cursor visual ──
    function updateBrushCursor() {
        const px = Math.max(6, brushSize * 0.6);
        brushCursor.style.width  = px + 'px';
        brushCursor.style.height = px + 'px';
        brushCursor.style.borderColor = tool === 'eraser'
            ? 'rgba(255,64,96,0.8)' : 'rgba(0,200,255,0.8)';
    }
    updateBrushCursor();

    // ── History ──
    function pushUndo() {
        undoStack.push(ctx.getImageData(0, 0, TEX_SIZE, TEX_SIZE));
        if (undoStack.length > MAX_UNDO) undoStack.shift();
        redoStack = [];
        updateUndoButtons();
    }
    function undo() {
        if (!undoStack.length) return;
        redoStack.push(ctx.getImageData(0, 0, TEX_SIZE, TEX_SIZE));
        ctx.putImageData(undoStack.pop(), 0, 0);
        updateUndoButtons();
        scheduleExport();
    }
    function redo() {
        if (!redoStack.length) return;
        undoStack.push(ctx.getImageData(0, 0, TEX_SIZE, TEX_SIZE));
        ctx.putImageData(redoStack.pop(), 0, 0);
        updateUndoButtons();
        scheduleExport();
    }
    function updateUndoButtons() {
        btnUndo.disabled = !undoStack.length;
        btnRedo.disabled = !redoStack.length;
    }

    // ── Toolbar hover detection ──
    toolbar.addEventListener('mouseenter', () => { overToolbar = true; });
    toolbar.addEventListener('mouseleave', () => { overToolbar = false; });

    // ── Toolbar drag ──
    let dragOff = null;
    document.getElementById('toolbar-handle').addEventListener('mousedown', (e) => {
        dragOff = { x: e.clientX - toolbar.offsetLeft, y: e.clientY - toolbar.offsetTop };
        e.stopPropagation();
    });
    document.addEventListener('mousemove', (e) => {
        if (dragOff) {
            toolbar.style.left = (e.clientX - dragOff.x) + 'px';
            toolbar.style.top  = (e.clientY - dragOff.y) + 'px';
        }
    });
    document.addEventListener('mouseup', () => { dragOff = null; });

    // ──────────────────────────────────
    //  Mouse → Lua relay for 3D painting
    // ──────────────────────────────────

    surface.addEventListener('mousemove', (e) => {
        brushCursor.style.left = e.clientX + 'px';
        brushCursor.style.top  = e.clientY + 'px';

        if (overToolbar || dragOff) return;

        if (orbiting) {
            // Send orbit delta to Lua
            post('orbit', { dx: e.movementX, dy: e.movementY });
        } else if (painting) {
            // Send screen coords to Lua for raycast
            post('paint', { sx: e.clientX, sy: e.clientY });
        }
    });

    surface.addEventListener('mousedown', (e) => {
        if (overToolbar || dragOff) return;
        e.preventDefault();

        if (e.button === 0) {
            // Left click — start painting
            painting = true;
            pushUndo();
            post('paint', { sx: e.clientX, sy: e.clientY });
        } else if (e.button === 2) {
            // Right click — start orbiting camera
            orbiting = true;
        }
    });

    surface.addEventListener('mouseup', (e) => {
        if (e.button === 0 && painting) {
            painting = false;
            lastPaintU = -1;
            lastPaintV = -1;
            scheduleExport();
        } else if (e.button === 2) {
            orbiting = false;
        }
    });

    surface.addEventListener('wheel', (e) => {
        if (overToolbar) return;
        e.preventDefault();
        post('zoom', { delta: e.deltaY > 0 ? 1 : -1 });
    }, { passive: false });

    surface.addEventListener('contextmenu', (e) => e.preventDefault());

    function post(action, data) {
        fetch('https://hk-livery/' + action, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data || {}),
        });
    }

    // ──────────────────────────────────
    //  Paint on hidden canvas (UV coords from Lua)
    // ──────────────────────────────────

    /** Paint a dot/line on the texture at UV coordinates (0-1 range) */
    function paintAtUV(u, v) {
        const px = u * TEX_SIZE;
        const py = v * TEX_SIZE;
        const r  = brushSize * 0.5;

        ctx.globalCompositeOperation = tool === 'eraser' ? 'destination-out' : 'source-over';
        ctx.globalAlpha = 1.0;

        if (lastPaintU >= 0 && lastPaintV >= 0) {
            // Draw line from last point to current (for smooth strokes)
            const lx = lastPaintU * TEX_SIZE;
            const ly = lastPaintV * TEX_SIZE;
            ctx.strokeStyle = tool === 'eraser' ? '#000' : color;
            ctx.lineWidth = brushSize;
            ctx.beginPath();
            ctx.moveTo(lx, ly);
            ctx.lineTo(px, py);
            ctx.stroke();
        } else {
            // Single dot
            ctx.fillStyle = tool === 'eraser' ? '#000' : color;
            ctx.beginPath();
            ctx.arc(px, py, r, 0, Math.PI * 2);
            ctx.fill();
        }

        lastPaintU = u;
        lastPaintV = v;
    }

    // ──────────────────────────────────
    //  Texture export → Lua for DUI update
    // ──────────────────────────────────

    let exportTimer = null;

    function scheduleExport() {
        if (exportTimer) return;
        exportTimer = setTimeout(() => {
            exportTimer = null;
            const png = canvas.toDataURL('image/png');
            post('updateTexture', { png: png });
        }, 150);
    }

    function exportNow() {
        clearTimeout(exportTimer);
        exportTimer = null;
        const png = canvas.toDataURL('image/png');
        return png;
    }

    // ──────────────────────────────────
    //  Actions: undo/redo/clear/save/close
    // ──────────────────────────────────

    btnUndo.addEventListener('click', undo);
    btnRedo.addEventListener('click', redo);

    btnClear.addEventListener('click', () => {
        if (!confirm('Clear the entire canvas?')) return;
        pushUndo();
        ctx.clearRect(0, 0, TEX_SIZE, TEX_SIZE);
        scheduleExport();
    });

    btnSave.addEventListener('click', () => {
        const png = exportNow();
        post('save', { png: png });
        showToast('Livery saved');
    });

    btnClose.addEventListener('click', () => post('close', {}));

    // ── Keyboard shortcuts ──
    document.addEventListener('keydown', (e) => {
        if (!isOpen) return;
        if (e.target.tagName === 'INPUT') return;

        if (e.key === 'Escape') { post('close', {}); return; }
        if (e.ctrlKey && e.key === 'z') { e.preventDefault(); undo(); return; }
        if (e.ctrlKey && (e.key === 'y' || e.key === 'Z')) { e.preventDefault(); redo(); return; }

        switch (e.key) {
            case 'b': document.querySelector('[data-tool="pen"]')?.click(); break;
            case 'e': document.querySelector('[data-tool="eraser"]')?.click(); break;
            case '[': sizeSlider.value = Math.max(1, brushSize - 3); sizeSlider.dispatchEvent(new Event('input')); break;
            case ']': sizeSlider.value = Math.min(80, brushSize + 3); sizeSlider.dispatchEvent(new Event('input')); break;
        }
    });

    // ── Toast ──
    let toastTimer = null;
    function showToast(msg) {
        toast.textContent = msg;
        toast.classList.remove('hidden');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => toast.classList.add('hidden'), 2000);
    }

    // ──────────────────────────────────
    //  NUI message handler
    // ──────────────────────────────────

    window.addEventListener('message', (e) => {
        const d = e.data;

        // Open editor
        if (d.action === 'open') {
            isOpen = true;
            editor.classList.remove('hidden');
            if (d.png) {
                loadPng(d.png);
            } else {
                ctx.clearRect(0, 0, TEX_SIZE, TEX_SIZE);
                undoStack = [];
                redoStack = [];
                updateUndoButtons();
            }
        }

        // Close editor
        if (d.action === 'close') {
            isOpen = false;
            editor.classList.add('hidden');
            painting = false;
            orbiting = false;
        }

        // Lua tells us to paint at UV coordinates (from raycast hit)
        if (d.action === 'paintUV') {
            paintAtUV(d.u, d.v);
        }

        // Lua says raycast missed — break stroke continuity
        if (d.action === 'paintMiss') {
            lastPaintU = -1;
            lastPaintV = -1;
        }
    });

    // ── Load PNG into canvas ──
    function loadPng(dataUrl) {
        const img = new Image();
        img.onload = () => {
            ctx.clearRect(0, 0, TEX_SIZE, TEX_SIZE);
            ctx.drawImage(img, 0, 0, TEX_SIZE, TEX_SIZE);
            undoStack = [];
            redoStack = [];
            updateUndoButtons();
        };
        img.src = dataUrl;
    }

    // ── Prevent defaults ──
    document.addEventListener('dragstart', e => e.preventDefault());
    document.addEventListener('selectstart', e => {
        if (e.target.tagName !== 'INPUT') e.preventDefault();
    });

})();
