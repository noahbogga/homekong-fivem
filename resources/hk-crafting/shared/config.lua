Config = {}

-- ── Core ────────────────────────────────────────────────────────────────
Config.Locale         = 'zh'          -- 'zh' = 繁中(HK), 'en' = English
Config.SaveToDatabase = true          -- persist placed tables across restarts
Config.Debug          = false         -- print() diagnostics

-- ── Weapon license documents (hk-documents integration) ───────────────────
-- When a gundealer crafts an actual weapon, auto-issue a weapon license via
-- hk-documents carrying the weapon's serial. Owner name + expiry left BLANK
-- for the gundealer/authority to fill in later.
Config.WeaponLicense = {
    enabled   = true,
    recipeSet = 'gundealer',            -- only crafts from this set generate a license
    job       = 'firearms_license',     -- hk-documents branding key (says "Firearms License")
    docType   = 'license',
    title     = 'Firearms License',
    -- only item names matching this pattern get a license (skips ammo/armor)
    itemPattern = '^weapon_',
}

-- ── Placement ───────────────────────────────────────────────────────────
Config.Placement = {
    GhostAlpha    = 200,              -- transparency of the ghost prop while positioning
    OutlineColor  = { r = 0, g = 200, b = 255 },  -- HK cyan placement outline
    RotateStep    = 10.0,            -- degrees per scroll notch
    MaxDistance   = 8.0,             -- furthest the ghost can sit from the player
    PlaceDuration = 1000,           -- ms progress bar when confirming placement
    PickupDuration = 1000,          -- ms progress bar when picking up
}

-- ── qb-target interaction on placed tables ───────────────────────────────
Config.Target = {
    Distance         = 2.0,
    OpenLabel        = '開啟合成',
    OpenIcon         = 'fas fa-screwdriver-wrench',
    PickupLabel      = '收起工作枱',
    PickupIcon       = 'fas fa-hand',
    OwnerOnlyPickup  = false,        -- true = only the placer can pick the table back up
}

-- ── Item icon resolution for the NUI grid ────────────────────────────────
-- Craftable icons in the panel are pulled from qb-inventory's image folder by
-- item name (<item>.png). Point this at wherever your inventory images are served.
Config.InventoryImagePath = 'nui://qb-inventory/html/images/%s.png'

-- ── Fixed world stations ──────────────────────────────────────────────────
-- Permanent crafting benches at set map locations (no item needed, can't be
-- picked up). `uses` picks which CraftingTables recipe set the station offers.
-- Add as many as you like. The prop is assumed to already exist in the map at
-- `coords` (a mapped MLO/prop); the zone just attaches the interaction to it.
Config.Stations = {
    {
        id       = 'gundealer_bench',
        label    = '槍械工作枱',
        uses     = 'gundealer',                         -- gundealer weapon recipe set
        coords   = vec3(29.19, -1093.08, 28.8),
        heading  = 250.0,                              -- prop heading (used for the zoom camera)
        radius   = 1.5,                                -- interaction sphere radius
        model    = 170995043,                          -- optional: only shown for reference
        job      = { gundealer = 0 },                  -- qb-target job gate (grade >= 0)
        useMarker = false,                             -- true = draw a subtle ground marker
    },
}

