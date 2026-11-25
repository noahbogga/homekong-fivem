-- hk-race :: client/hud.lua
-- Race HUD via NUI (top-right), styled after hk-speedo's minimal panel. Native
-- DrawText can't render Chinese track names (and mixes emoji poorly); the NUI panel
-- uses a webfont stack that renders 中文 + emoji cleanly. We push a compact state
-- blob to the page ~5x/sec while racing; the page just re-renders text (cheap).

local H = RaceConfig.Hud

-- ms → M:SS.mmm (or SS.mmm under a minute). Global (used by race.lua too).
-- 2 decimals (centiseconds) — smoother to read, less churn than milliseconds.
function fmtTime(ms)
    if not ms or ms <= 0 then return '--' end
    local totalMs = math.floor(ms)
    local m = math.floor(totalMs / 60000)
    local s = math.floor((totalMs % 60000) / 1000)
    local cs = math.floor((totalMs % 1000) / 10)   -- centiseconds (00-99)
    if m > 0 then return ('%d:%02d.%02d'):format(m, s, cs) end
    return ('%d.%02d'):format(s, cs)
end

local shownLast = false

CreateThread(function()
    while true do
        local st = (RaceState and RaceState()) or nil
        if H.enabled and st then
            SendNUIMessage({
                action = 'raceHud',
                show = true,
                name = st.name or 'Race',
                cp = st.finished and st.total or st.cp,
                total = st.total,
                isLoop = st.isLoop and true or false,
                lap = st.lap or 1,
                laps = st.laps or 1,
                pos = st.pos or 1,
                racers = st.racers or 1,
                time = (st.liveLap and st.liveLap > 0 and not st.finished) and fmtTime(st.liveLap) or nil,
                best = (st.bestLap and st.bestLap > 0) and fmtTime(st.bestLap) or nil,
                legal = st.legal and true or false,
            })
            shownLast = true
            Wait(250)   -- 4 updates/sec; matches the 2-decimal readout, low churn
        else
            if shownLast then
                SendNUIMessage({ action = 'raceHud', show = false })
                shownLast = false
            end
            Wait(400)
        end
    end
end)
