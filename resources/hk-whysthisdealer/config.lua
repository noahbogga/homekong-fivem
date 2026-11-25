Config = {}

-- Command + keybind (RegisterKeyMapping). Empty default key = command only,
-- player binds it themselves in Settings > Key Bindings > FiveM.
Config.Command      = 'whysthisdealer'
Config.CommandAlias = 'wtd'
Config.DefaultKey   = ''            -- e.g. 'B'; '' = unbound by default

-- Meme timing. The clip's groove sits around this tempo; the bounce impulse
-- fires once per beat so hops line up with the audio.
Config.BPM          = 132           -- beats per minute of the clip (tune to the track)
Config.ClipSeconds  = 130.0         -- length of whysthisdealer.mp3 (auto-stop after this)

-- Bounce is VISUAL, not physical: we oscillate the vehicle's suspension height
-- (SET_VEHICLE_SUSPENSION_HEIGHT — wheels stay planted, body bobs) on a sine
-- wave locked to the beat. This is the bouncing-Yaris look; ApplyForce just
-- slams the whole car around, so it is deliberately NOT used here.
Config.BounceHeight = 0.22          -- amplitude of the bob (suspension units; ~0.15-0.30 looks good)
Config.BounceGain   = 1.0           -- overall multiplier if you want it wilder
Config.BobsPerBeat  = 1.0           -- 1 = one bounce per beat, 2 = double-time
-- Raise the whole oscillation so the low-phase doesn't drop the body onto the
-- tyres (wheels clipping through). Negative raises. -0.08 = shift range 8% up.
Config.RideBias     = -0.08

-- Bounce SHAPE. false = smooth sine (floaty bop). true = ball-bounce: the body
-- gathers low, SNAPS up high fast, then falls back down under "gravity" and
-- squashes at the bottom before the next hop. This is the hydraulics/hop feel.
Config.BallBounce   = true
Config.HangTime     = 0.35          -- 0-0.9: how long it floats at the top (higher = more hang)

-- Audio (NUI). Volume falls off with distance to the bouncing car.
Config.HearingRange = 75.0          -- metres you can hear it from
Config.MaxVolume    = 0.9           -- 0.0 - 1.0 volume at the car itself

-- Only the driver can start it, and only while actually in a car.
Config.DriverOnly   = true
Config.CooldownMs   = 1500          -- anti-spam between toggles