-- ── Crafting tables ───────────────────────────────────────────────────────
-- Each KEY is the inventory item name that, when "used", places that table.
-- craftables KEY = the item name granted on a successful craft.
Config.CraftingTables = {

    ['weapon_craftingtable'] = {
        label = '武器工作枱',
        model = 'gr_prop_gr_bench_04b',

        craftables = {
            ['weapon_pistol'] = {
                label       = 'Pistol',
                model       = 'w_pi_pistol',            -- preview prop on the bench
                description = 'A compact, semi-automatic handgun for personal defense and close-quarters work.',
                amount      = 1,
                duration    = 5000,                     -- ms craft progress
                materials = {
                    { item = 'steel',  label = 'Steel',  amount = 5 },
                    { item = 'copper', label = 'Copper', amount = 3 },
                },
                blueprint      = 'blueprint_pistol',    -- item name, or false for none
                blueprintLabel = 'Pistol Blueprint',
                consumeBlueprint = false,               -- keep the blueprint after crafting
            },
            ['weapon_carbinerifle'] = {
                label       = 'Carbine Rifle',
                model       = 'w_ar_carbinerifle',
                description = 'A versatile automatic rifle engineered for rapid fire and mid-range accuracy.',
                amount      = 1,
                duration    = 8000,
                materials = {
                    { item = 'steel',    label = 'Steel',    amount = 10 },
                    { item = 'copper',   label = 'Copper',   amount = 6 },
                    { item = 'aluminum', label = 'Aluminum', amount = 4 },
                },
                blueprint      = false,
            },
            ['weapon_pumpshotgun'] = {
                label       = 'Pump Shotgun',
                model       = 'w_sg_pumpshotgun',
                description = 'A rugged pump-action shotgun built for stopping power at short range.',
                amount      = 1,
                duration    = 7000,
                materials = {
                    { item = 'steel',  label = 'Steel',  amount = 8 },
                    { item = 'copper', label = 'Copper', amount = 4 },
                },
                blueprint = false,
            },
        },
    },

    ['item_craftingtable'] = {
        label = '物品工作枱',
        model = 'gr_prop_gr_bench_02a',

        craftables = {
            ['toolbox'] = {
                label       = 'Toolbox',
                model       = 'v_ind_cs_toolbox4',
                description = '堅固嘅便攜工具箱,用嚟收納同整理工具。',
                amount      = 1,
                duration    = 4000,
                materials = {
                    { item = 'plastic', label = 'Plastic', amount = 2 },
                    { item = 'steel',   label = 'Steel',   amount = 2 },
                },
                blueprint = false,
            },
            ['lockpick'] = {
                label       = 'Lockpick',
                model       = 'prop_tool_screwdvr02',
                description = '簡單嘅開鎖器。好易爛,但緊急時夠用。',
                amount      = 2,
                duration    = 3000,
                materials = {
                    { item = 'plastic', label = 'Plastic', amount = 1 },
                    { item = 'metalscrap', label = 'Metal Scrap', amount = 3 },
                },
                blueprint = false,
            },
        },
    },
}

-- ══════════════════════════════════════════════════════════════════════════
-- GUNDEALER WEAPON CRAFTING (job-locked recipe set)
-- ──────────────────────────────────────────────────────────────────────────
-- Every weapon here mirrors the qb-shops `gundealer` store. Only players with
-- the `gundealer` job (any grade >= GunCraft.MinGrade) can open/craft, enforced
-- on BOTH the target zone and the server callback.
--
-- Materials are auto-derived from the shop price tier by the builder below, so
-- to rebalance you only edit GunCraft.Tiers (or add a `materials`/`blueprint`
-- override on an individual GUNS entry). Blueprints reuse your existing
-- blueprint_pistol / _smg / _rifle / _shotgun / _armor items.
-- ══════════════════════════════════════════════════════════════════════════
Config.GunCraft = {
    jobLock  = 'gundealer',   -- qb-core job name required
    MinGrade = 0,             -- minimum job grade (0 = any employee, 4 = boss only)

    -- Blueprint item gating per category (false = no blueprint needed).
    -- Blueprints are BOSS-ONLY buyable from the gundealer shop NPC next to the
    -- bench (see qb-shops biblegunshop). Melee stays free (simple to make).
    -- Every craftable category requires a boss-supplied blueprint. The boss buys
    -- blueprints (boss-only) from the gundealer shop NPC and hands them to
    -- workers, so nothing can be crafted without the boss enabling it. Ammo is
    -- the only exception (high-frequency consumable, stays free).
    Blueprints = {
        melee      = 'blueprint_melee',
        pistol     = 'blueprint_pistol',
        smg        = 'blueprint_smg',
        rifle      = 'blueprint_rifle',
        mg         = 'blueprint_mg',
        shotgun    = 'blueprint_shotgun',
        explosive  = 'blueprint_explosive',
        armor      = 'blueprint_armor',
        heavyarmor = 'blueprint_heavyarmor',
        ammo       = false,
    },

    -- Material recipe by price tier. Highest matching threshold wins.
    -- { maxPrice, materials = {...}, duration = ms }
    Tiers = {
        { maxPrice = 4999,    duration = 4000,  materials = { {item='metalscrap',label='Metal Scrap',amount=5},  {item='steel',label='Steel',amount=2} } },
        { maxPrice = 15000,   duration = 6000,  materials = { {item='metalscrap',label='Metal Scrap',amount=10}, {item='steel',label='Steel',amount=5},  {item='copper',label='Copper',amount=3} } },
        { maxPrice = 35000,   duration = 9000,  materials = { {item='steel',label='Steel',amount=12}, {item='copper',label='Copper',amount=6},  {item='aluminum',label='Aluminum',amount=5},  {item='metalscrap',label='Metal Scrap',amount=8} } },
        { maxPrice = 80000,   duration = 12000, materials = { {item='steel',label='Steel',amount=20}, {item='aluminum',label='Aluminum',amount=10}, {item='copper',label='Copper',amount=8},  {item='electronickit',label='Electronic Kit',amount=1} } },
        { maxPrice = math.huge, duration = 18000, materials = { {item='steel',label='Steel',amount=35}, {item='aluminum',label='Aluminum',amount=20}, {item='copper',label='Copper',amount=15}, {item='electronickit',label='Electronic Kit',amount=2}, {item='diamond',label='Diamond',amount=1} } },
    },
}

