/* ============================================================
   HOMEKONG loading screen
   Vanilla JS — no external CDN. Edit the DATA block below.
   ============================================================ */

// ---- Background images (edit this list to match /assets/images) ----
// Filenames must match EXACTLY (extension matters: .jpg vs .png).
// Any resolution/aspect works — they're rendered with background-size: cover.
const IMAGES = [
    '1.jpg',
    '2.jpg',
    '3.png',
    '4.png',
    '5.png',
];

// ---- Server description (shown top-left) ----
const SERVER_DESC =
    'HOMEKONG 是香港第一個民主自由角色扮演伺服器。一切由民選領袖玩家管治，' +
    '並依隨憲法辦事 — 白宮、國會、最高法院、軍情局俱全。坐穩，我哋幫緊你下載入嚟玩嘅模組，' +
    '完成後會自動進入伺服器，請勿關閉電腦。';

// ---- Card 1: Driving (hk-handling gearbox / EV regen / hybrid + hk-speedo) ----
// keys map to physical defaults; players can rebind in FiveM settings.
// K/J are dual-purpose: gear shift on combustion, regen level on EVs.
const DRIVING = [
    { key: 'K / J',  label: '升 / 降檔',     sub: '油車換檔 · 電車回充 D1-D3' },
    { key: 'L·SHIFT',label: '離合 / 滑行',   sub: 'Clutch · DCT→自動 · 電車→Coast' },
    { key: 'K + J',  label: '入空檔',        sub: 'Hold 兩鍵 · 連按=鎖定空檔' },
    { key: 'G',      label: '動力模式',      sub: '長按: 電動→混合→引擎 · 單按開關引擎' },
    { key: 'CAPS',   label: '甩尾模式',      sub: 'Hold — Drift Mode' },
];

// ---- Card 2: Tools (speedo + racecam + cruise + emotes + referral) ----
const RACING = [
    { key: 'F6',        label: '切換車速錶', sub: '4 種模式循環 · /speedo' },
    { key: 'F7',        label: '賽事鏡頭',   sub: '切換 追car / 引擎蓋 視角' },
    { key: 'F4',        label: '鎖定鏡頭',   sub: 'Race Cam 鎖定/解鎖' },
    { key: 'Y',         label: '定速巡航',   sub: 'Cruise Control' },
    { key: 'B',         label: '安全帶',     sub: 'Seatbelt' },
];

// ---- Card 3: Menu, Services & core keys ----
// F5 opens the main menu hub → shop / battlepass / daily rewards / more.
const COMMUNITY = [
    { key: 'F5',    label: '主選單',   sub: 'HK Hub 導航' },
    { key: 'M',     label: '電話',     sub: 'Phone' },
    { key: 'TAB',   label: '物品庫',   sub: 'Inventory' },
    { key: 'F1',    label: '圓形選單', sub: 'Radial Menu' },
    { key: 'X',     label: '舉手',     sub: 'Hands Up' },
];

// ---- Rotating tips (footer) ----
const TIPS = [
    '按 K / J 換檔 — 手波車配合離合器 (L·Shift) 可獲得換檔完美加成。',
    '手波車同時按住 K + J 可入空檔，連按兩下即鎖定空檔。',
    'DCT 波箱撳一下 L·Shift 就可以喺自動同撥片之間切換。',
    '電車用單踏板駕駛：鬆油門就會回充減速，K / J 可調校 D1-D3 回充力度。',
    '電車 D3 最強回充可以令架車喺路口自動停定；想滑行就撳 L·Shift 入 Coast。',
    '電車停定後入空檔，再踩一下brake就入倒檔，踩油門返前進 — 倒車唔使搵掣。',
    '混能超跑長按 G 切換 電動 → 混合 → 引擎 模式，靜靜雞飆到指定速度先著引擎。',
    '按 F6 (或 /speedo) 循環切換 4 種車速錶模式，簡約模式更慳 FPS。',
    '長途巡航揸得攰？按 Y 開定速巡航，鬆腳都保持車速。',
    '比賽期間按 F7 切換賽事鏡頭 (追car / 引擎蓋)，F4 鎖定運鏡。',
    '按 F5 打開主選單 — 商店、開箱、戰鬥通行證、每日獎勵一次過搞掂。',
    '主選單內每日簽到領獎，連續登入獎品更豐富；邀請朋友仲有 HOMECOIN。',
    'HOMEKONG 由民選政府管治，記得參與投票同國會事務。',
    '所有按鍵可於 FiveM 設定 → 按鍵綁定 中自訂。',
];

