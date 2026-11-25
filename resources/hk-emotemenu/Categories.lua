-- hk-emotemenu — RP sub-category map for the Emotes tab
-- The base dpemotes list is one flat 359-entry table. This file tags each emote
-- into a browsable RP sub-section so the NUI can render labelled groups.
--
-- How it resolves (see HKEmote.CategoryOf):
--   1) strip trailing digits from the key  ("wave9" -> "wave", "sit2" -> "sit")
--   2) exact-match that base against BaseMap (exact-match avoids prefix
--      collisions like no / noway / nosepick / notepad)
--   3) fall back to PrefixRules (only the wait[b-m] family needs this)
--   4) anything still unmatched -> "other"  (never lost; search covers all)
--
-- Only DP.Emotes are sub-categorised. Dances / Props / Walks / Moods / Shared
-- are already their own top-level tabs.

HKEmote = {}

-- Display order + labels for the Emotes-tab sub-sections. `id` must match the
-- values used in BaseMap / PrefixRules. "other" is always last as a catch-all.
HKEmote.CategoryOrder = {
    { id = 'greetings', en = 'Greetings & Social', zh = '社交問候', icon = '🤝' },
    { id = 'reactions', en = 'Reactions',          zh = '反應',     icon = '😮' },
    { id = 'attitude',  en = 'Rude & Aggro',       zh = '挑釁粗魯', icon = '😤' },
    { id = 'idle',      en = 'Idle & Leaning',     zh = '待機倚靠', icon = '🧍' },
    { id = 'sitting',   en = 'Sitting & Lying',    zh = '坐臥',     icon = '🪑' },
    { id = 'poses',     en = 'Poses & Photo',      zh = '姿勢影相', icon = '📸' },
    { id = 'jobs',      en = 'Jobs & Work',        zh = '工作',     icon = '🔧' },
    { id = 'fun',       en = 'Fitness & Fun',      zh = '運動娛樂', icon = '🎉' },
    { id = 'animals',   en = 'Animals',            zh = '動物',     icon = '🐦' },
    { id = 'adult',     en = '18+',                zh = '成人',     icon = '🔞' },
    { id = 'other',     en = 'Other',              zh = '其他',     icon = '▸'  },
}

