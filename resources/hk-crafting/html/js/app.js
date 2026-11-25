// js/app.js - NUI controller for hk-crafting
(function () {
    'use strict';

    const RES = 'hk-crafting';
    const $ = (sel) => document.querySelector(sel);

    const panel     = $('#panel');
    const listEl    = $('#item-list');
    const detailEl  = $('#detail');
    const titleEl   = $('#ch-title');
    const subEl     = $('#ch-sub');

    const catTabs   = $('#cat-tabs');

    let craftables = [];
    let selected   = null;      // item name
    let activeCat  = null;      // active category filter, or null = all
    let repairCfg  = null;      // { enabled, minGrade, grade, costPer }
    let repairMode = false;     // true = Repair tab active
    let repairSel  = null;      // selected weapon slot in repair view
    let L = { required: 'Required Materials', craft: 'Craft', have: 'have',
              selectHint: 'Select an item to craft', makes: 'makes %s', blueprint: 'Blueprint' };

    // ===== NUI message handler =====
    window.addEventListener('message', (e) => {
        const d = e.data;
        switch (d.action) {
            case 'open':     open(d); break;
            case 'refresh':  refresh(d.craftables); break;
            case 'reenable': reenableCraft(); break;
            case 'close':    close(); break;
        }
    });

    // Re-render the current craftable's detail (re-enables the craft button after
    // a cancelled craft, which otherwise leaves it stuck disabled).
    function reenableCraft() {
        if (repairMode || !selected) return;
        const entry = craftables.find(c => c.item === selected);
        if (entry) showDetail(entry);
    }

    function setAccent(color) {
        if (!color) return;
        const hex = '#' + [color.r, color.g, color.b]
            .map(x => Math.max(0, Math.min(255, x | 0)).toString(16).padStart(2, '0')).join('');
        document.documentElement.style.setProperty('--accent-color', hex);
    }

    function open(d) {
        setAccent(d.accent);
        if (d.locales) L = Object.assign(L, d.locales);
        titleEl.textContent = d.title || 'Crafting';
        subEl.textContent = d.tableLabel || '';
        craftables = d.craftables || [];
        repairCfg = d.repair || null;
        selected = null;
        activeCat = null;
        repairMode = false;
        panel.classList.remove('hidden');
        buildCatTabs();
        buildList();
        showEmptyDetail();
    }

    function refresh(list) {
        if (list) craftables = list;
        buildCatTabs();
        buildList();
        if (selected) {
            const entry = craftables.find(c => c.item === selected);
            if (entry) showDetail(entry);
        }
    }

    // ===== category tabs =====
    function categories() {
        // preserve first-seen order
        const seen = [];
        craftables.forEach(c => { const k = c.category || 'General'; if (!seen.includes(k)) seen.push(k); });
        return seen;
    }

    function buildCatTabs() {
        const cats = categories();
        const hasRepair = repairCfg && repairCfg.enabled;
        // no category tabs AND no repair tab → hide the bar entirely
        if (cats.length <= 1 && !hasRepair) {
            catTabs.classList.add('hidden');
            activeCat = null;
            return;
        }
        catTabs.classList.remove('hidden');
        if (!repairMode && (!activeCat || !cats.includes(activeCat))) activeCat = cats[0];
        catTabs.innerHTML = '';

        cats.forEach(cat => {
            const btn = document.createElement('button');
            btn.className = 'cat-tab' + (!repairMode && cat === activeCat ? ' active' : '');
            btn.textContent = cat;
            btn.addEventListener('click', () => {
                repairMode = false;
                activeCat = cat;
                selected = null;
                post('clearPreview');   // remove any floating item prop
                buildCatTabs();
                buildList();
                showEmptyDetail();
            });
            catTabs.appendChild(btn);
        });

        // Repair tab (greyed out below minGrade — still visible, per spec)
        if (hasRepair) {
            const locked = (repairCfg.grade || 0) < (repairCfg.minGrade || 0);
            const btn = document.createElement('button');
            btn.className = 'cat-tab' + (repairMode ? ' active' : '') + (locked ? ' locked' : '');
            btn.textContent = L.repairTab || 'Repair';
            if (locked) btn.title = L.repairLocked || 'Locked';
            btn.addEventListener('click', () => {
                if (locked) return;         // greyed out: does nothing
                repairMode = true;
                selected = null;
                post('clearPreview');   // remove any floating item prop
                buildCatTabs();
                openRepairView();
            });
            catTabs.appendChild(btn);
        }
    }

    function visibleCraftables() {
        if (!activeCat) return craftables;
        return craftables.filter(c => (c.category || 'General') === activeCat);
    }

    function close() {
        panel.classList.add('hidden');
        listEl.innerHTML = '';
        detailEl.innerHTML = '';
        selected = null;
    }

    // ===== helpers =====
    function canCraft(entry) {
        if (entry.hasBlueprint && !entry.hasBlueprintItem) return false;
        return entry.materials.every(m => m.have >= m.need);
    }

    // <img> with graceful fallback to a lettered box if the icon 404s.
    function iconEl(src, fallbackClass, letter) {
        const img = document.createElement('img');
        img.src = src;
        img.onerror = () => {
            const box = document.createElement('div');
            box.className = fallbackClass;
            box.textContent = letter || '?';
            img.replaceWith(box);
        };
        return img;
    }

    // ===== left list =====
    function buildList() {
        listEl.innerHTML = '';
        visibleCraftables().forEach(entry => {
            const row = document.createElement('div');
            row.className = 'item-row' + (entry.item === selected ? ' active' : '');

            row.appendChild(iconEl(entry.icon, 'ir-fallback', (entry.label || '?')[0]));

            const info = document.createElement('div');
            const name = document.createElement('div');
            name.className = 'ir-name';
            name.textContent = entry.label;
            const amt = document.createElement('div');
            amt.className = 'ir-amt';
            amt.textContent = entry.amount > 1 ? (L.makes || 'makes %s').replace('%s', entry.amount) : '';
            info.appendChild(name);
            info.appendChild(amt);
            row.appendChild(info);

            const dot = document.createElement('div');
            dot.className = 'ir-craftable' + (canCraft(entry) ? '' : ' no');
            row.appendChild(dot);

            row.addEventListener('click', () => selectItem(entry));
            listEl.appendChild(row);
        });
    }

    function selectItem(entry) {
        selected = entry.item;
        buildList();
        showDetail(entry);
        post('preview', { item: entry.item, model: true });
    }

    // ===== right detail =====
    function showEmptyDetail() {
        detailEl.className = 'detail detail-empty';
        detailEl.innerHTML = `<p class="detail-hint">${L.selectHint || 'Select an item to craft'}</p>`;
    }

    function showDetail(entry) {
        detailEl.className = 'detail';
        detailEl.innerHTML = '';

        // inline header: small icon beside the title (keeps the craft button in view)
        const head = document.createElement('div');
        head.className = 'detail-head';
        head.appendChild(iconEl(entry.icon, 'detail-icon', (entry.label || '?')[0]));
        const h = document.createElement('h3');
        h.textContent = entry.amount > 1 ? `${entry.label} ×${entry.amount}` : entry.label;
        head.appendChild(h);
        detailEl.appendChild(head);

        const desc = document.createElement('p');
        desc.className = 'd-desc';
        desc.textContent = entry.description || '';
        detailEl.appendChild(desc);

        if (entry.hasBlueprint) {
            const bp = document.createElement('div');
            const has = !!entry.hasBlueprintItem;
            bp.className = 'bp-badge ' + (has ? 'have' : 'missing');
            bp.textContent = (has ? '✓ ' : '✗ ') + (entry.blueprintLabel || L.blueprint || 'Blueprint');
            detailEl.appendChild(bp);
        }

        const lbl = document.createElement('div');
        lbl.className = 'section-label';
        lbl.textContent = L.required;
        detailEl.appendChild(lbl);

        entry.materials.forEach(m => {
            const row = document.createElement('div');
            row.className = 'mat-row';
            row.appendChild(iconEl(m.icon, 'm-fallback', (m.label || '?')[0]));

            const name = document.createElement('div');
            name.className = 'm-name';
            name.textContent = m.label;
            row.appendChild(name);

            const cnt = document.createElement('div');
            cnt.className = 'm-count ' + (m.have >= m.need ? 'ok' : 'bad');
            cnt.textContent = `${m.have} / ${m.need}`;
            row.appendChild(cnt);

            detailEl.appendChild(row);
        });

        const btn = document.createElement('button');
        btn.className = 'btn-craft';
        btn.textContent = L.craft;
        btn.disabled = !canCraft(entry);
        btn.addEventListener('click', () => {
            btn.disabled = true;
            post('craft', { item: entry.item });
        });
        detailEl.appendChild(btn);
    }

    // ===== events =====
    $('#btn-close').addEventListener('click', () => post('close', {}));

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !panel.classList.contains('hidden')) post('close', {});
    });

    function post(name, body) {
        return fetch(`https://${RES}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body || {}),
        }).then(r => r.json()).catch(() => null);
    }

    // ===== Repair view =====
    let repairStock = {};   // { itemName: ownedCount }

    async function openRepairView() {
        listEl.innerHTML = '';
        detailEl.className = 'detail detail-empty';
        detailEl.innerHTML = `<p class="detail-hint">...</p>`;
        repairSel = null;

        const res = (await post('getWeapons')) || {};
        const weapons = res.weapons || [];
        repairStock = res.stock || {};
        listEl.innerHTML = '';
        if (!weapons.length) {
            detailEl.innerHTML = `<p class="detail-hint">${L.repairNoWeapons || 'No weapons'}</p>`;
            return;
        }
        weapons.forEach(w => {
            const row = document.createElement('div');
            row.className = 'item-row';
            row.appendChild(iconEl(w.icon, 'ir-fallback', (w.label || '?')[0]));
            const info = document.createElement('div');
            info.style.flex = '1';
            const name = document.createElement('div');
            name.className = 'ir-name';
            name.textContent = w.label;
            const bar = document.createElement('div');
            bar.className = 'q-bar';
            const fill = document.createElement('div');
            fill.className = 'q-fill' + (w.quality < 35 ? ' low' : w.quality < 70 ? ' mid' : '');
            fill.style.width = w.quality + '%';
            bar.appendChild(fill);
            info.appendChild(name);
            info.appendChild(bar);
            row.appendChild(info);
            const pct = document.createElement('div');
            pct.className = 'ir-amt';
            pct.textContent = w.quality + '%';
            row.appendChild(pct);
            row.addEventListener('click', () => {
                document.querySelectorAll('#item-list .item-row').forEach(r => r.classList.remove('active'));
                row.classList.add('active');
                showRepairDetail(w);
            });
            listEl.appendChild(row);
        });
    }

    function computeCost(points) {
        const cost = [];
        (repairCfg.costPer || []).forEach(c => {
            const amt = Math.ceil(points * c.per);
            if (amt > 0) cost.push({ item: c.item, label: c.label, amount: amt, have: repairStock[c.item] || 0 });
        });
        return cost;
    }

    function showRepairDetail(w) {
        repairSel = w;
        detailEl.className = 'detail';
        detailEl.innerHTML = '';

        const head = document.createElement('div');
        head.className = 'detail-head';
        head.appendChild(iconEl(w.icon, 'detail-icon', (w.label || '?')[0]));
        const h = document.createElement('h3');
        h.textContent = w.label;
        head.appendChild(h);
        detailEl.appendChild(head);

        const cur = document.createElement('p');
        cur.className = 'd-desc';
        cur.textContent = `${w.serie ? '#' + w.serie + ' · ' : ''}${w.quality}%`;
        detailEl.appendChild(cur);

        // target quality slider (gundealer picks how much to restore)
        const lbl = document.createElement('div');
        lbl.className = 'section-label';
        lbl.textContent = L.repairTarget || 'Target Quality';
        detailEl.appendChild(lbl);

        const slider = document.createElement('input');
        slider.type = 'range';
        slider.min = Math.min(w.quality + 1, 100);
        slider.max = 100;
        slider.value = 100;
        slider.className = 'q-slider';
        detailEl.appendChild(slider);

        const readout = document.createElement('div');
        readout.className = 'q-readout';
        detailEl.appendChild(readout);

        const matsLbl = document.createElement('div');
        matsLbl.className = 'section-label';
        matsLbl.textContent = L.required || 'Required Materials';
        detailEl.appendChild(matsLbl);
        const matsBox = document.createElement('div');
        detailEl.appendChild(matsBox);

        const btn = document.createElement('button');
        btn.className = 'btn-craft';
        btn.textContent = L.repairBtn || 'Repair';
        detailEl.appendChild(btn);

        function render() {
            const target = parseInt(slider.value);
            const points = target - w.quality;
            readout.textContent = `${w.quality}% → ${target}%  (+${points})`;
            matsBox.innerHTML = '';
            let canAfford = points > 0;
            computeCost(points).forEach(c => {
                const enough = c.have >= c.amount;
                if (!enough) canAfford = false;
                const row = document.createElement('div');
                row.className = 'mat-row';
                const n = document.createElement('div');
                n.className = 'm-name'; n.textContent = c.label;
                const a = document.createElement('div');
                a.className = 'm-count ' + (enough ? 'ok' : 'bad');
                a.textContent = `${c.have} / ${c.amount}`;   // have / need, like the craft tab
                row.appendChild(n); row.appendChild(a);
                matsBox.appendChild(row);
            });
            // gate the button: no points, or missing materials
            btn.disabled = !canAfford;
        }
        slider.addEventListener('input', render);
        render();

        btn.addEventListener('click', async () => {
            if (btn.disabled) return;
            btn.disabled = true;
            const res = await post('repair', { slot: w.slot, target: parseInt(slider.value) });
            if (res && res.ok) openRepairView();   // refresh list + stock with new quality
            else btn.disabled = false;
        });
    }
})();
