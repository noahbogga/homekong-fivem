Config = {}

-- Command to open the editor
Config.Command = 'livery'

-- Target interaction (qb-target)
Config.UseTarget = true
Config.TargetDistance = 2.5

-- Canvas resolution (must be power of 2)
Config.CanvasSize = 1024

-- Max concurrent DUI objects for other players' liveries
Config.MaxDuiPool = 10

-- Preview update debounce (ms) — how often preview refreshes while drawing
Config.PreviewDebounceMs = 500

-- Camera orbit settings
Config.Camera = {
    radius = 6.0,
    height = 1.5,
    fov    = 50.0,
}

-- Max undo states in NUI
Config.MaxUndoStates = 50

-- Vehicles without livery support show this message
Config.NoLiveryMessage = 'This vehicle doesn\'t support custom liveries yet.'