-- base key (trailing digits stripped, lowercased) -> category id
HKEmote.BaseMap = {
    -- greetings & social
    wave='greetings', handshake='greetings', salute='greetings', bow='greetings',
    curtsy='greetings', namaste='greetings', hug='greetings', peace='greetings',
    blowkiss='greetings', cheer='greetings', thumbsup='greetings', clap='greetings',
    slowclap='greetings', clapangry='greetings', handsup='greetings', jazzhands='greetings',
    wait='greetings', me='greetings', point='greetings', pointright='greetings',
    pointdown='greetings', whistle='greetings', yeah='greetings', ok='greetings',
    knock='greetings', hangout='greetings',

    -- reactions
    facepalm='reactions', shrug='reactions', think='reactions', damn='reactions',
    no='reactions', noway='reactions', scared='reactions', nervous='reactions',
    stunned='reactions', mindblown='reactions', mindcontrol='reactions', cough='reactions',
    smell='reactions', stink='reactions', nosepick='reactions', lol='reactions',
    boi='reactions', celebrate='reactions', countdown='reactions', damn2='reactions',

    -- rude & aggro
    finger='attitude', flipoff='attitude', screwyou='attitude', bringiton='attitude',
    comeatmebro='attitude', fightme='attitude', argue='attitude', threaten='attitude',
    cutthroat='attitude', gangsign='attitude', slap='attitude', headbutt='attitude',
    punching='attitude', boxing='attitude', karate='attitude', metal='attitude',
    surrender='attitude', stickup='attitude',

    -- idle & leaning
    idle='idle', idledrunk='idle', chill='idle', lean='idle', leanside='idle',
    leanbar='idle', leanhigh='idle', leanflirt='idle', crossarms='idle',
    crossarmsside='idle', foldarms='idle', warmth='idle', impatient='idle',
    outofbreath='idle',

    -- sitting & lying
    sit='sitting', sitlow='sitting', sitlean='sitting', sitsad='sitting',
    sitscared='sitting', sitdrunk='sitting', sitchair='sitting', sitchairside='sitting',
    kneel='sitting', prone='sitting', crawl='sitting', cloudgaze='sitting',
    sunbathe='sitting', sunbatheback='sitting', sleep='sitting', fallasleep='sitting',
    passout='sitting', bumsleep='sitting', ledge='sitting',

    -- poses & photo
    t='poses', statue='poses', superhero='poses', spiderman='poses', flex='poses',
    peek='poses', peace2='poses', fspose='poses', me2='poses', record='poses',
    texting='poses', type='poses', clipboard2='poses', notepad2='poses',

    -- jobs & work
    cop='jobs', copbeacon='jobs', medic='jobs', cpr='jobs', mechanic='jobs',
    weld='jobs', hammer='jobs', drilling='jobs', janitor='jobs', maid='jobs',
    garden='jobs', guard='jobs', lookout='jobs', musician='jobs', bartender='jobs',
    valet='jobs', parkingmeter='jobs', keyfob='jobs', inspect='jobs', picklock='jobs',
    uncuff='jobs', radio='jobs', filmshocking='jobs', prosthigh='jobs', prostlow='jobs',

    -- fitness & fun
    pushup='fun', situp='fun', chinup='fun', jumpingjacks='fun', stretch='fun',
    yoga='fun', meditate='fun', jog='fun', jog2='fun', hiking='fun', karate2='fun',
    golfswing='fun', slugger='fun', airguitar='fun', airsynth='fun', fishdance='fun',
    clown='fun', party='fun', bbq='fun', atm='fun', eat='fun', drink='fun',
    dispenser='fun', smoke='fun', smokeweed='fun', smokepot='fun', tryclothes='fun',
    windowshop='fun', flip='fun', slide='fun', crawl2='fun', spraychamp='fun',
    airplane='fun', beast='fun',

    -- extras folded out of "other"
    fallover='reactions', stumble='reactions', shot='reactions', shakeoff='reactions',
    adjust='idle', adjusttie='idle', pullover='idle', knucklecrunch='idle',
    cleanhands='jobs', cleanface='jobs', buzz='jobs', pickup='jobs', pull='jobs',
    push='jobs', reaching='jobs', lift='greetings',

    -- animals
    bird='animals', chicken='animals', bark='animals', rabbit='animals',
    petting='animals', hump='animals',

    -- 18+
    fspose2='adult', fspose4='adult', tighten='adult', showerf='adult',
    showerm='adult', piss='adult', pee='adult',
}

-- Prefix fallbacks for families that don't share a clean digit-stripped base.
-- Checked in order, longest-prefix-first, only if BaseMap missed. `wait` has
-- lettered variants (waitb..waitm) that strip to "wait" fine, but the bare
-- alpha suffixes are covered here for safety.
HKEmote.PrefixRules = {
    { p = 'shower', c = 'adult' },
    { p = 'fspose', c = 'adult' },
    { p = 'clown',  c = 'fun'   },
    { p = 'wait',   c = 'greetings' },
    { p = 'lean',   c = 'idle'  },
    { p = 'sit',    c = 'sitting' },
    { p = 'idle',   c = 'idle'  },
}

-- key -> category id. Never returns nil (falls through to 'other').
function HKEmote.CategoryOf(key)
    key = string.lower(key)
    -- strip a trailing run of digits: wave9 -> wave, sitchair2 -> sitchair
    local base = key:gsub('%d+$', '')

    if HKEmote.BaseMap[key]  then return HKEmote.BaseMap[key]  end  -- exact key first
    if HKEmote.BaseMap[base] then return HKEmote.BaseMap[base] end  -- then digit-stripped

    for _, r in ipairs(HKEmote.PrefixRules) do
        if key:sub(1, #r.p) == r.p then return r.c end
    end
    return 'other'
end