-- ══════════════════════════════════════════════════════════════════════════
-- WEAPON REPAIR (維修 tab)
-- ──────────────────────────────────────────────────────────────────────────
-- Repairs a held weapon's info.quality back up. The gundealer picks the TARGET
-- quality on a slider; material cost scales with the points restored, so they
-- can upsell the repair. Tab is visible to all gundealers but greyed out below
-- MinGrade (they see it locked). Enforced server-side too.
-- ══════════════════════════════════════════════════════════════════════════
Config.Repair = {
    enabled    = true,
    MinGrade   = 3,             -- grade 3+ can repair; below = tab greyed out
    -- Materials needed PER 1% of quality restored. Final cost = ceil(points * per).
    -- e.g. restoring 60 points with steel per=0.15 -> ceil(9) = 9 steel.
    CostPerPoint = {
        { item = 'metalscrap', label = 'Metal Scrap', per = 0.12 },
        { item = 'steel',      label = 'Steel',        per = 0.05 },
        { item = 'copper',     label = 'Copper',       per = 0.03 },
    },
    Duration = 8000,            -- ms progress bar for a repair
}

-- The gundealer catalogue (mirrors qb-shops `gundealer`). Each entry:
--   { item, label, cat, price, model=weapon preview prop, amount=1 }
-- `price` only drives which material tier the builder picks. Add/remove freely.
local GUNS = {
    -- melee / misc
    { item='weapon_knife',          label='Knife',            cat='melee',   price=500,    model='w_me_knife_01' },
    { item='weapon_knuckle',        label='Knuckle Duster',   cat='melee',   price=1000,   model='w_me_knuckle' },
    { item='weapon_battleaxe',      label='Battle Axe',       cat='melee',   price=5000,   model='w_me_battleaxe' },
    { item='weapon_switchblade',    label='Switchblade',      cat='melee',   price=5000,   model='w_me_switchblade' },
    { item='weapon_flashlight',     label='Flashlight',       cat='melee',   price=7000,   model='w_me_flashlight' },
    -- pistols
    { item='weapon_snspistol',      label='SNS Pistol',       cat='pistol',  price=6000,   model='w_pi_sns_pistol' },
    { item='weapon_pistol',         label='Pistol',           cat='pistol',  price=10000,  model='w_pi_pistol' },
    { item='weapon_revolver',       label='Revolver',         cat='pistol',  price=12000,  model='w_pi_revolver' },
    { item='weapon_ceramicpistol',  label='Ceramic Pistol',   cat='pistol',  price=20000,  model='w_pi_ceramicpistol' },
    { item='weapon_pistol50',       label='Pistol .50',       cat='pistol',  price=20000,  model='w_pi_pistol50' },
    -- smg
    { item='weapon_minismg',        label='Mini SMG',         cat='smg',     price=15000,  model='w_sb_minismg' },
    { item='weapon_microsmg',       label='Micro SMG',        cat='smg',     price=20000,  model='w_sb_microsmg' },
    { item='weapon_smg',            label='SMG',              cat='smg',     price=30000,  model='w_sb_smg' },
    { item='weapon_assaultsmg',     label='Assault SMG',      cat='smg',     price=35000,  model='w_sb_assaultsmg' },
    { item='weapon_combatpdw',      label='Combat PDW',       cat='smg',     price=35000,  model='w_sb_pdw' },
    { item='weapon_gusenberg',      label='Gusenberg Sweeper',cat='smg',     price=35000,  model='w_sb_gusenberg' },
    -- rifles
    { item='weapon_compactrifle',   label='Compact Rifle',    cat='rifle',   price=30000,  model='w_ar_assaultrifle_smg' },
    { item='weapon_assaultrifle',   label='Assault Rifle',    cat='rifle',   price=40000,  model='w_ar_assaultrifle' },
    { item='weapon_bullpuprifle',   label='Bullpup Rifle',    cat='rifle',   price=47000,  model='w_ar_bullpuprifle' },
    { item='weapon_carbinerifle',   label='Carbine Rifle',    cat='rifle',   price=50000,  model='w_ar_carbinerifle' },
    { item='weapon_specialcarbine', label='Special Carbine',  cat='rifle',   price=55000,  model='w_ar_specialcarbine' },
    -- shotguns
    { item='weapon_dbshotgun',      label='Double Barrel',    cat='shotgun', price=30000,  model='w_sg_doublebarrel' },
    { item='weapon_sawnoffshotgun', label='Sawn-Off Shotgun', cat='shotgun', price=40000,  model='w_sg_sawnoff' },
    { item='weapon_pumpshotgun',    label='Pump Shotgun',     cat='shotgun', price=60000,  model='w_sg_pumpshotgun' },
    { item='weapon_bullpupshotgun', label='Bullpup Shotgun',  cat='shotgun', price=80000,  model='w_sg_bullpupshotgun' },
    { item='weapon_combatshotgun',  label='Combat Shotgun',   cat='shotgun', price=160000, model='w_sg_assaultshotgun' },
    -- machine guns
    { item='weapon_mg',             label='Machine Gun',      cat='mg',      price=220000, model='w_mg_mg' },
    { item='weapon_combatmg',       label='Combat MG',        cat='mg',      price=450000, model='w_mg_combatmg' },
    -- armor
    { item='armor',                 label='Body Armor',       cat='armor',   price=30000,  model='prop_armour_pickup' },
    { item='heavyarmor',            label='Heavy Armor',      cat='heavyarmor', price=60000, model='prop_armour_pickup' },
    -- explosives / throwables (blueprint-gated as a group via 'explosive')
    { item='weapon_molotov',        label='Molotov',          cat='explosive', price=8000,   model='w_ex_molotov' },
    { item='weapon_pipebomb',       label='Pipe Bomb',        cat='explosive', price=15000,  model='w_ex_pipebomb' },
    { item='weapon_grenade',        label='Grenade',          cat='explosive', price=25000,  model='w_ex_grenadefrag' },
    { item='weapon_smokegrenade',   label='Smoke Grenade',    cat='explosive', price=6000,   model='w_ex_grenadesmoke' },
    { item='weapon_stickybomb',     label='Sticky Bomb',      cat='explosive', price=60000,  model='w_ex_pe' },
    { item='weapon_proxmine',       label='Proximity Mine',   cat='explosive', price=80000,  model='w_ex_apmine' },
    -- AMMO CHAIN --------------------------------------------------------------
    -- Step 1: bullet_shell is the base component. It is the ONLY ammo-tab item
    --   gated by blueprint_ammo (boss-only). Crafted from raw metal.
    -- Step 2: the 5 ammo clips are blueprint-FREE but each needs bullet_shell +
    --   gunpowder (from recycling), with amounts scaled per weapon class.
    { item='bullet_shell', label='Bullet Shells', cat='ammo', price=2000, amount=50, model='prop_ld_case_01', bp='blueprint_ammo',
      mats={ {item='metalscrap',label='Metal Scrap',amount=6},{item='copper',label='Copper',amount=3} } },

    { item='pistol_ammo',  label='Pistol Ammo',  cat='ammo', amount=30, model='w_pi_pistol',       bp=false,
      mats={ {item='bullet_shell',label='Bullet Shells',amount=30},{item='gunpowder',label='Gunpowder',amount=8} } },
    { item='smg_ammo',     label='SMG Ammo',     cat='ammo', amount=30, model='w_sb_smg',          bp=false,
      mats={ {item='bullet_shell',label='Bullet Shells',amount=30},{item='gunpowder',label='Gunpowder',amount=12} } },
    { item='rifle_ammo',   label='Rifle Ammo',   cat='ammo', amount=30, model='w_ar_assaultrifle', bp=false,
      mats={ {item='bullet_shell',label='Bullet Shells',amount=30},{item='gunpowder',label='Gunpowder',amount=16} } },
    { item='shotgun_ammo', label='Shotgun Ammo', cat='ammo', amount=30, model='w_sg_pumpshotgun',  bp=false,
      mats={ {item='bullet_shell',label='Bullet Shells',amount=30},{item='gunpowder',label='Gunpowder',amount=14} } },
    { item='mg_ammo',      label='MG Ammo',      cat='ammo', amount=30, model='w_mg_mg',           bp=false,
      mats={ {item='bullet_shell',label='Bullet Shells',amount=30},{item='gunpowder',label='Gunpowder',amount=20} } },
}