// ============================================================
//  Render
// ============================================================
function keyRow(item) {
    const capCls = item.cmd ? 'keycap cmd' : 'keycap';
    const sub = item.sub ? `<small>${item.sub}</small>` : '';
    return `<div class="krow">
        <span class="${capCls}">${item.key}</span>
        <span class="klabel">${item.label}${sub}</span>
    </div>`;
}

document.getElementById('server-desc').textContent = SERVER_DESC;
document.getElementById('driving-list').innerHTML = DRIVING.map(keyRow).join('');
document.getElementById('racing-list').innerHTML = RACING.map(keyRow).join('');
document.getElementById('community-list').innerHTML = COMMUNITY.map(keyRow).join('');

// ============================================================
//  Background carousel + Ken Burns
//  Slides are built from IMAGES so swapping files only means
//  editing that array (no stale hardcoded filenames to 404).
// ============================================================
const bgEl = document.getElementById('bg');
const slides = IMAGES.map((file, i) => {
    const div = document.createElement('div');
    div.className = 'bg-slide' + (i === 0 ? ' active' : '');
    div.style.backgroundImage = `url('/assets/images/${file}')`;
    bgEl.appendChild(div);
    return div;
});
let bgIdx = 0;
if (slides.length > 1) {
    setInterval(() => {
        slides[bgIdx].classList.remove('active');
        bgIdx = (bgIdx + 1) % slides.length;
        slides[bgIdx].classList.add('active');
    }, 6000);
}

// ============================================================
//  Rotating tips
// ============================================================
const tipEl = document.getElementById('tip-text');
let tipIdx = 0;
function showTip() {
    tipEl.classList.remove('show');
    setTimeout(() => {
        tipEl.textContent = TIPS[tipIdx];
        tipEl.classList.add('show');
        tipIdx = (tipIdx + 1) % TIPS.length;
    }, 400);
}
showTip();
setInterval(showTip, 6500);

// ============================================================
//  Audio toggle
// ============================================================
const audio = document.getElementById('audio');
audio.volume = 0.15;
const audioBtn = document.getElementById('audio-btn');
const iconOn = document.getElementById('audio-on');
const iconOff = document.getElementById('audio-off');
audioBtn.addEventListener('click', () => {
    if (audio.paused) { audio.play(); iconOn.classList.remove('hidden'); iconOff.classList.add('hidden'); }
    else { audio.pause(); iconOn.classList.add('hidden'); iconOff.classList.remove('hidden'); }
});

// ============================================================
//  Loading progress (FiveM loadscreen events — preserved plumbing)
// ============================================================
const fill = document.getElementById('loadfill');
const pctEl = document.getElementById('loadpct');
let total = 0, done = 0;

function setPct(p) {
    p = Math.max(0, Math.min(100, p));
    fill.style.width = p + '%';
    pctEl.textContent = Math.round(p) + '%';
}

const handlers = {
    startInitFunctionOrder(data) { total = data.count; done = 0; },
    initFunctionInvoking(data)   { setPct((data.idx / total) * 100); },
    startDataFileEntries(data)   { total = data.count; done = 0; },
    performMapLoadFunction()     { done++; setPct((done / total) * 100); },
    onLogLine() {},
    onDataFileEntry() {},
};

window.addEventListener('message', (e) => {
    const fn = handlers[e.data && e.data.eventName];
    if (fn) fn(e.data);
});
