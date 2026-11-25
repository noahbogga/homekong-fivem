// hk-documents :: NUI controller
(function () {
    'use strict';
    const RES = 'hk-documents';
    const $ = (s) => document.querySelector(s);

    const panel   = $('#panel');
    const listCol = $('#list-col');
    const workCol = $('#work-col');
    const overlay = $('#view-overlay');
    const stage   = $('#view-stage');

    let branding = {};      // job branding + docTypes + identity
    let L = {};             // locales
    let imgCfg = {};        // Config.Images
    let activeTab = 'mine';
    let selected = null;    // currently selected list item id

    // ===== message bridge =====
    window.addEventListener('message', (e) => {
        const d = e.data;
        if (d.action === 'open') return open(d);
        if (d.action === 'close') return close();
        if (d.action === 'refresh') return loadTab(activeTab);
        if (d.action === 'viewFromPlayer') {
            // Seed locales so a receiver who never opened their own panel this
            // session still renders localized labels instead of raw keys.
            if (d.locales) L = d.locales;
            return showFullscreen(d.document);
        }
    });

    function post(name, body) {
        return fetch(`https://${RES}/${name}`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body || {}),
        }).then(r => r.json()).catch(() => null);
    }

    // Parse #rgb or #rrggbb into [r,g,b], or null.
    function parseHex(hex) {
        let s = String(hex || '').trim().replace(/^#/, '');
        if (/^[0-9a-fA-F]{3}$/.test(s)) s = s.split('').map(c => c + c).join('');
        if (!/^[0-9a-fA-F]{6}$/.test(s)) return null;
        return [parseInt(s.slice(0,2),16), parseInt(s.slice(2,4),16), parseInt(s.slice(4,6),16)];
    }
    // Perceived luminance 0..1 (sRGB weights).
    function lum([r,g,b]) { return (0.2126*r + 0.7152*g + 0.0722*b) / 255; }

    function setAccent(hex) {
        const root = document.documentElement.style;
        if (!hex) return;
        // Drive the heavy-tokenized shell off the job's branding accent so each
        // job's panel keeps its locked brand colour. But job accents can be very
        // dark (nia #2b2b2b, fbi #1f2d5a); on the dark shell that would make
        // accent-as-TEXT invisible and dark ink unreadable on the fill. So we
        // derive two adaptive tokens:
        //   --accent-ink  = readable text drawn ON the accent fill (buttons)
        //   --accent-fg   = a brightened accent used for accent-coloured TEXT on
        //                   the dark shell (tabs, badges, ids); tints derive from it.
        root.setProperty('--accent-color', hex);
        const rgb = parseHex(hex);
        if (!rgb) return;   // leave defaults if unparseable
        root.setProperty('--accent', hex);
        root.setProperty('--accent-2', hex);

        // Ink on the fill: light text on a dark accent, dark ink on a light one.
        root.setProperty('--accent-ink', lum(rgb) < 0.55 ? '#e9eef3' : '#04121c');

        // Foreground accent: lighten toward white until it reads on the dark card.
        let [r,g,b] = rgb;
        while (lum([r,g,b]) < 0.5) {
            r = Math.round(r + (255 - r) * 0.4);
            g = Math.round(g + (255 - g) * 0.4);
            b = Math.round(b + (255 - b) * 0.4);
            if (r > 250 && g > 250 && b > 250) break;
        }
        root.setProperty('--accent-fg', `rgb(${r},${g},${b})`);
        // Tints/borders derive from the readable foreground so they stay visible.
        root.setProperty('--accent-soft', `rgba(${r},${g},${b},0.15)`);
        root.setProperty('--accent-line', `rgba(${r},${g},${b},0.42)`);
    }
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => (
            { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
    }
    // Localized string lookup with %s substitution. Falls back to the key itself
    // if the active locale (sent from the client) has no entry for it.
    function t(key, ...args) {
        let s = (L && L[key] != null) ? L[key] : key;
        let i = 0;
        return String(s).replace(/%s/g, () => (i < args.length ? args[i++] : ''));
    }

    // Localize the static markup (tab labels + close tooltip) once locales are available.
    function applyStaticLabels() {
        const map = { mine: 'tab_mine', issue: 'tab_issue', templates: 'tab_templates' };
        document.querySelectorAll('.tab').forEach(el => {
            const k = map[el.dataset.tab];
            if (k) el.textContent = t(k);
        });
        const close = $('#btn-close');
        if (close) close.title = t('tt_close');
    }

    // ===== open / close =====
    function open(d) {
        branding = d.branding || {};
        L = d.locales || {};
        imgCfg = d.images || {};
        setAccent(branding.accent);
        applyStaticLabels();
        $('#dh-title').textContent = t('ui_title');
        $('#dh-sub').textContent = branding.label || t('ui_citizen');
        // Templates tab only for managers
        $('#tab-templates').style.display = branding.canManage ? '' : 'none';
        if (!branding.canManage && activeTab === 'templates') activeTab = 'mine';
        panel.classList.remove('hidden');
        setTab(activeTab);
    }
    // Active transient mini-modal (portal upload / nearby picker) + its poll
    // timer, tracked at module scope so panel close / tab switch / editor change
    // can always tear them down (otherwise the portal poll runs forever and a
    // late completion bleeds into an unrelated editor).
    let activeModal = null;      // the .mini-modal element currently shown
    let activePoll = null;       // setTimeout handle for the portal claim poll
    function dismissMiniModal() {
        if (activePoll) { clearTimeout(activePoll); activePoll = null; }
        if (activeModal) { activeModal.remove(); activeModal = null; }
    }

    function close() {
        dismissMiniModal();
        panel.classList.add('hidden');
        overlay.classList.add('hidden');
        selected = null;
    }

    $('#btn-close').addEventListener('click', () => post('close'));
    document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        // A transient modal takes precedence over overlay/panel on Esc.
        if (activeModal) { dismissMiniModal(); return; }
        if (!overlay.classList.contains('hidden')) { post('closeView'); overlay.classList.add('hidden'); return; }
        if (!panel.classList.contains('hidden')) post('close');
    });

    // ===== tabs =====
    document.querySelectorAll('.tab').forEach(t => {
        t.addEventListener('click', () => setTab(t.dataset.tab));
    });
    function setTab(tab) {
        dismissMiniModal();   // never leave a portal poll running across a tab switch
        activeTab = tab;
        document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
        selected = null;
        workCol.innerHTML = `<p class="empty-hint">${esc(t('ui_select_left'))}</p>`;
        loadTab(tab);
    }

    // expose internals used by later chunks
    window.__hkdoc = { post, esc, setAccent, get branding(){return branding;}, get L(){return L;},
        get imgCfg(){return imgCfg;}, get activeTab(){return activeTab;},
        listCol, workCol, overlay, stage,
        setSelected: (v)=>selected=v, getSelected: ()=>selected };
    // ===== tab loaders =====
    let cacheDocs = [], cacheTemplates = [];

    async function loadTab(tab) {
        if (tab === 'mine') {
            cacheDocs = (await post('getMyDocuments')) || [];
            renderDocList(cacheDocs.filter(d => true), 'mine');
        } else if (tab === 'issue') {
            cacheTemplates = (await post('getTemplates')) || [];
            renderTemplatePicker(cacheTemplates);
        } else if (tab === 'templates') {
            cacheTemplates = (await post('getTemplates')) || [];
            renderTemplateManager(cacheTemplates);
        }
    }

    function logoFor(doc) {
        return doc.logo || branding.logo || 'assets/hk_logo.png';
    }

    // Localized document-type label. Prefers a locale key (dt_<type>), then the
    // English label from Config.DocTypes, then the raw type string.
    function docTypeLabel(type) {
        type = type || 'a4';
        const key = 'dt_' + type;
        if (L && L[key] != null) return L[key];
        const dt = (branding.docTypes || {})[type];
        return (dt && dt.label) || type;
    }

    // My Documents — list of held docs
    function renderDocList(docs) {
        listCol.innerHTML = '';
        const head = document.createElement('div');
        head.className = 'list-head';
        head.innerHTML = `<h3>${esc(t('head_mine'))}</h3>`;
        listCol.appendChild(head);

        if (!docs.length) {
            listCol.insertAdjacentHTML('beforeend', `<p class="empty-hint" style="margin:20px auto;">${esc(t('empty_mine'))}</p>`);
            return;
        }
        docs.forEach(doc => {
            const row = document.createElement('div');
            row.className = 'list-row';
            row.innerHTML = `
                <img class="lr-logo" src="${esc(logoFor(doc))}" onerror="this.style.visibility='hidden'">
                <div>
                    <div class="lr-title">${esc(doc.title || doc.jobLabel || t('generic_document'))}</div>
                    <div class="lr-meta">${esc(docTypeLabel(doc.docType))} • ${esc(doc.createdAt || '')}</div>
                </div>
                ${doc.isCopy ? `<span class="lr-badge">${esc(t('label_copy'))}</span>` : ''}`;
            row.addEventListener('click', () => {
                document.querySelectorAll('.list-row').forEach(r => r.classList.remove('active'));
                row.classList.add('active');
                showDocDetail(doc);
            });
            listCol.appendChild(row);
        });
    }

    // Issue tab — pick a template to fill in
    function renderTemplatePicker(templates) {
        listCol.innerHTML = `<div class="list-head"><h3>${esc(t('head_issue'))}</h3></div>`;
        if (!templates.length) {
            listCol.insertAdjacentHTML('beforeend', `<p class="empty-hint" style="margin:20px auto;">${esc(t('empty_issue'))}</p>`);
            return;
        }
        templates.forEach(tpl => {
            const row = document.createElement('div');
            row.className = 'list-row';
            row.innerHTML = `
                <img class="lr-logo" src="${esc(branding.logo || 'assets/hk_logo.png')}" onerror="this.style.visibility='hidden'">
                <div>
                    <div class="lr-title">${esc(tpl.documentName || t('untitled'))}</div>
                    <div class="lr-meta">${esc(docTypeLabel(tpl.docType))}${tpl.minGrade!=null?(' • '+esc(t('grade_prefix', tpl.minGrade))):''}</div>
                </div>`;
            row.addEventListener('click', () => {
                document.querySelectorAll('.list-row').forEach(r => r.classList.remove('active'));
                row.classList.add('active');
                openDocEditor(tpl);
            });
            listCol.appendChild(row);
        });
    }

    // Templates tab — manage (create/edit/delete) job templates
    function renderTemplateManager(templates) {
        listCol.innerHTML = '';
        const head = document.createElement('div');
        head.className = 'list-head';
        head.innerHTML = `<h3>${esc(t('head_templates'))}</h3><button class="btn-add" id="new-tmpl">${esc(t('btn_new'))}</button>`;
        listCol.appendChild(head);
        head.querySelector('#new-tmpl').addEventListener('click', () => openTemplateEditor(null));

        templates.forEach(tpl => {
            const row = document.createElement('div');
            row.className = 'list-row';
            row.innerHTML = `
                <div>
                    <div class="lr-title">${esc(tpl.documentName || t('untitled'))}</div>
                    <div class="lr-meta">${esc(docTypeLabel(tpl.docType))} • ${esc(t('fields_count', (tpl.fields||[]).length))}</div>
                </div>`;
            row.addEventListener('click', () => {
                document.querySelectorAll('.list-row').forEach(r => r.classList.remove('active'));
                row.classList.add('active');
                openTemplateEditor(tpl);
            });
            listCol.appendChild(row);
        });
    }

    // expose to later chunks
    Object.assign(window.__hkdoc, {
        renderDocList, loadTab, logoFor,
        get cacheDocs(){return cacheDocs;}, get cacheTemplates(){return cacheTemplates;},
    });
    // ===== Template editor (manage tab) =====
    function openTemplateEditor(tmpl) {
        editorGen++;
        dismissMiniModal();
        const isNew = !tmpl;
        const dt = branding.docTypes || {};
        const typeOpts = Object.keys(dt).map(k =>
            `<option value="${k}" ${tmpl && tmpl.docType===k?'selected':''}>${esc(docTypeLabel(k))}</option>`).join('');
        const fields = (tmpl && tmpl.fields) || [];

        workCol.innerHTML = `
            <div class="editor">
                <h3>${isNew ? esc(t('tpl_new')) : esc(t('tpl_edit'))}</h3>
                <p class="ed-note">${t('tpl_locked_note', esc(branding.label||t('ui_citizen')))}</p>
                <div class="field-group"><label>${esc(t('lbl_doctype'))}</label><select id="t-type">${typeOpts}</select></div>
                <div class="field-group"><label>${esc(t('lbl_tpl_name'))}</label><input id="t-name" value="${esc(tmpl?tmpl.documentName:'')}" maxlength="120"></div>
                <div class="field-group"><label>${esc(t('lbl_description'))}</label><textarea id="t-desc" maxlength="500">${esc(tmpl?tmpl.description:'')}</textarea></div>
                <div class="field-group"><label>${esc(t('lbl_min_grade'))}</label><input id="t-grade" type="number" min="0" value="${tmpl&&tmpl.minGrade!=null?tmpl.minGrade:''}"></div>
                <div class="field-group"><label>${esc(t('lbl_fields'))}</label><div id="t-fields"></div>
                    <button class="btn-secondary" id="t-addfield">${esc(t('btn_add_field'))}</button></div>
                <div class="field-group"><label>${esc(t('lbl_info_name'))}</label><input id="t-infoname" value="${esc(tmpl?tmpl.infoName:'')}" maxlength="60"></div>
                <div class="field-group"><label>${esc(t('lbl_info_text'))}</label><textarea id="t-infotext" maxlength="2000">${esc(tmpl?tmpl.infoTemplate:'')}</textarea></div>
                <div class="editor-actions">
                    ${!isNew ? `<button class="btn-secondary" id="t-del">${esc(t('btn_delete'))}</button>` : ''}
                    <button class="btn-primary" id="t-save">${isNew?esc(t('btn_create_tpl')):esc(t('btn_save_changes'))}</button>
                </div>
            </div>`;

        const fWrap = $('#t-fields');
        function addFieldRow(name) {
            const row = document.createElement('div');
            row.className = 'dyn-field';
            row.innerHTML = `<input placeholder="${esc(t('ph_field_name'))}" value="${esc(name||'')}" maxlength="60">
                             <button class="btn-del">✕</button>`;
            row.querySelector('.btn-del').addEventListener('click', () => row.remove());
            fWrap.appendChild(row);
        }
        fields.forEach(f => addFieldRow(typeof f === 'string' ? f : f.name));
        $('#t-addfield').addEventListener('click', () => addFieldRow(''));

        $('#t-save').addEventListener('click', async () => {
            const payload = {
                id: tmpl ? tmpl.id : undefined,
                docType: $('#t-type').value,
                documentName: $('#t-name').value.trim(),   // blank stays blank; renderers localize via t('untitled')
                description: $('#t-desc').value,
                minGrade: $('#t-grade').value === '' ? null : parseInt($('#t-grade').value),
                infoName: $('#t-infoname').value,
                infoTemplate: $('#t-infotext').value,
                fields: [...fWrap.querySelectorAll('input')].map(i => i.value.trim()).filter(Boolean),
            };
            const res = await post('saveTemplate', payload);
            if (res) loadTab('templates');
        });
        if (!isNew) $('#t-del').addEventListener('click', async () => {
            await post('deleteTemplate', { id: tmpl.id });
            loadTab('templates');
        });
    }

    // ===== Document editor (issue tab) =====
    let editorImages = [], signed = false;
    // Bumped every time an editor (re)opens; a portal upload started under one
    // generation must not write its result into a later editor's state.
    let editorGen = 0;
    function openDocEditor(tmpl) {
        editorGen++;
        dismissMiniModal();
        editorImages = []; signed = false;
        const docType = tmpl.docType || 'a4';
        const dt = (branding.docTypes || {})[docType] || {};
        const tFields = (tmpl.fields || []).map(f => typeof f === 'string' ? f : f.name);

        const fieldInputs = tFields.map((name, i) =>
            `<div class="field-group"><label>${esc(name)}</label><input class="df-input" data-name="${esc(name)}" maxlength="300"></div>`).join('');

        const signName = `${(branding.identity||{}).firstname||''} ${(branding.identity||{}).lastname||''}`.trim();
        workCol.innerHTML = `
            <div class="editor">
                <h3>${esc(tmpl.documentName || t('doc_new'))}</h3>
                <p class="ed-note">${t('doc_issued_as', esc(branding.label||''))} <span class="locked-badge">● ${esc(t('branding_locked'))}</span></p>
                ${tmpl.description ? `<div class="field-group"><label>${esc(t('lbl_description'))}</label><textarea id="d-desc" maxlength="500">${esc(tmpl.description)}</textarea></div>` : ''}
                ${fieldInputs}
                ${dt.hasExpiry ? `<div class="field-group"><label>${esc(t('lbl_expiry'))}</label><input id="d-expiry" maxlength="40" placeholder="${esc(t('ph_expiry'))}"></div>` : ''}
                ${dt.hasBody ? `<div class="field-group"><label>${esc(t('lbl_body'))}</label><textarea id="d-body" maxlength="5000" style="min-height:140px;"></textarea></div>` : ''}
                ${tmpl.infoName ? `<div class="field-group"><label>${esc(tmpl.infoName)}</label><textarea id="d-info" maxlength="2000">${esc(tmpl.infoTemplate||'')}</textarea></div>` : ''}
                ${(dt.hasAttachments || dt.hasPhoto) ? imageAttachHtml(dt.hasPhoto) : ''}
                <div class="sign-gate">
                    <label style="font-size:11px;text-transform:uppercase;letter-spacing:0.08em;color:var(--fg-muted);font-weight:600;">${esc(t('lbl_signature'))}</label>
                    <div class="sign-pad" id="sign-pad"><span class="sp-hint">${esc(t('sign_click', signName))}</span></div>
                </div>
                <div class="editor-actions">
                    <button class="btn-primary" id="d-create" disabled>${esc(t('btn_create_doc'))}</button>
                </div>
            </div>`;

        wireImageAttach(dt.hasPhoto);

        const pad = $('#sign-pad');
        pad.addEventListener('click', () => {
            signed = true;
            pad.classList.add('signed');
            const id = branding.identity || {};
            pad.innerHTML = `<span>${esc(id.firstname||'')} ${esc(id.lastname||'')}</span>`;
            $('#d-create').disabled = false;
        });

        $('#d-create').addEventListener('click', async () => {
            if (!signed) return;
            const fields = [...workCol.querySelectorAll('.df-input')].map(i => ({ name: i.dataset.name, value: i.value }));
            const payload = {
                templateId: tmpl.id,
                docType,
                title: tmpl.documentName,
                description: $('#d-desc') ? $('#d-desc').value : (tmpl.description||''),
                fields,
                infoName: tmpl.infoName || '',
                infoValue: $('#d-info') ? $('#d-info').value : '',
                expiry: $('#d-expiry') ? $('#d-expiry').value : undefined,
                body: $('#d-body') ? $('#d-body').value : undefined,
                images: dt.hasPhoto ? [] : editorImages.slice(),
                photo: dt.hasPhoto ? (editorImages[0] || undefined) : undefined,
            };
            const res = await post('createDocument', payload);
            if (res) { setTab('mine'); }
        });
    }

    // shared image-attach UI + wiring (used by doc editor)
    function imageAttachHtml(single) {
        return `
        <div class="img-attach">
            <label style="font-size:11px;text-transform:uppercase;letter-spacing:0.08em;color:var(--fg-muted);font-weight:600;display:block;margin-bottom:8px;">
                ${single ? esc(t('lbl_photo')) : esc(t('lbl_attachments'))}</label>
            <div class="ia-row">
                <input id="ia-url" placeholder="${esc(t('ph_image_url'))}" style="flex:1;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:9px 11px;color:var(--fg);font-family:var(--font);">
                <button class="btn-secondary" id="ia-addurl">${esc(t('btn_add'))}</button>
            </div>
            ${imgCfg.portalEnabled ? `<div class="ia-row"><button class="btn-secondary" id="ia-portal" style="flex:1;">${esc(t('btn_portal_upload'))}</button></div>` : ''}
            <div class="img-thumbs" id="ia-thumbs"></div>
        </div>`;
    }

    function wireImageAttach(single) {
        const thumbs = $('#ia-thumbs');
        if (!thumbs) return;
        function redraw() {
            thumbs.innerHTML = editorImages.map((u,i) =>
                `<img src="${esc(u)}" title="${esc(t('tt_remove_image'))}" data-i="${i}">`).join('');
            thumbs.querySelectorAll('img').forEach(im => im.addEventListener('click', () => {
                editorImages.splice(parseInt(im.dataset.i),1); redraw();
            }));
        }
        async function addUrl(u) {
            u = (u||'').trim();
            if (!u) return;
            const chk = await post('validateImageUrl', { url: u });
            if (!chk || !chk.ok) { alert(t('img_not_allowed')); return; }
            if (single) editorImages = [u]; else editorImages.push(u);
            redraw();
        }
        $('#ia-addurl').addEventListener('click', () => { addUrl($('#ia-url').value); $('#ia-url').value=''; });
        const portalBtn = $('#ia-portal');
        if (portalBtn) portalBtn.addEventListener('click', () => startPortalFlow(addUrl));
    }

    // portal code flow: get code, show it, poll claim.
    // The modal + poll are registered in the module-level activeModal/activePoll
    // so close()/setTab()/editor changes can tear them down. The completion is
    // pinned to the editor generation it started in, so a late claim can't inject
    // an image into a different editor the player has since opened.
    async function startPortalFlow(onUrl) {
        dismissMiniModal();   // only ever one transient modal at a time
        const code = await post('newUploadCode');
        if (!code) { alert(t('portal_unavailable')); return; }
        const myGen = editorGen;
        const modal = document.createElement('div');
        modal.className = 'mini-modal';
        modal.innerHTML = `
            <div class="mini-card">
                <h3>${esc(t('portal_title'))}</h3>
                <p>${esc(t('portal_instructions'))}</p>
                <div class="code-big">${esc(code)}</div>
                <p style="font-size:12px;">${esc(t('portal_waiting'))}</p>
                <button class="btn-secondary" id="portal-cancel">${esc(t('btn_cancel'))}</button>
            </div>`;
        document.body.appendChild(modal);
        activeModal = modal;
        modal.querySelector('#portal-cancel').addEventListener('click', dismissMiniModal);
        const poll = async () => {
            if (activeModal !== modal) return;   // torn down elsewhere
            const res = await post('claimUploadCode', { code });
            if (activeModal !== modal) return;   // torn down while awaiting
            if (res && res.ok && res.url) {
                dismissMiniModal();
                if (myGen === editorGen) onUrl(res.url);   // same editor still open
                return;
            }
            activePoll = setTimeout(poll, 2500);
        };
        activePoll = setTimeout(poll, 2500);
    }

    Object.assign(window.__hkdoc, { openDocEditor, openTemplateEditor });

    // ===== Document renderers =====
    function fieldPairs(doc) { return (doc.fields || []).filter(f => f && (f.value||f.name)); }

    function renderA4(doc) {
        const accent = doc.accent || branding.accent || '#333';
        const f = fieldPairs(doc).map(x =>
            `<div class="dr-f"><div class="k">${esc(x.name)}</div><div class="v">${esc(x.value)}</div></div>`).join('');
        const imgs = (doc.images||[]).map(u => `<img src="${esc(u)}">`).join('');
        const iss = doc.issuer || {};
        return `<div class="doc-render dr-a4" style="--doc-accent:${esc(accent)}">
            ${doc.isCopy?`<div class="copy-mark">${esc(t('label_copy'))}</div>`:''}
            <div class="dr-head">
                <img class="dr-logo" src="${esc(logoFor(doc))}" onerror="this.style.display='none'">
                <div><div class="dr-org">${esc(doc.jobLabel||branding.label||'')}</div>
                <div class="dr-title">${esc(doc.title||'')}</div></div>
            </div>
            ${doc.description?`<div class="dr-desc">${esc(doc.description)}</div>`:''}
            ${f?`<div class="dr-fields">${f}</div>`:''}
            ${doc.body?`<div class="dr-body">${esc(doc.body)}</div>`:''}
            ${imgs?`<div class="dr-imgs">${imgs}</div>`:''}
            ${doc.infoValue?`<div class="dr-desc"><b>${esc(doc.infoName||'')}</b><br>${esc(doc.infoValue)}</div>`:''}
            <div class="dr-foot">
                <div class="dr-issuer">${esc(t('label_issued', doc.createdAt||''))}</div>
                <div style="text-align:right"><div class="dr-sign">${esc(iss.firstname||'')} ${esc(iss.lastname||'')}</div>
                <div class="dr-issuer">${esc(iss.jobLabel||'')}</div></div>
            </div>
        </div>`;
    }

    function renderLicense(doc) {
        const accent = doc.accent || branding.accent || '#333';
        const f = fieldPairs(doc).map(x =>
            `<div class="lc-f"><div class="k">${esc(x.name)}</div><div class="v">${esc(x.value)}</div></div>`).join('');
        const photo = doc.photo
            ? `<img class="lc-photo" src="${esc(doc.photo)}">`
            : `<div class="lc-photo">${esc(t('label_photo'))}</div>`;
        return `<div class="doc-render dr-license" style="--doc-accent:${esc(accent)}">
            ${doc.isCopy?`<div class="copy-mark">${esc(t('label_copy'))}</div>`:''}
            <div class="lc-top">
                <img src="${esc(logoFor(doc))}" onerror="this.style.display='none'">
                <div><div class="lc-org">${esc(doc.jobLabel||branding.label||'')}</div>
                <div class="lc-type">${esc(doc.title||t('label_license'))}</div></div>
            </div>
            <div class="lc-body">
                ${photo}
                <div class="lc-fields">${f}
                    ${doc.expiry?`<div class="lc-f"><div class="k">${esc(t('label_expires'))}</div><div class="v">${esc(doc.expiry)}</div></div>`:''}
                </div>
            </div>
            <div class="lc-foot"><span>${esc(t('label_issued', doc.createdAt||''))}</span>
                <span>${esc((doc.issuer||{}).firstname||'')} ${esc((doc.issuer||{}).lastname||'')}</span></div>
        </div>`;
    }

    function renderCert(doc) {
        const accent = doc.accent || branding.accent || '#8a6d3b';
        const recipient = (fieldPairs(doc)[0]||{}).value || '';
        const iss = doc.issuer || {};
        return `<div class="doc-render dr-cert" style="--doc-accent:${esc(accent)}">
            ${doc.isCopy?`<div class="copy-mark">${esc(t('label_copy'))}</div>`:''}
            <img class="dr-logo" src="${esc(logoFor(doc))}" onerror="this.style.display='none'">
            <div class="ct-org">${esc(doc.jobLabel||branding.label||'')}</div>
            <div class="ct-title">${esc(doc.title||t('label_certificate'))}</div>
            ${recipient?`<div class="ct-recipient">${esc(recipient)}</div>`:''}
            ${doc.description?`<div class="ct-desc">${esc(doc.description)}</div>`:''}
            <div class="ct-foot">
                <div>${esc(doc.createdAt||'')}</div>
                <div class="ct-sign">${esc(iss.firstname||'')} ${esc(iss.lastname||'')}</div>
            </div>
        </div>`;
    }

    function renderDoc(doc) {
        if (doc.docType === 'license') return renderLicense(doc);
        if (doc.docType === 'certificate') return renderCert(doc);
        return renderA4(doc);
    }

    // detail view in the work column (My Documents)
    function showDocDetail(doc) {
        workCol.innerHTML = `<div class="preview-wrap">${renderDoc(doc)}</div>
            <div class="editor-actions">
                <button class="btn-secondary" id="dv-show">${esc(t('btn_show_nearby'))}</button>
                <button class="btn-secondary" id="dv-copy">${esc(t('btn_give_copy'))}</button>
                <button class="btn-secondary" id="dv-del" style="color:var(--red);border-color:rgba(248,113,113,0.35)">${esc(t('btn_delete'))}</button>
            </div>`;
        $('#dv-show').addEventListener('click', () => openNearbyPicker(doc, 'showToNearby'));
        $('#dv-copy').addEventListener('click', () => openNearbyPicker(doc, 'giveCopy'));
        $('#dv-del').addEventListener('click', async () => {
            await post('deleteDocument', { id: doc.id });
            setTab('mine');
        });
    }

    // Nearby-player picker: list of in-range players (name + /id) to give/show to.
    async function openNearbyPicker(doc, action) {
        dismissMiniModal();
        const players = (await post('getNearby')) || [];
        const modal = document.createElement('div');
        modal.className = 'mini-modal';
        const title = action === 'giveCopy' ? t('pick_give_title') : t('pick_show_title');
        const rows = players.length
            ? players.map(p => `<div class="np-row" data-id="${p.id}">
                    <span class="np-name">${esc(p.name)}</span>
                    <span class="np-id">/id ${p.id}</span>
               </div>`).join('')
            : `<p style="color:var(--fg-dim);font-size:13px;">${esc(t('pick_none'))}</p>`;
        modal.innerHTML = `
            <div class="mini-card" style="text-align:left;">
                <h3 style="text-align:center;">${esc(title)}</h3>
                <div class="np-list">${rows}</div>
                <button class="btn-secondary" id="np-cancel" style="width:100%;margin-top:14px;">${esc(t('btn_cancel'))}</button>
            </div>`;
        document.body.appendChild(modal);
        activeModal = modal;
        modal.querySelector('#np-cancel').addEventListener('click', dismissMiniModal);
        modal.querySelectorAll('.np-row').forEach(r => r.addEventListener('click', () => {
            post(action, { id: doc.id, targetSrc: parseInt(r.dataset.id) });
            dismissMiniModal();
        }));
    }

    // fullscreen (received from another player)
    function showFullscreen(doc) {
        stage.innerHTML = renderDoc(doc);
        overlay.classList.remove('hidden');
    }
    $('#view-close').addEventListener('click', () => { post('closeView'); overlay.classList.add('hidden'); });
})();
