Locales = {}

Locales['en'] = {
    -- placement
    place_instructions   = '[Scroll] Rotate  •  [E] Confirm  •  [X] Cancel',
    no_place_in_vehicle  = 'You cannot place a table while in a vehicle',
    no_place_no_room     = 'Not enough room to place the table here',
    placing_table        = 'Placing table...',
    placed_table         = 'Placed crafting table',
    already_placing      = 'You are already placing a table',
    cancelled_placing    = 'Cancelled placement',

    -- pickup
    picking_up_table     = 'Picking up table...',
    picked_up_table      = 'Picked up crafting table',
    pickup_failed        = 'Failed to pick up table',
    pickup_not_owner     = 'This table does not belong to you',

    -- crafting
    table_name           = "%s's Bench",     -- %s = player name
    craft_required       = 'Required Materials',
    craft_missing_items  = 'You are missing required materials',
    craft_no_job         = 'You are not authorized to craft here',
    craft_inv_full       = 'Your inventory is full',
    not_found            = 'Weapon not found',
    craft_missing_bp     = 'You are missing the %s',      -- %s = blueprint label
    craft_success        = 'Crafted %sx %s',              -- amount, item label
    craft_cancelled      = 'Crafting cancelled',
    crafting_progress    = 'Crafting %s...',              -- item label
    craft_button         = 'Craft',
    have_label           = 'have',                        -- "3 / 5 have"

    -- NUI static text
    ui_select_hint       = 'Select an item to craft',
    ui_makes             = 'makes %s',
    ui_blueprint         = 'Blueprint',
    ui_craft_desc        = 'Craft a %s. Requires the matching blueprint and materials.',
    ui_repair_tab        = 'Repair',
    ui_repair_btn        = 'Repair',
    ui_repair_target     = 'Target Quality',
    ui_repair_none       = 'You have no weapons to repair',
    ui_repair_locked     = 'Requires rank 3 or above',
    ui_repair_progress   = 'weapon',
    repair_ok            = 'Repaired to %s%%',
    repair_no_grade      = 'You are not authorized to repair',
    repair_no_materials  = 'Not enough materials',
}

Locales['zh'] = {
    -- placement
    place_instructions   = '[滾輪] 旋轉  •  [E] 確認  •  [X] 取消',
    no_place_in_vehicle  = '你唔可以喺車入面擺放工作枱',
    no_place_no_room     = '呢度冇足夠空間擺放工作枱',
    placing_table        = '擺放工作枱中...',
    placed_table         = '已擺放合成工作枱',
    already_placing      = '你已經喺度擺放緊工作枱',
    cancelled_placing    = '已取消擺放',

    -- pickup
    picking_up_table     = '收拾工作枱中...',
    picked_up_table      = '已收起合成工作枱',
    pickup_failed        = '收起工作枱失敗',
    pickup_not_owner     = '呢個工作枱唔屬於你',

    -- crafting
    table_name           = '%s 嘅工作枱',                 -- %s = player name
    craft_required       = '所需材料',
    craft_missing_items  = '你缺少所需材料',
    craft_no_job         = '你冇權限喺度合成',
    craft_inv_full       = '你嘅背包已滿',
    not_found            = '搵唔到武器',
    craft_missing_bp     = '你缺少 %s',                    -- %s = blueprint label
    craft_success        = '成功合成 %s 件 %s',            -- amount, item label
    craft_cancelled      = '已取消合成',
    crafting_progress    = '合成緊 %s...',                 -- item label
    craft_button         = '合成',
    have_label           = '擁有',                         -- "3 / 5 擁有"

    -- NUI static text
    ui_select_hint       = '揀一件物品嚟合成',
    ui_makes             = '製成 %s 件',                   -- "製成 2 件"
    ui_blueprint         = '藍圖',
    ui_craft_desc        = '合成 %s。需要對應嘅藍圖同材料。',  -- %s = item label
    ui_repair_tab        = '維修',
    ui_repair_btn        = '維修',
    ui_repair_target     = '目標耐久',
    ui_repair_none       = '你冇武器可以維修',
    ui_repair_locked     = '需要三級或以上先可以使用',
    ui_repair_progress   = '武器',
    repair_ok            = '已維修到 %s%%',
    repair_no_grade      = '你冇權限維修',
    repair_no_materials  = '材料唔夠',
}