-- Pick the material tier whose maxPrice first covers `price`. Entries without a
-- price (e.g. ammo clips that supply their own `mats`) get the cheapest tier's
-- duration and never rely on tier.materials.
local function tierFor(price)
    if not price then return Config.GunCraft.Tiers[1] end
    for _, t in ipairs(Config.GunCraft.Tiers) do
        if price <= t.maxPrice then return t end
    end
    return Config.GunCraft.Tiers[#Config.GunCraft.Tiers]
end

-- Build the `gundealer` recipe set into Config.CraftingTables from GUNS above.
do
    local craftables = {}
    for idx, g in ipairs(GUNS) do
        local tier = tierFor(g.price)
        local bp   = g.bp
        if bp == nil then bp = Config.GunCraft.Blueprints[g.cat] end

        -- UI category (the top tab this item lands under). 繁中(HK) tab names.
        local CATEGORY_TAB = {
            ammo       = '子彈',
            melee      = '近戰',
            explosive  = '爆裂物',
            armor      = '防彈衣',
            heavyarmor = '防彈衣',
            -- pistol/smg/rifle/shotgun/mg all fall under 槍械
        }
        local category = CATEGORY_TAB[g.cat] or '槍械'

        craftables[g.item] = {
            label            = g.label,
            model            = g.model,
            description      = nil,     -- filled from qb-core label client-side
            amount           = g.amount or 1,
            duration         = tier.duration,
            materials        = g.mats or tier.materials,
            blueprint        = bp or false,
            blueprintLabel   = nil,     -- resolved from the blueprint item's own label
            consumeBlueprint = false,   -- keep blueprints (reusable schematics)
            category         = category,
            order            = idx,     -- preserve GUNS list order in the UI
        }
    end

    Config.CraftingTables['gundealer'] = {
        label      = '槍械工作枱',
        model      = 'gr_prop_gr_bench_04b',
        jobLock    = Config.GunCraft.jobLock,     -- server enforces this
        minGrade   = Config.GunCraft.MinGrade,
        -- Materials are drawn from this job stash (qb-stashes2 stashName), not the
        -- crafter's pockets. Blueprints stay personal. Set to false to use pockets.
        materialStash = 'gundealer_stash',
        craftables = craftables,
    }
end

