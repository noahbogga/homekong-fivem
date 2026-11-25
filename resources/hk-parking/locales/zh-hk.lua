-- HOMEKONG 香港中文 (廣東話) — 對應伺服器 qb_locale "zh-hk"
-- Merged locale for the all-in-one hk-parking: garage keys + street-parking keys
-- share ONE Lang (both subsystems live in one resource).
local Translations = {
    -- ── Garage (was hk-garage hk.lua) ──────────────────────────────────────
    error = {
        no_vehicles = "你無載具係呢一個車庫到!",
        not_impound = "你架車唔係扣押場",
        not_owned = "無人擁有呢架載具",
        not_correct_type = "你唔能夠係到停泊呢一類載具",
        not_enough = "你唔夠錢俾",
        no_garage = "None",
        vehicle_occupied = "你唔能夠停泊呢架車, 因為上面有人",
        not_depot = "唔可以係扣留中心攞車",
        vehicle_not_tracked = "追蹤唔到架車",
        no_spawn = "呢度太逼喇",
    },
    success = {
        vehicle_parked = "載具已停泊",
        vehicle_taken = "成功攞返架車",
        vehicle_tracked = "已追蹤架車",
    },
    menu = {
        header = {
            house_car = "房屋車庫 %{value}",
            public_car = "公共停車場 %{value}",
            public_sea = "公共船屋 %{value}",
            public_air = "公共機庫 %{value}",
            job_car = "工作停車場 %{value}",
            job_sea = "工作船屋 %{value}",
            job_air = "工作機庫 %{value}",
            gang_car = "幫派車庫 %{value}",
            gang_sea = "幫派船屋 %{value}",
            gang_air = "幫派機庫 %{value}",
            depot_car = "車輛扣留中心 %{value}",
            depot_sea = "船隻扣留中心 %{value}",
            depot_air = "飛行扣留中心 %{value}",
            vehicles = "可用載具",
            depot = "%{value} [ $%{value2} ]",
            garage = "%{value} [ %{value2} ]",
        },
        leave = {
            car = "⬅ 離開車庫",
            sea = "⬅ 離開船屋",
            air = "⬅ 離開機庫",
        },
        text = {
            vehicles = "檢視已停泊載具!",
            depot = "車牌: %{value}<br>油量: %{value2} | 引擎: %{value3} | 車身: %{value4}",
            garage = "狀態: %{value}<br>油量: %{value2} | 引擎: %{value3} | 車身: %{value4}",
        }
    },
    status = {
        out = "已駛出",
        garaged = "已停泊",
        impound = "被警察扣押",
        parked = "泊咗喺街",
    },
    info = {
        -- garage [E] prompts
        car_e = "E - 車庫",
        sea_e = "E - 船屋",
        air_e = "E - 機庫",
        park_e = "E - 停泊",
        rig_e = "E - 大型車位",
        depot_e = "E - 扣留中心",
        house_garage = "房屋車庫",
        house = "房屋",
        -- street-parking messages
        not_the_owner = "架車唔係你㗎喎。",
        not_a_vip = "你唔係 VIP 會員。",
        wheel_clamp = "車輪鎖",
        wheel_clamp_add = "上車輪鎖",
        no_cops = "而家冇差人當值。",
        wheel_clamp_added = "架車俾人上咗鎖！罰款：$%{fine}",
        wheel_clamp_deleted = "車輪鎖已經解除。",
        street = "街道：%{street}",
        fuel = "燃油：%{fuel}",
        engine = "引擎：%{engine}",
        body = "車身：%{body}",
        click_to_set_waypoint = "㩒一下設定 GPS 導航點",
        no_waipoint = "得 %{distance} 米咋，唔使導航點掛。",
        no_vehicles_parked = "你冇車泊喺街度。",
        max_parked = "泊車數量已達上限。",
    },
    vehicle = {
        info = "車輛資料",
        body_damage = "車身損毀",
        engine_damage = "引擎狀態",
        fuel_level = "燃油",
        oil_level = "機油",
        engine_temp = "引擎溫度",
        parked = "架車泊好喇。",
        unparked = "架車已經開走。",
    },
    blip = {
        label = "泊咗：%{model}（%{plate}）",
    }
}

if GetConvar('qb_locale', 'en') == 'zh-hk' then
    Lang = Locale:new({
        phrases = Translations,
        warnOnMissing = true,
        fallbackLang = Lang,
    })
end
