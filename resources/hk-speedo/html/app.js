/**
 * hk-speedo :: app.js
 * Racing-style dual-ring SVG speedometer with glow feedback.
 * Outer ring = Speed, Inner ring = RPM, Center = Gear
 */

(function () {
    'use strict';

    // --- Constants ---
    const CX = 150, CY = 150;
    const OUTER_R = 130;       // speed ring radius
    const INNER_R = 100;       // rpm ring radius (normal cars) / EV regen meter (pure EV)
    // HYBRID layout: reuse the pure-EV split ring (regen/power) at INNER_R (100), and add
    // a NEW thin blue RPM ring INSIDE it at HY_RPM_R (clear of the R66 shift-light dots).
    const HY_RPM_R = 80;       // hybrid inner blue RPM ring radius
    const SEMI_R = 112;        // semi/KERS thin charge arc, just OUTSIDE the rpm ring (100)
    const ARC_START = 135;     // degrees (bottom-left)
    const ARC_END = 405;       // degrees (bottom-right, going clockwise = 270° sweep)
    const ARC_SWEEP = ARC_END - ARC_START; // 270°

    // DOM refs
    const container = document.getElementById('speedo-container');
    const backlightEl = document.getElementById('backlight');
    // Passenger mini speedo (separate, simple element).
    const miniRpmFill = document.getElementById('mini-rpm-fill');   // minimal-mode horizontal RPM bar
    const miniRpmThr = document.getElementById('mini-rpm-thr');     // EV throttle (right, green)
    const miniRpmBrake = document.getElementById('mini-rpm-brake'); // EV brake (left, red)
    const indRegenmode = document.getElementById('ind-regenmode'); // EV regen-mode status pill
    const indHybridmode = document.getElementById('ind-hybridmode'); // hybrid ⚡ (e-mode/ICE) pill
    const indDrivetrain = document.getElementById('ind-drivetrain'); // RWD/FWD/AWD badge
    const indLaunch = document.getElementById('ind-launch');         // launch-control pill
    const svg = document.getElementById('gauge-svg');
    const gearEl = document.getElementById('gear-display');
    const speedEl = document.getElementById('speed-value');
    const unitEl = document.getElementById('speed-unit');
    const glowEl = document.getElementById('glow-overlay');
    const redlineEl2 = document.getElementById('redline-overlay');
    const modeEl = document.getElementById('mode-overlay');
    const indTc = document.getElementById('ind-tc');
    const indAbs = document.getElementById('ind-abs');
    const indHb = document.getElementById('ind-handbrake');
    const indSeatbelt = document.getElementById('ind-seatbelt');
    const indLock = document.getElementById('ind-lock');
    const indLights = document.getElementById('ind-lights');   // headlight pill (off/low/high)
    const indBlinker = document.getElementById('ind-blinker');       // auto-blinker pill (LAlt)
    const indHandsup = document.getElementById('ind-handsup');
    const indGearmode = document.getElementById('ind-gearmode');
    const fuelFill = document.getElementById('fuel-bar-fill');
    const clutchGauge = document.getElementById('clutch-gauge');
    const clutchFill = document.getElementById('clutch-fill');
    const turboGauge = document.getElementById('turbo-gauge');
    const turboFill = document.getElementById('turbo-fill');
    const nosBlock = document.getElementById('nos-block');
    const nosBarContainer = document.getElementById('nos-bar-container');
    const nosBarFill = document.getElementById('nos-bar-fill');
    const nosIcon = document.getElementById('nos-icon');
    const nosDots = Array.prototype.slice.call(document.querySelectorAll('.nos-dot'));

    // --- SVG Helpers ---
    function polarToCart(cx, cy, r, angleDeg) {
        const rad = (angleDeg - 90) * Math.PI / 180;
        return { x: cx + r * Math.cos(rad), y: cy + r * Math.sin(rad) };
    }

    function describeArc(cx, cy, r, startAngle, endAngle) {
        // Path drawn so dashoffset reveals from the RIGHT (end) side
        const start = polarToCart(cx, cy, r, startAngle);
        const end = polarToCart(cx, cy, r, endAngle);
        const largeArc = (endAngle - startAngle) > 180 ? 1 : 0;
        return `M ${start.x} ${start.y} A ${r} ${r} 0 ${largeArc} 1 ${end.x} ${end.y}`;
    }

    // Same arc but drawn in REVERSE (sweep-flag 0), so the path STARTS at startAngle and
    // goes counter-clockwise to endAngle. Used for the EV brake half-arc so it originates
    // at the mid and reveals leftward with the same positive-dashoffset math.
    function describeArcReverse(cx, cy, r, startAngle, endAngle) {
        const start = polarToCart(cx, cy, r, startAngle);
        const end = polarToCart(cx, cy, r, endAngle);
        const largeArc = (startAngle - endAngle) > 180 ? 1 : 0;
        return `M ${start.x} ${start.y} A ${r} ${r} 0 ${largeArc} 0 ${end.x} ${end.y}`;
    }

    function getArcLength(r, sweepDeg) {
        return 2 * Math.PI * r * (sweepDeg / 360);
    }

    // --- Build gauge SVG elements ---
    function buildGauge() {
        const ns = 'http://www.w3.org/2000/svg';

        // Remove placeholder
        const placeholder = svg.querySelector('#gauge-rings');
        if (placeholder) placeholder.remove();

        // Outer track (speed background)
        const outerTrack = document.createElementNS(ns, 'path');
        outerTrack.setAttribute('d', describeArc(CX, CY, OUTER_R, ARC_START, ARC_END));
        outerTrack.setAttribute('class', 'arc-track arc-track-outer');
        svg.appendChild(outerTrack);

        // Inner track (RPM background)
        const innerTrack = document.createElementNS(ns, 'path');
        innerTrack.setAttribute('d', describeArc(CX, CY, INNER_R, ARC_START, ARC_END));
        innerTrack.setAttribute('class', 'arc-track arc-track-inner');
        svg.appendChild(innerTrack);

        // Redline zone on RPM (last 15% of arc)
        const redStart = ARC_START + ARC_SWEEP * 0.85;
        const redTrack = document.createElementNS(ns, 'path');
        redTrack.setAttribute('d', describeArc(CX, CY, INNER_R, redStart, ARC_END));
        redTrack.setAttribute('class', 'redline-zone');
        svg.appendChild(redTrack);

        // START CAP for the speed bar = a SEMICIRCLE (D-shape), not a full circle.
        // A full circle centred on the 0 mark bulges half a stroke-width FORWARD past
        // the 0 line into the fill — that lump is the "weird rounded end when
        // accelerating". Instead we draw a half-disc whose flat edge sits exactly on
        // the 0 line and whose round side points BACK into the gap (before 0). The
        // fill (butt-capped) then cuts off sharply at 0 and meets the flat edge
        // seamlessly. Diameter spans the stroke width across the 0 radial; radius =
        // half the stroke-width. Path precomputed from the arc geometry.
        const capHW = 19.6 / 2;
        const capIn = polarToCart(CX, CY, OUTER_R - capHW, ARC_START);   // inner edge @ 0
        const capOut = polarToCart(CX, CY, OUTER_R + capHW, ARC_START);  // outer edge @ 0
        const speedCap = document.createElementNS(ns, 'path');
        // sweep 1 = bulge backwards (into the gap, BEFORE the 0 line). sweep 0 put the
        // round side forward past 0 (wrong side). The flat edge stays on the 0 line.
        speedCap.setAttribute('d',
            `M ${capIn.x} ${capIn.y} A ${capHW} ${capHW} 0 0 1 ${capOut.x} ${capOut.y} Z`);
        speedCap.setAttribute('class', 'arc-speed-cap');
        speedCap.id = 'arc-speed-cap';
        svg.appendChild(speedCap);

        const speedLen = getArcLength(OUTER_R, ARC_SWEEP);

        // Speed GLOW HALO — a fatter, translucent twin of the speed arc drawn UNDER it,
        // driven by the SAME dashoffset so the glow follows the lit tip. NO filter: a wide
        // stroked path is GPU-composited, unlike a drop-shadow blur which CEF re-rasterizes
        // every frame (that per-frame blur on a moving arc was the big FPS cost). Used in
        // NORMAL mode; FULL mode hides it + uses the live filter instead (CSS-gated).
        const speedHalo = document.createElementNS(ns, 'path');
        speedHalo.setAttribute('d', describeArc(CX, CY, OUTER_R, ARC_START, ARC_END));
        speedHalo.setAttribute('class', 'arc-active arc-speed-halo');
        speedHalo.id = 'arc-speed-halo';
        speedHalo.style.strokeDasharray = speedLen;
        speedHalo.style.strokeDashoffset = speedLen;
        svg.appendChild(speedHalo);
        arcSpeedHaloEl = speedHalo;

        // Speed active arc
        const speedArc = document.createElementNS(ns, 'path');
        speedArc.setAttribute('d', describeArc(CX, CY, OUTER_R, ARC_START, ARC_END));
        speedArc.setAttribute('class', 'arc-active arc-speed');
        speedArc.id = 'arc-speed';
        speedArc.style.strokeDasharray = speedLen;
        speedArc.style.strokeDashoffset = speedLen; // fully hidden
        svg.appendChild(speedArc);
        arcSpeedEl = speedArc;   // cache for the per-frame updateGauge

        // RPM active arc — a single gradient path revealed by dashoffset (see
        // buildRpmSegments; the old masked 90-segment version was a CEF perf sink).
        buildRpmSegments(ns);

        // HYBRID inner RPM ring (hidden unless .hybrid). The regen/power meter reuses the
        // pure-EV split ring; this only adds a thin blue RPM ring at HY_RPM_R inside it.
        buildHybridRings(ns);

        // Speed ticks are dynamic — built by rebuildSpeedTicks() when maxSpeed changes
        rebuildSpeedTicks(360);

        // Ticks for RPM: major every 1000, minor every 500
        for (let i = 0; i <= 18; i++) {
            const rpmVal = i * 500;
            const angle = ARC_START + (ARC_SWEEP * (i / 18));
            const isMajor = (rpmVal % 1000 === 0);

            const tickLen = isMajor ? 7 : 4;
            const strokeW = isMajor ? 1.6 : 0.9;
            const opacity = isMajor ? 0.5 : 0.3;

            const inner = polarToCart(CX, CY, INNER_R - tickLen, angle);
            const outer = polarToCart(CX, CY, INNER_R + 2, angle);
            const tick = document.createElementNS(ns, 'line');
            tick.setAttribute('x1', inner.x);
            tick.setAttribute('y1', inner.y);
            tick.setAttribute('x2', outer.x);
            tick.setAttribute('y2', outer.y);
            tick.setAttribute('class', 'tick-mark');
            tick.style.opacity = opacity;
            tick.style.strokeWidth = strokeW;
            svg.appendChild(tick);
        }
    }

    // --- Dynamic speed ticks (rebuilt when vehicle maxSpeed changes) ---
    let currentGaugeMax = 360;
    let speedTickEls = [];

    // Pick a major-tick step that divides maxSpeed evenly (so the max is always
    // labelled) and yields ~5-7 major ticks. Falls back to the closest clean step.
    function pickMajorStep(maxSpeed) {
        const candidates = [20, 25, 30, 40, 50, 60, 80, 100];
        let best = candidates[0], bestScore = Infinity;
        for (const step of candidates) {
            if (maxSpeed % step !== 0) continue;      // must divide evenly
            const count = maxSpeed / step;            // number of major ticks
            const score = Math.abs(count - 6);        // aim for ~6 majors
            if (score < bestScore) { bestScore = score; best = step; }
        }
        if (bestScore === Infinity) {                 // nothing divides evenly
            best = Math.max(20, Math.round(maxSpeed / 6 / 10) * 10);
        }
        return best;
    }

    function rebuildSpeedTicks(maxSpeed) {
        const ns = 'http://www.w3.org/2000/svg';
        // Remove old speed ticks
        speedTickEls.forEach(el => el.remove());
        speedTickEls = [];
        currentGaugeMax = maxSpeed;

        const majorStep = pickMajorStep(maxSpeed);
        // Finer minor ticks for a clearer scale: aim for ~10 minors per major (falls
        // back to /8 or /5 so the step stays a clean divisor). mediumStep is the
        // half-major mark. More small lines = easier to read speed between numbers.
        let minorStep;
        if (majorStep % 10 === 0)      minorStep = majorStep / 10;   // e.g. 40 -> every 4
        else if (majorStep % 8 === 0)  minorStep = majorStep / 8;
        else if (majorStep % 5 === 0)  minorStep = majorStep / 5;    // e.g. 25 -> every 5
        else                            minorStep = majorStep / 4;
        const mediumStep = majorStep / 2;

        const totalTicks = Math.round(maxSpeed / minorStep);
        for (let i = 0; i <= totalTicks; i++) {
            const speedVal = i * minorStep;
            const angle = ARC_START + (ARC_SWEEP * (speedVal / maxSpeed));
            const isMajor = (Math.abs(speedVal % majorStep) < 0.001);
            const isMedium = (!isMajor && Math.abs(speedVal % mediumStep) < 0.001);

            // Brighter across the board for daytime visibility (was 0.7/0.45/0.25).
            let tickLen, strokeW, opacity;
            if (isMajor) { tickLen = 11; strokeW = 2.4; opacity = 0.95; }
            else if (isMedium) { tickLen = 7; strokeW = 1.7; opacity = 0.7; }
            else { tickLen = 4.5; strokeW = 1.1; opacity = 0.5; }

            const inner = polarToCart(CX, CY, OUTER_R - tickLen, angle);
            const outer = polarToCart(CX, CY, OUTER_R + 2, angle);
            const tick = document.createElementNS(ns, 'line');
            tick.setAttribute('x1', inner.x);
            tick.setAttribute('y1', inner.y);
            tick.setAttribute('x2', outer.x);
            tick.setAttribute('y2', outer.y);
            tick.setAttribute('class', isMajor ? 'tick-mark tick-major' : 'tick-mark');
            tick.style.opacity = opacity;
            tick.style.strokeWidth = strokeW;
            svg.appendChild(tick);
            speedTickEls.push(tick);

            // Label only on major ticks
            if (isMajor) {
                // Pushed out to +17 and rotated -90° (anticlockwise) to counter the
                // SVG's 90° CW CSS rotation so numbers read upright.
                const labelPos = polarToCart(CX, CY, OUTER_R + 17, angle);
                const label = document.createElementNS(ns, 'text');
                label.setAttribute('x', labelPos.x);
                label.setAttribute('y', labelPos.y);
                label.setAttribute('class', 'tick-label');
                label.setAttribute('transform', `rotate(-90, ${labelPos.x}, ${labelPos.y})`);
                label.textContent = Math.round(speedVal).toString();
                svg.appendChild(label);
                speedTickEls.push(label);
            }
        }

        // Faint END-OF-SCALE line: a very transparent radial stroke at the arc's end,
        // running from the ring out to the unit label — visually "closes" the scale and
        // points at the KMH/MPH caption. Sits behind the label (appended before it).
        const endAngle = ARC_END;
        const extInner = polarToCart(CX, CY, OUTER_R - 10, endAngle);
        const extOuter = polarToCart(CX, CY, OUTER_R + 24, endAngle);
        const extLine = document.createElementNS(ns, 'line');
        extLine.setAttribute('x1', extInner.x);
        extLine.setAttribute('y1', extInner.y);
        extLine.setAttribute('x2', extOuter.x);
        extLine.setAttribute('y2', extOuter.y);
        extLine.setAttribute('class', 'scale-end-line');
        svg.appendChild(extLine);
        speedTickEls.push(extLine);

        // Unit label ("KM/H" / "MPH") at the END of the speed arc, just past the max
        // numeral — real single-scale dials put the unit near the top-end number.
        const unitPos = polarToCart(CX, CY, OUTER_R + 30, endAngle);
        const unit = document.createElementNS(ns, 'text');
        unit.setAttribute('x', unitPos.x);
        unit.setAttribute('y', unitPos.y);
        unit.setAttribute('class', 'tick-label unit-label');
        unit.setAttribute('transform', `rotate(-90, ${unitPos.x}, ${unitPos.y})`);
        unit.textContent = state.unit || 'KM/H';
        svg.appendChild(unit);
        speedTickEls.push(unit);
    }

    // --- State ---
    let state = {
        speed: 0, rpm: 0, gear: 0, maxSpeed: 360, maxRpm: 9000,
        nosState: 'off', drift: false, tcOff: false, absOff: false, handbrake: false,
        blinker: false,
        seatbelt: true, harness: false, fuel: 100, unit: 'KM/H', locked: false, handsup: false,
        lights: 0,   // headlights: 0 off, 1 low beam, 2 high beam

        theme: 'eco', redline: 0.85, electric: false, throttle: 0, brake: 0, gearMode: 'A',
        drivetrain: null,
        hybrid: false, electricNow: false, singleGear: false, indIcon: null, indColor: null, gearLabel: null,
        regen: 0, friction: 0, braking: false,
        regenMode: null, regenHolding: false,
        lc: 'off',   // launch-control render state: 'off'|'idle'|'prep'|'armed'|'boost'
        // CLUTCH gauge (manual only): clutchManual gates visibility, clutch = engagement 0..1.
        clutchManual: false, clutch: 1,
        // TURBO gauge (turbo cars only): turboActive gates visibility, turboSpool = boost 0..1,
        // turboHit = punch intensity 0..1 (flashes the fill white as boost slams online).
        turboActive: false, turboSpool: 0, turboHit: 0,
        // SEMI / KERS hybrid: keeps its normal tach, adds a thin charge arc alongside it.
        semi: false, semiCharge: 0, semiBoost: 0,
        // Semi-LOOK full PHEV in e-mode: throttle-driven green tach bar (no revs).
        emodeBar: false, emodeThr: 0,

        hasNos: false, nosAmount: 0, nosBoostLevel: 1, nosPurge: false, nosColor: null,
        nosOverheat: false
    };
    let glowTimeout = null;
    let selfTestActive = false;  // true while the ignition self-test sweep runs
    let exitToken = 0;           // bumped on each show/hide to cancel a stale exit-hide
    let lastEmode = null;        // last hybrid e-mode state — fires the mode-change sweep
    let modeSweepActive = false; // true while the EV<->ICE mode-change sweep runs
    let lastEmodeBar = false;    // last semi-look PHEV emode-bar state — fires the mode-flip crossfade
    let modeFlipTimer = null;    // setTimeout handle that clears .mode-flip after the crossfade
    // Display mode: 'normal' | 'full' | 'lite' | 'minimal' (set by the 'mode' message).
    //   normal  -> DEFAULT. full look, cheap glow halos (no per-frame blur)
    //   full    -> live per-arc drop-shadow filters (max quality, expensive)
    //   lite    -> no vibration/glow paint (CSS .lite hides glow layers)
    //   minimal -> hide the cluster entirely, drive the mini rectangle from the tick
    let dispMode = 'normal';

    // --- Drive-mode theming ---
    // eco  = calm blue/teal accent (automatic / DCT-auto)
    // sport = aggressive red/orange accent (manual / sequential / DCT-paddle)
    let themeSeen = false;   // false until the first theme sync after HUD show
    let lastGearMode = null; // last A/M shown — used to fire the change pulse
    function applyTheme(theme) {
        container.classList.toggle('theme-sport', theme === 'sport');
        container.classList.toggle('theme-eco', theme !== 'sport');
    }

    // Soft inner-ring bloom on a drive-mode switch (auto/eco <-> manual/sport).
    // Restart the animation by clearing the class + forcing a reflow first.
    function pulseModeChange(theme) {
        if (!modeEl) return;
        const cls = (theme === 'sport') ? 'pulse-sport' : 'pulse-eco';
        modeEl.classList.remove('pulse-sport', 'pulse-eco');
        void modeEl.offsetWidth;   // reflow so the animation replays even if same class
        modeEl.classList.add(cls);
    }

    // --- Speed needle smoothing ---
    // The raw speed is fed straight from the game, so a quick throttle blip made the
    // arc POP up and snap back down. Ease a displayed value toward the real speed each
    // frame (same idea as RPM's smoothRpm) so the fill glides in and out. Asymmetric:
    // rises a touch quicker than it falls, so it feels responsive but coasts down soft.
    let smoothSpeed = 0;
    let lastSpeedOffset = -1, lastRpmOffset = -1;  // dirty-flag: skip identical dashoffset writes
    const SPEED_LERP_UP = 0.18;    // how fast the fill catches up when accelerating
    const SPEED_LERP_DOWN = 0.10;  // slower on release = smooth glide back down
    // EV throttle bar: eased toward the raw throttle so slamming the pedal ramps up
    // quickly-but-smoothly (like a real EV building torque), not an instant jump.
    let smoothThrottle = 0, smoothBrake = 0, smoothFriction = 0;
    const THROTTLE_LERP_UP = 0.12;    // rise rate (lower = more gradual build)
    const THROTTLE_LERP_DOWN = 0.20;  // release a bit quicker
    let smoothSemiCharge = 0, smoothSemiBoost = 0;   // semi/KERS charge-arc EMAs (JS-side glide)
    let smoothEmodeThr = 0;                          // semi-look PHEV e-mode tach bar (throttle) EMA
    // The emode throttle bar sweeps the WHOLE tach arc, so the shared throttle lerps (tuned
    // for the short EV split-ring + semi charge arc) read as a jumpy needle here. Give it its
    // own, gentler rates so the bar builds/eases smoothly like a real tach sweep.
    const EMODE_LERP_UP = 0.022;   // rise (lower = slower build)
    const EMODE_LERP_DOWN = 0.05;  // release, a touch quicker than the build

    // --- RPM bounce on gear change ---
    // Simulates the real needle bounce: overshoot then settle
    let lastGear = 0;
    let rpmBounce = 0;        // current bounce offset (added to RPM display)
    let rpmBounceVel = 0;     // velocity of bounce spring
    const BOUNCE_DAMPING = 0.72;   // how fast bounce settles (lower = faster settle)
    const BOUNCE_STIFFNESS = 0.25; // spring pull-back strength
    const UPSHIFT_KICK = -0.08;    // negative = needle drops then bounces up
    const DOWNSHIFT_KICK = 0.10;   // positive = needle jumps then settles down

    function tickBounce() {
        // Spring physics: accelerate toward 0, with damping
        rpmBounceVel += (-rpmBounce * BOUNCE_STIFFNESS);
        rpmBounceVel *= BOUNCE_DAMPING;
        rpmBounce += rpmBounceVel;
        // Kill tiny residual
        if (Math.abs(rpmBounce) < 0.001 && Math.abs(rpmBounceVel) < 0.001) {
            rpmBounce = 0;
            rpmBounceVel = 0;
        }
    }

    // --- Engine vibration / needle flutter ---
    // A real analog needle is never still: it quivers at idle, flutters harder under
    // load and near redline. Model as a lightly-damped spring that gets a small RANDOM
    // kick every frame (organic flutter, not digital white-noise). Amplitude scales
    // with rpm level + how fast the value is changing (throttle stabs / gear load).
    let rpmVib = 0, rpmVibVel = 0, prevRpmPct = 0;
    let speedVib = 0, speedVibVel = 0, prevSpeedPct = 0;
    const VIB_STIFF = 0.45;   // pull back toward centre
    const VIB_DAMP = 0.58;    // settle rate (lower = jitterier)

    function tickVibration(rpmPct, speedPct) {
        // RPM: idle baseline (only when the engine's actually spinning) + more with
        // rpm + a burst proportional to how fast rpm is moving.
        const rpmChange = Math.abs(rpmPct - prevRpmPct);
        prevRpmPct = rpmPct;
        const alive = rpmPct > 0.05 ? 1 : 0;
        // Amplitude cut to ~1/3 (down 2/3) — the rpm bar was bobbing too much.
        const rpmAmp = alive * (0.0023 + rpmPct * 0.0043) + rpmChange * 0.28;
        rpmVibVel += (Math.random() - 0.5) * rpmAmp - rpmVib * VIB_STIFF;
        rpmVibVel *= VIB_DAMP;
        rpmVib += rpmVibVel;

        // Speed: much subtler — mostly from acceleration (road/engine buzz).
        const speedChange = Math.abs(speedPct - prevSpeedPct);
        prevSpeedPct = speedPct;
        const speedAmp = 0.0015 + speedChange * 0.4;
        speedVibVel += (Math.random() - 0.5) * speedAmp - speedVib * VIB_STIFF;
        speedVibVel *= VIB_DAMP;
        speedVib += speedVibVel;
    }

    // --- RPM bar colour along its length ---
    // The bar is a true positional gradient: base is blue, ramping through green,
    // yellow and orange, to red at the redline. Colour depends on WHERE along the
    // arc a segment sits (pos 0..1), not on total RPM — so a half-filled bar is
    // blue/green and only the top segments near redline are yellow/orange/red.
    const REDLINE_START = 0.85; // matches the 15% redline zone drawn on the track
    function lerpRGB(a, b, t) {
        return [
            Math.round(a[0] + (b[0] - a[0]) * t),
            Math.round(a[1] + (b[1] - a[1]) * t),
            Math.round(a[2] + (b[2] - a[2]) * t),
        ];
    }
    // Colour stops keyed by position along the arc (0 = base, 1 = redline top).
    const RPM_STOPS = [
        { p: 0.00, c: [0x33, 0x99, 0xff] }, // blue
        { p: 0.55, c: [0x33, 0xdd, 0xcc] }, // teal/green
        { p: 0.72, c: [0x66, 0xdd, 0x44] }, // green
        { p: 0.85, c: [0xff, 0xdd, 0x22] }, // yellow (redline zone begins)
        { p: 0.93, c: [0xff, 0x88, 0x22] }, // orange
        { p: 1.00, c: [0xff, 0x22, 0x22] }, // red
    ];
    function rpmColor(pos) {
        pos = Math.max(0, Math.min(1, pos));
        for (let i = 1; i < RPM_STOPS.length; i++) {
            if (pos <= RPM_STOPS[i].p) {
                const a = RPM_STOPS[i - 1], b = RPM_STOPS[i];
                const t = (pos - a.p) / (b.p - a.p);
                const rgb = lerpRGB(a.c, b.c, t);
                return `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
            }
        }
        const last = RPM_STOPS[RPM_STOPS.length - 1].c;
        return `rgb(${last[0]}, ${last[1]}, ${last[2]})`;
    }

    // RPM bar — a SINGLE gradient <path> revealed by stroke-dashoffset, exactly like
    // the speed bar. PERF: this replaces the old approach (a 90-segment group masked
    // by an animated SVG <mask>). SVG masks + 90 nodes are brutally slow in CEF and
    // were re-composited every frame; one dashoffset'd path is GPU-cheap. The colour
    // along the bar comes from #rpm-gradient (blue -> ... -> red at redline).
    let rpmMaskArc = null;   // name kept — it's the element updateGauge animates
    let arcSpeedEl = null;   // cached per-frame refs (avoid getElementById each frame)
    let arcSpeedHaloEl = null, rpmHaloArc = null;   // NORMAL-mode glow halos (twin arcs)
    let shiftLightsGroup = null;
    let rpmEvThrArc = null, rpmEvBrakeArc = null, rpmEvFrictionArc = null, rpmEvHalfLen = 0;  // EV split ring arcs
    let semiArc = null, semiArcLen = 0;   // SEMI/KERS thin charge arc (rides the normal tach)
    const rpmMaskLen = getArcLength(INNER_R, ARC_SWEEP);
    function buildRpmSegments(ns) {
        const SVGNS = ns;

        // Remove any old fill/mask/segments from a previous build.
        const oldMask = svg.querySelector('#rpm-mask');
        if (oldMask) oldMask.remove();
        const oldGroup = svg.querySelector('#rpm-fill');
        if (oldGroup) oldGroup.remove();

        // RPM GLOW HALO — fatter translucent twin under the fill, same dashoffset (set
        // alongside rpm-fill in updateGauge). NO filter (GPU-composited, cheap). NORMAL
        // mode only; FULL uses the live drop-shadow instead (CSS-gated).
        const oldRpmHalo = svg.querySelector('#rpm-halo');
        if (oldRpmHalo) oldRpmHalo.remove();
        const rpmHalo = document.createElementNS(SVGNS, 'path');
        rpmHalo.setAttribute('d', describeArc(CX, CY, INNER_R, ARC_START, ARC_END));
        rpmHalo.setAttribute('class', 'arc-active arc-rpm-halo');
        rpmHalo.id = 'rpm-halo';
        rpmHalo.style.strokeDasharray = rpmMaskLen;
        rpmHalo.style.strokeDashoffset = rpmMaskLen;
        svg.appendChild(rpmHalo);
        rpmHaloArc = rpmHalo;

        // Single RPM fill arc (gradient stroke, dashoffset reveal).
        const rpmArc = document.createElementNS(SVGNS, 'path');
        rpmArc.setAttribute('d', describeArc(CX, CY, INNER_R, ARC_START, ARC_END));
        rpmArc.setAttribute('class', 'arc-active arc-rpm');
        rpmArc.id = 'rpm-fill';
        rpmArc.style.strokeDasharray = rpmMaskLen;
        rpmArc.style.strokeDashoffset = rpmMaskLen;   // fully hidden at start
        svg.appendChild(rpmArc);
        rpmMaskArc = rpmArc;   // updateGauge drives its strokeDashoffset

        // ROUND START CAP at 0 rpm — solid circle, base (blue) colour, under the fill.
        const oldRpmCap = svg.querySelector('#rpm-cap');
        if (oldRpmCap) oldRpmCap.remove();
        const rpmStartPt = polarToCart(CX, CY, INNER_R, ARC_START);
        const rpmCap = document.createElementNS(SVGNS, 'circle');
        rpmCap.setAttribute('cx', rpmStartPt.x);
        rpmCap.setAttribute('cy', rpmStartPt.y);
        rpmCap.setAttribute('r', 10.08 / 2);
        rpmCap.setAttribute('class', 'arc-rpm-cap');
        rpmCap.id = 'rpm-cap';
        rpmCap.style.fill = rpmColor(0);
        svg.insertBefore(rpmCap, rpmArc);   // under the fill

        // EV CENTER-SPLIT arcs (full mode): the RPM ring becomes a power meter split at
        // the arc's MIDPOINT (top / 12 o'clock). Throttle fills mid->END clockwise
        // (green, right side); brake fills mid->START counter-clockwise (red, left side).
        // Two half-arcs, each revealed from the middle by its own dashoffset. Hidden by
        // default; shown only for EVs (CSS .ev). updated in updateGauge.
        const oldThr = svg.querySelector('#rpm-ev-thr');   if (oldThr) oldThr.remove();
        const oldBrk = svg.querySelector('#rpm-ev-brake'); if (oldBrk) oldBrk.remove();
        const oldFri = svg.querySelector('#rpm-ev-friction'); if (oldFri) oldFri.remove();
        const MID = ARC_START + ARC_SWEEP / 2;
        rpmEvHalfLen = getArcLength(INNER_R, ARC_SWEEP / 2);

        // Throttle: mid -> end (drawn from mid forward; dashoffset hides from the mid end).
        rpmEvThrArc = document.createElementNS(SVGNS, 'path');
        rpmEvThrArc.setAttribute('d', describeArc(CX, CY, INNER_R, MID, ARC_END));
        rpmEvThrArc.setAttribute('class', 'arc-active arc-rpm-ev-thr');
        rpmEvThrArc.id = 'rpm-ev-thr';
        rpmEvThrArc.style.strokeDasharray = rpmEvHalfLen;
        rpmEvThrArc.style.strokeDashoffset = rpmEvHalfLen;   // hidden (reveals from mid)
        svg.appendChild(rpmEvThrArc);

        // Brake: drawn MID -> START (reversed) so it ALSO originates at the mid and
        // reveals leftward with the same positive-offset math as the throttle arc.
        rpmEvBrakeArc = document.createElementNS(SVGNS, 'path');
        rpmEvBrakeArc.setAttribute('d', describeArcReverse(CX, CY, INNER_R, MID, ARC_START));
        rpmEvBrakeArc.setAttribute('class', 'arc-active arc-rpm-ev-brake');
        rpmEvBrakeArc.id = 'rpm-ev-brake';
        rpmEvBrakeArc.style.strokeDasharray = rpmEvHalfLen;
        rpmEvBrakeArc.style.strokeDashoffset = rpmEvHalfLen;   // hidden (reveals from mid)
        svg.appendChild(rpmEvBrakeArc);

        // FRICTION overlay: identical geometry to the brake/regen arc, drawn AFTER it so it
        // sits ON TOP. This is the translucent GREY band that extends over the green regen
        // when the brake PEDAL is pressed (regen + friction are independent layers now —
        // the grey no longer replaces the green). Driven by smoothFriction in updateGauge.
        rpmEvFrictionArc = document.createElementNS(SVGNS, 'path');
        rpmEvFrictionArc.setAttribute('d', describeArcReverse(CX, CY, INNER_R, MID, ARC_START));
        rpmEvFrictionArc.setAttribute('class', 'arc-active arc-rpm-ev-friction');
        rpmEvFrictionArc.id = 'rpm-ev-friction';
        rpmEvFrictionArc.style.strokeDasharray = rpmEvHalfLen;
        rpmEvFrictionArc.style.strokeDashoffset = rpmEvHalfLen;   // hidden (reveals from mid)
        svg.appendChild(rpmEvFrictionArc);

        // SEMI / KERS CHARGE ARC — a thin arc hugging the rpm ring, drawn just OUTSIDE it
        // (SEMI_R) so it reads alongside the revs without touching them. A semi is an ICE
        // car (keeps its tach + gears), so this is the ONLY e-motor readout: it fills from
        // the base (ARC_START) and swaps colour — GREEN while charging (regen on lift),
        // AMBER while boosting (e-assist on throttle). Hidden unless .semi (set in updateGauge).
        const oldSemi = svg.querySelector('#semi-arc'); if (oldSemi) oldSemi.remove();
        semiArcLen = getArcLength(SEMI_R, ARC_SWEEP);
        semiArc = document.createElementNS(SVGNS, 'path');
        semiArc.setAttribute('d', describeArc(CX, CY, SEMI_R, ARC_START, ARC_END));
        semiArc.setAttribute('class', 'arc-active arc-semi');
        semiArc.id = 'semi-arc';
        semiArc.style.strokeDasharray = semiArcLen;
        semiArc.style.strokeDashoffset = semiArcLen;   // hidden (reveals from base)
        svg.appendChild(semiArc);

        buildShiftLights(SVGNS);
    }

    // --- Hybrid inner RPM ring (built once, shown only when .hybrid) ---
    // The hybrid REGEN/power meter REUSES the pure-EV split ring (arc-rpm-ev-*), so it
    // looks exactly like a pure EV (no separate arcs, no redline glitch). All we add for
    // a hybrid is a NEW inner blue RPM ring (track + fill + its own redline zone),
    // sitting inside the EV meter. Hidden by CSS unless .hybrid; driven in updateGauge.
    let hyRpmArc = null, hyRpmLen = 0;
    function buildHybridRings(ns) {
        ['#hy-rpm', '#hy-rpm-track', '#hy-rpm-redline'].forEach(function (sel) {
            const o = svg.querySelector(sel); if (o) o.remove();
        });
        hyRpmLen = getArcLength(HY_RPM_R, ARC_SWEEP);

        // Background track (full sweep).
        const rpmTrack = document.createElementNS(ns, 'path');
        rpmTrack.setAttribute('d', describeArc(CX, CY, HY_RPM_R, ARC_START, ARC_END));
        rpmTrack.setAttribute('class', 'arc-track hy-rpm-track');
        rpmTrack.id = 'hy-rpm-track';
        svg.appendChild(rpmTrack);

        // REDLINE zone on the inner ring (last 15%), like the normal RPM ring has.
        const redStart = ARC_START + ARC_SWEEP * 0.85;
        const rpmRed = document.createElementNS(ns, 'path');
        rpmRed.setAttribute('d', describeArc(CX, CY, HY_RPM_R, redStart, ARC_END));
        rpmRed.setAttribute('class', 'hy-rpm-redline');
        rpmRed.id = 'hy-rpm-redline';
        svg.appendChild(rpmRed);

        // Blue RPM fill (dashoffset reveal).
        hyRpmArc = document.createElementNS(ns, 'path');
        hyRpmArc.setAttribute('d', describeArc(CX, CY, HY_RPM_R, ARC_START, ARC_END));
        hyRpmArc.setAttribute('class', 'arc-active hy-rpm');
        hyRpmArc.id = 'hy-rpm';
        hyRpmArc.style.strokeDasharray = hyRpmLen;
        hyRpmArc.style.strokeDashoffset = hyRpmLen;
        svg.appendChild(hyRpmArc);
    }

    // --- Sequential shift-light bar ---
    // A row of LED dots across the TOP of the gauge (12 o'clock, which after the
    // 90deg CSS rotation is where the arc's high-rpm region reads). Fills L->R
    // green -> yellow -> red as RPM climbs; the whole bar strobes at the limiter.
    const SHIFT_LIGHTS = 9;
    let shiftLightEls = [];
    function buildShiftLights(ns) {
        const old = svg.querySelector('#shift-lights');
        if (old) old.remove();
        shiftLightEls = [];
        const g = document.createElementNS(ns, 'g');
        g.id = 'shift-lights';
        // Lay the dots on a shallow arc across the top of the dial. In SVG space
        // (before the 90deg CSS rotation) "top" spans around angle 0; we place them
        // symmetrically from -40deg to +40deg at a radius just inside the rings.
        const R = 66;
        const spread = 80; // total degrees
        for (let i = 0; i < SHIFT_LIGHTS; i++) {
            const frac = SHIFT_LIGHTS === 1 ? 0.5 : i / (SHIFT_LIGHTS - 1);
            const ang = -spread / 2 + spread * frac;
            const p = polarToCart(CX, CY, R, ang);
            const dot = document.createElementNS(ns, 'circle');
            dot.setAttribute('cx', p.x);
            dot.setAttribute('cy', p.y);
            dot.setAttribute('r', 3);
            dot.setAttribute('class', 'shift-light');
            // colour by position: first third green, middle yellow, last red
            let col;
            if (frac < 0.45) col = '#33dd55';
            else if (frac < 0.78) col = '#ffcc22';
            else col = '#ff2a2a';
            dot.style.setProperty('--lit', col);
            g.appendChild(dot);
            shiftLightEls.push(dot);
        }
        svg.appendChild(g);
        shiftLightsGroup = g;   // cache for per-frame updateShiftLights
    }

    // Dirty-flag cache: only touch the DOM when the lit count or limiter state actually
    // changes (was toggling 9 classes + a querySelector EVERY frame regardless).
    let lastLitCount = -1, lastAtLimit = null;
    function updateShiftLights(rpmPct) {
        if (!shiftLightEls.length) return;
        // Lights begin arming a bit before the redline zone and are all lit at max.
        const start = (state.redline || 0.85) - 0.10; // start ~10% before redline
        const t = Math.max(0, Math.min(1, (rpmPct - start) / (1 - start)));
        const litCount = Math.round(t * SHIFT_LIGHTS);
        const atLimit = rpmPct >= (state.redline || 0.85) + 0.10 || rpmPct >= 0.98;
        if (litCount === lastLitCount && atLimit === lastAtLimit) return; // no change
        lastLitCount = litCount;
        lastAtLimit = atLimit;
        for (let i = 0; i < SHIFT_LIGHTS; i++) {
            shiftLightEls[i].classList.toggle('lit', !atLimit && i < litCount);
        }
        // Strobe: at the limiter, flash ALL lights on/off together (cached group).
        if (shiftLightsGroup) shiftLightsGroup.classList.toggle('strobe', atLimit);
    }

    // --- Gear display with sliding transition ---
    // `text` is a plain label ('D','R','N','1'…, or EV regen 'D1'/'D2'/'D3'). For the EV
    // regen labels we render the DIGIT as a subscript (D with a small low 1/2/3). The
    // element's dataset.g holds the plain label so change-detection stays string-based.
    let lastGearShown = null;      // gear VALUE currently shown (-1/0/1..n)
    let lastEvGear = false;        // last EV gear-display state (white + green glow)
    let lastSingleGear = false;    // last comfort-auto gear-display state (white + blue glow)
    let curGearNum = gearEl.querySelector('.gear-num');
    function gearRender(el, text) {
        el.dataset.g = text;
        const m = /^D([123])$/.exec(text);
        if (m) el.innerHTML = 'D<sub>' + m[1] + '</sub>';
        else el.textContent = text;
    }
    function updateGearDisplay(text, gearVal) {
        if (lastGearShown === null) {
            if (curGearNum) gearRender(curGearNum, text);   // first paint: no animation
            lastGearShown = gearVal;
            return;
        }
        // Compare by the plain label stored in dataset.g (not textContent, which may hold
        // the subscript markup). Gear value can stay the same while the label flips
        // (e.g. D -> D1, or EV->normal both in gear 1), so key on the label too.
        const shownText = curGearNum ? (curGearNum.dataset.g || curGearNum.textContent) : null;
        if (gearVal === lastGearShown && shownText === text) return;
        if (shownText === text) { lastGearShown = gearVal; return; }

        // Minimal mode: no slide — swap in place.
        if (dispMode === 'minimal') {
            if (curGearNum) gearRender(curGearNum, text);
            lastGearShown = gearVal;
            return;
        }

        const goingUp = gearVal > lastGearShown; // upshift vs downshift
        const oldEl = curGearNum;
        const newEl = document.createElement('span');
        newEl.className = 'gear-num ' + (goingUp ? 'in-right' : 'in-left');
        gearRender(newEl, text);
        gearEl.appendChild(newEl);

        if (oldEl) {
            oldEl.classList.remove('in-right', 'in-left');
            oldEl.classList.add(goingUp ? 'out-left' : 'out-right');
            const toRemove = oldEl;
            setTimeout(() => { if (toRemove.parentNode) toRemove.parentNode.removeChild(toRemove); }, 340);
        }
        curGearNum = newEl;
        lastGearShown = gearVal;
    }

    // --- Update display ---
    const speedArcLen = getArcLength(OUTER_R, ARC_SWEEP);
    const rpmArcLen = getArcLength(INNER_R, ARC_SWEEP);

    function updateGauge() {
        // Detect gear change and trigger bounce
        if (state.gear !== lastGear && state.gear !== 0 && lastGear !== 0) {
            if (state.gear > lastGear) {
                // Upshift: needle drops then bounces back
                rpmBounceVel = UPSHIFT_KICK;
            } else {
                // Downshift: needle jumps then settles
                rpmBounceVel = DOWNSHIFT_KICK;
            }
        }
        lastGear = state.gear;

        // Tick the bounce spring
        tickBounce();

        // Speed arc — ease the displayed value toward the real speed so a brief
        // throttle blip fills in and drains out smoothly instead of popping.
        const lerp = (state.speed >= smoothSpeed) ? SPEED_LERP_UP : SPEED_LERP_DOWN;
        smoothSpeed += (state.speed - smoothSpeed) * lerp;
        if (Math.abs(state.speed - smoothSpeed) < 0.1) smoothSpeed = state.speed; // snap the last sliver
        const speedPctRaw = Math.min(smoothSpeed / state.maxSpeed, 1);

        // Smooth the EV throttle + brake every frame (drive the split power meter, and
        // the throttle is also the EV ring value). Ramps up quickly-but-smoothly.
        {
            const tgt = state.throttle || 0;
            const tl = (tgt >= smoothThrottle) ? THROTTLE_LERP_UP : THROTTLE_LERP_DOWN;
            smoothThrottle += (tgt - smoothThrottle) * tl;
            if (Math.abs(tgt - smoothThrottle) < 0.005) smoothThrottle = tgt;

            // LEFT side is now two independent layers: GREEN regen (state.regen) as the
            // base, and translucent GREY friction (state.friction) overlaid on top. Smooth
            // each separately so the grey can extend OVER the green instead of replacing it.
            const bt = state.regen || 0;
            const bl = (bt >= smoothBrake) ? THROTTLE_LERP_UP : THROTTLE_LERP_DOWN;
            smoothBrake += (bt - smoothBrake) * bl;
            if (Math.abs(bt - smoothBrake) < 0.005) smoothBrake = bt;

            const ft = state.friction || 0;
            const fl = (ft >= smoothFriction) ? THROTTLE_LERP_UP : THROTTLE_LERP_DOWN;
            smoothFriction += (ft - smoothFriction) * fl;
            if (Math.abs(ft - smoothFriction) < 0.005) smoothFriction = ft;
        }

        // EMODE-BAR: a full-PHEV wearing the SEMI cluster look (918/P1) that has slipped
        // into pure-EV drive. It keeps the normal tach ring (no split EV ring), but while
        // in e-mode there are no revs — so the ring reads THROTTLE (green, via CSS
        // .emode-bar) instead of rpm. Glide the throttle the same way the pure-EV ring does.
        {
            const et = state.emodeThr || 0;
            const el = (et >= smoothEmodeThr) ? EMODE_LERP_UP : EMODE_LERP_DOWN;
            smoothEmodeThr += (et - smoothEmodeThr) * el;
            if (Math.abs(et - smoothEmodeThr) < 0.004) smoothEmodeThr = et;
        }

        // RPM bar value. PURE-EV (not hybrid): the smoothed THROTTLE (0..1) drives the
        // pure-EV split ring. EMODE-BAR (semi-look PHEV in e-mode): throttle on the normal
        // tach ring. Everyone else (normal + hybrid): real rpm. Hybrids have a dedicated
        // thin RPM ring, so they use real rpm even in e-mode.
        const pureEv = state.electric && !state.hybrid;
        const throttleRing = pureEv || state.emodeBar;
        const rawRpmPct = pureEv
            ? smoothThrottle
            : (state.emodeBar
                ? smoothEmodeThr
                : Math.min(state.rpm / state.maxRpm, 1));
        const rpmPctBase = Math.max(0, Math.min(1, rawRpmPct + (throttleRing ? 0 : rpmBounce)));

        // Vibration flutter in NORMAL + FULL (the fancy tier); lite/minimal sit dead-still.
        if (dispMode === 'normal' || dispMode === 'full') {
            tickVibration(rpmPctBase, speedPctRaw);
        }
        const speedPct = Math.max(0, Math.min(1, speedPctRaw + speedVib));
        const rpmPct = Math.max(0, Math.min(1, rpmPctBase + rpmVib));

        // SVG ring writes — skipped in minimal (rings are CSS-hidden; writing to
        // display:none arcs is wasted work, and minimal is all about saving frames).
        // haloOn: only NORMAL mode shows the glow-halo twins, so only then do we write
        // them (in full/lite they're display:none — writing would be wasted work).
        const haloOn = (dispMode === 'normal');
        if (dispMode !== 'minimal') {
            const speedOffset = speedArcLen * (1 - speedPct);
            if (arcSpeedEl && !selfTestActive && Math.abs(speedOffset - lastSpeedOffset) > 0.05) {
                lastSpeedOffset = speedOffset;
                arcSpeedEl.style.strokeDashoffset = speedOffset;
                if (haloOn && arcSpeedHaloEl) arcSpeedHaloEl.style.strokeDashoffset = speedOffset;
            }

            if (!selfTestActive) {
                if (state.electric || state.hybrid) {
                    // PURE EV *and* HYBRID share the center-split power/regen ring at
                    // INNER_R — identical look, no redline glitch (that's the whole point
                    // of reusing the EV template). RIGHT = throttle (teal). LEFT = GREEN
                    // regen, with a translucent GREY friction band layered OVER it when the
                    // brake pedal is pressed (two independent arcs, grey on top of green).
                    if (rpmEvThrArc) {
                        rpmEvThrArc.style.strokeDashoffset = rpmEvHalfLen * (1 - smoothThrottle);
                    }
                    if (rpmEvBrakeArc) {
                        // GREEN regen — always its own colour now (no more grey swap).
                        rpmEvBrakeArc.style.strokeDashoffset = rpmEvHalfLen * (1 - smoothBrake);
                    }
                    if (rpmEvFrictionArc) {
                        // GREY friction overlay, revealed from the mid over the green.
                        rpmEvFrictionArc.style.strokeDashoffset = rpmEvHalfLen * (1 - smoothFriction);
                    }
                    if (rpmMaskArc) rpmMaskArc.style.strokeDashoffset = rpmMaskLen;

                    // HYBRID extra: the inner blue RPM ring + shift-lights/redline, but
                    // ONLY in ICE mode (e-mode is silent — CSS hides the RPM ring there).
                    // While the mode-change sweep is running it owns the ring + dots, so
                    // skip the live writes (they'd fight the sweep).
                    if (state.hybrid && !state.electricNow && !modeSweepActive) {
                        if (hyRpmArc) hyRpmArc.style.strokeDashoffset = hyRpmLen * (1 - rpmPct);
                        updateShiftLights(rpmPctBase);
                        updateRedlineApproach(rpmPctBase);
                    } else if (!modeSweepActive) {
                        // pure EV, or hybrid in e-mode: no revs — clear shift-lights/glow.
                        updateShiftLights(0);
                        updateRedlineApproach(0);
                    }
                } else {
                    const rpmOffset = rpmMaskLen * (1 - rpmPct);
                    if (rpmMaskArc && Math.abs(rpmOffset - lastRpmOffset) > 0.05) {
                        lastRpmOffset = rpmOffset;
                        rpmMaskArc.style.strokeDashoffset = rpmOffset;
                        if (haloOn && rpmHaloArc) rpmHaloArc.style.strokeDashoffset = rpmOffset;
                    }
                    // Single-gear comfort auto: no manual shifting -> clear the F1 shift-light
                    // dots (CSS hides them too). Redline glow stays — it's a rev warning.
                    // EMODE-BAR (semi-look PHEV in e-mode): the ring is throttle, not revs,
                    // so there's nothing to warn about — kill lights + glow like a pure EV.
                    if (state.emodeBar) {
                        updateShiftLights(0);
                        updateRedlineApproach(0);
                    } else {
                        updateShiftLights(state.singleGear ? 0 : rpmPctBase);
                        updateRedlineApproach(rpmPctBase);
                    }

                    // SEMI / KERS charge arc — only for a semi-hybrid (normal cars leave it
                    // hidden via CSS). Charge (green, regen on lift) and boost (amber,
                    // e-assist on throttle) are mutually exclusive in practice, so one arc
                    // fills from the base and swaps colour. EMA-glide both sides here (Lua
                    // already smooths, but the JS pass keeps it silky at any tick rate).
                    if (semiArc && state.semi) {
                        const cT = state.semiCharge || 0;
                        smoothSemiCharge += (cT - smoothSemiCharge) * (cT >= smoothSemiCharge ? THROTTLE_LERP_UP : THROTTLE_LERP_DOWN);
                        if (Math.abs(cT - smoothSemiCharge) < 0.005) smoothSemiCharge = cT;
                        const bT = state.semiBoost || 0;
                        smoothSemiBoost += (bT - smoothSemiBoost) * (bT >= smoothSemiBoost ? THROTTLE_LERP_UP : THROTTLE_LERP_DOWN);
                        if (Math.abs(bT - smoothSemiBoost) < 0.005) smoothSemiBoost = bT;
                        // charge wins the colour if both somehow non-zero (lift beats gas).
                        const charging = smoothSemiCharge > 0.01;
                        const frac = charging ? smoothSemiCharge : smoothSemiBoost;
                        semiArc.classList.toggle('semi-charge', charging);
                        semiArc.classList.toggle('semi-boost', !charging && smoothSemiBoost > 0.01);
                        semiArc.style.strokeDashoffset = semiArcLen * (1 - Math.max(0, Math.min(1, frac)));
                    } else if (semiArc && (smoothSemiCharge !== 0 || smoothSemiBoost !== 0)) {
                        smoothSemiCharge = 0; smoothSemiBoost = 0;
                        semiArc.style.strokeDashoffset = semiArcLen;   // hide
                    }
                }
            }
        }

        // Gear display: -1=R, 0=N, 1+=gear number. On change, slide the number:
        //   upshift  -> new enters from RIGHT, old exits LEFT
        //   downshift-> new enters from LEFT,  old exits RIGHT
        // Gear label. EV: forward gear = 'D' at COAST, or 'D1'/'D2'/'D3' in regen mode.
        let gearText = 'N';
        if (state.gear === -1) gearText = 'R';
        else if (state.gear === 0) gearText = 'N';
        else if (state.hybrid) {
            // Hybrid: E-MODE drives like a pure EV (single-gear feel) -> show 'D'. In ICE
            // mode show the real DCT/auto gear number. (The 'E' indication lives on the
            // gearbox STATUS pill, not the big gear readout.)
            gearText = state.electricNow ? 'D' : state.gear.toString();
        }
        else if (state.electric) {
            // Pure EV: 'D' at coast, or the D1/D2/D3 regen level.
            const rm = state.regenMode;   // 'coast'|'D1'|'D2'|'D3'
            gearText = (rm === 'D1' || rm === 'D2' || rm === 'D3') ? rm : 'D';
        }
        else if (state.emodeBar) {
            // Semi-look full-PHEV (918/P1) that slipped into pure-EV drive: it wears the
            // SEMI cluster (no split ring), but the drive is electric single-gear -> show
            // 'D' just like a real EV, instead of the ICE gear number.
            gearText = 'D';
        }
        else if (state.singleGear) {
            // Comfort auto (mode 0): full-auto box, no manual shifting to show -> always 'D'.
            gearText = 'D';
        }
        else gearText = state.gear.toString();
        updateGearDisplay(gearText, state.gear);

        // EV gear = white with a GREEN glow (like non-EV gear is white with a themed
        // glow). No per-stage colour on the gear — the stage colour lives on the status
        // pill only. Toggle a single .ev-gear class. Comfort auto (mode 0) gets a matching
        // white+BLUE glow via .single-gear (its 'D' isn't electric, so not the EV green).
        if (gearEl) {
            // EMODE-BAR (semi-look PHEV in e-mode) counts as EV for the green gear glow.
            const wantEv = !!state.electric || !!state.emodeBar;
            if (wantEv !== lastEvGear) {
                gearEl.classList.toggle('ev-gear', wantEv);
                lastEvGear = wantEv;
            }
            const wantSingle = !wantEv && !!state.singleGear;
            if (wantSingle !== lastSingleGear) {
                gearEl.classList.toggle('single-gear', wantSingle);
                lastSingleGear = wantSingle;
            }
        }

        // Speed number — show the smoothed value so the digit tracks the arc. Deadbanded:
        // only touch the DOM when the ROUNDED digit actually changes (was writing every
        // frame even when unchanged = needless text-node paint). Unit only on change too.
        const spd = Math.round(smoothSpeed);
        if (spd !== lastSpeedText) { speedEl.textContent = spd; lastSpeedText = spd; }
        if (state.unit !== lastUnitText) { unitEl.textContent = state.unit; lastUnitText = state.unit; }
    }
    let lastSpeedText = null, lastUnitText = null;

    // Slow indicators — driven by the throttled 'state' message, NOT per frame:
    // TC/ABS, handbrake, seatbelt/harness, lights, lock, fuel bar, NOS bar.
    function renderIndicators() {
        // TC/ABS pills: lit amber/peach = assist ON, dark grey = OFF. Drift mode force-disables
        // BOTH assists, so the pills show their dark OFF fill — but we add a flashing cyan outer
        // RING (drift-ring) on top so the driver can tell "off because I'm drifting" from "off
        // because I toggled /tc /abs". The ring layers over the fill and shows even when the
        // driver ALSO manually switched the assist off.
        const tcIsOff  = state.tcOff  || state.drift;
        const absIsOff = state.absOff || state.drift;
        indTc.className  = (tcIsOff  ? 'indicator tc-off'  : 'indicator active-tc')
            + (state.drift ? ' drift-ring' : '');
        indAbs.className = (absIsOff ? 'indicator abs-off' : 'indicator active-abs')
            + (state.drift ? ' drift-ring' : '');

        toggleIndicator(indHb, state.handbrake, 'active-handbrake');

        // Seatbelt/harness pill, three states:
        //   harness worn  -> solid RED (race harness on)
        //   buckled        -> solid GREEN (belt on, safe)
        //   neither        -> orange pulsing warning (unrestrained)
        if (state.harness) {
            indSeatbelt.className = 'indicator icon-pill harness-on';
        } else if (state.seatbelt) {
            indSeatbelt.className = 'indicator icon-pill seatbelt-on';
        } else {
            indSeatbelt.className = 'indicator icon-pill seatbelt-off';
        }

        // Door lock: locked = green, unlocked = amber. .unlocked also swaps the glyph.
        indLock.className = state.locked
            ? 'indicator icon-pill lock-locked'
            : 'indicator icon-pill unlocked lock-unlocked';

        // Headlights: 0 off (grey), 1 low beam (white), 2 high beam (blue + .highbeam glyph).
        if (indLights) {
            const L = state.lights || 0;
            indLights.className = 'indicator icon-pill '
                + (L >= 2 ? 'lights-high highbeam' : L === 1 ? 'lights-low' : 'lights-off');
        }

        // Hands up: hidden unless active; when active, hard bright-red fast pulse.
        if (indHandsup) {
            indHandsup.className = state.handsup
                ? 'indicator icon-pill handsup-on'
                : 'indicator icon-pill hidden';
        }

        // Auto-blinker pill (LAlt). Hidden when disarmed; when armed, a small green pill that
        // softly pulses (CSS). No side, no flash — just an on/off status like the other pills.
        if (indBlinker) {
            indBlinker.className = state.blinker ? 'indicator blinker-on' : 'indicator hidden';
        }

        // Gearbox mode pill. On a CHANGE, pulse bright twice fast (mode-switch feedback).
        //   PURE EV                 -> 'E' (green, single-speed).
        //   HYBRID in E-MODE        -> 'E' (green) too — it drives like a pure EV.
        //   HYBRID in ICE / normal  -> the real box: A (auto/DCT, blue) or M (manual, red).
        //   COMFORT AUTO (mode 0)   -> HIDDEN. It's a single-'D' full-auto with no manual
        //                              shifting, so an A/M pill is meaningless (like an EV).
        // The hybrid drive-mode ⚡ pill sits beside this one, so in ICE mode you get A/M + ⚡.
        if (indGearmode) {
            if (state.singleGear && !state.electric && !state.hybrid) {
                indGearmode.className = 'indicator hidden';
                lastGearMode = 'hidden';
            } else {
                let key, txt, cls;
                if (state.indIcon === 'E' || (state.hybrid && state.electricNow)) {
                    key = 'ev-E'; txt = 'E'; cls = 'indicator gearmode-e';
                } else {
                    const gm = state.gearMode || 'A';
                    key = gm; txt = gm;
                    cls = (gm === 'M') ? 'indicator gearmode-m'
                        : (gm === 'E') ? 'indicator gearmode-e'
                        : 'indicator gearmode-a';
                }
                indGearmode.textContent = txt;
                indGearmode.className = cls;
                if (key !== lastGearMode) {
                    if (lastGearMode !== null && lastGearMode !== 'hidden') {   // skip first sync + un-hide
                        indGearmode.classList.remove('gearmode-flash');
                        void indGearmode.offsetWidth;   // restart the animation
                        indGearmode.classList.add('gearmode-flash');
                    }
                    lastGearMode = key;
                }
            }
        }

        // Hybrid ⚡ pill (separate, right of A/M): only on hybrids (indIcon === 'BOLT').
        // GREEN = e-mode (running electric), GOLD = ICE (engine engaged). Hidden otherwise.
        if (indHybridmode) {
            if (state.indIcon === 'BOLT') {
                const gold = (state.indColor === 'gold');
                indHybridmode.textContent = '⚡';
                indHybridmode.className = 'indicator '
                    + (gold ? 'gearmode-bolt-gold' : 'gearmode-bolt-green');
            } else {
                indHybridmode.className = 'indicator hidden';
            }
        }

        // Drivetrain badge (RWD/FWD/AWD). Hidden until hk-handling reports a layout.
        if (indDrivetrain) {
            const dt = state.drivetrain;
            if (dt === 'RWD' || dt === 'FWD' || dt === 'AWD') {
                indDrivetrain.textContent = dt;
                indDrivetrain.className = 'indicator drivetrain-' + dt.toLowerCase();
            } else {
                indDrivetrain.className = 'indicator hidden';
            }
        }

        // Fuel bar
        if (fuelFill) fuelFill.style.width = Math.max(0, Math.min(100, state.fuel)) + '%';

        // NOS block — only visible when the car has the modifier.
        updateNosBlock();

        // NOS danger glow override
        if (state.nosState === 'danger') {
            glowEl.className = 'glow-red';
        } else if (state.nosState === 'boost') {
            glowEl.className = 'glow-nos';
        } else if (!glowTimeout) {
            glowEl.className = 'glow-none';
        }
    }

    // Render the NOS bar block: hide entirely without a NOS modifier; otherwise fill
    // the bar from remaining amount, light the level dots to the boost level, and swap
    // to the purge look (tinted with the vehicle's purge smoke colour) while purging.
    function updateNosBlock() {
        if (!nosBlock) return;
        if (!state.hasNos) {
            nosBlock.classList.add('hidden-nos');
            return;
        }
        nosBlock.classList.remove('hidden-nos');

        // Purge smoke colour. jim-mechanic's default (no custom colour set) is WHITE
        // (rgb(255,255,255)); a player-picked colour comes from GlobalState.nosColour.
        // state.nosColor is "r,g,b" or null. Apply it to BOTH the bar fill and the
        // purge icon while purging so the icon matches the real smoke colour (it was
        // stuck cyan before because we only set the var conditionally + wrong default).
        const purgeCol = state.nosColor ? ('rgb(' + state.nosColor + ')') : 'rgb(255,255,255)';
        if (state.nosPurge) {
            nosBarFill.style.setProperty('--nos-col', purgeCol);
            nosIcon.style.setProperty('--nos-col', purgeCol);
        } else {
            nosBarFill.style.removeProperty('--nos-col');
            nosIcon.style.removeProperty('--nos-col');
        }

        // Bar fill from remaining amount (0..100).
        nosBarFill.style.width = Math.max(0, Math.min(100, state.nosAmount)) + '%';

        // SINGLE icon slot SWAPS between the NOS bottle and purge spray SVGs (CSS
        // shows one or the other via .purging) — never both. Don't touch textContent
        // (that would wipe the inline SVGs).
        if (state.nosPurge) {
            nosIcon.classList.add('purging');
            nosIcon.classList.remove('boosting');
        } else {
            nosIcon.classList.remove('purging');
            nosIcon.classList.toggle('boosting', state.nosState === 'boost');
        }

        // Level dots: light 1..boostLevel.
        const lvl = Math.max(0, Math.min(3, state.nosBoostLevel || 0));
        for (let i = 0; i < nosDots.length; i++) {
            nosDots[i].classList.toggle('lit', i < lvl);
        }

        // Overheat (NOS held too long) — pulse a RED glow-bloom BEHIND the bar only.
        // The bar + icon keep their normal colours; just the shadow flashes.
        if (nosBarContainer) nosBarContainer.classList.toggle('overheat', !!state.nosOverheat);
    }

    function toggleIndicator(el, active, cls) {
        if (active) el.classList.add(cls);
        else el.classList.remove(cls);
    }

    // --- Glow events ---
    // The ring's fade in/out lives entirely in the CSS keyframe (pulse-*), so we let
    // the animation run to completion and clear the class on animationend rather than
    // a fixed timeout — a short timeout would strip the class mid-fade and snap it off.
    // The `duration` arg is kept for API compatibility but only used as a safety
    // fallback (in case animationend never fires), set well past the longest keyframe.
    // glowBusy locks the ring while a pulse is mid-play. On rapid gear changes we do
    // NOT interrupt or restart — the new glow is simply DROPPED, so each ring is only
    // shown once the previous one has fully finished (no strobing/stacking on fast
    // shifts). The lock clears on animationend.
    // Rings play ONE AT A TIME but rapid shifts are QUEUED, not dropped — so blitzing
    // through 1->3->5 shows a ring per shift back to back, each getting its full smooth
    // fade instead of overlapping into a smear. The queue is capped (GLOW_QUEUE_MAX) so
    // a long sweep can't lag seconds behind the car; oldest pending is dropped past the
    // cap. Consecutive duplicates of the same colour are collapsed (a run of normal
    // upshifts is still visibly one-per-shift, but we don't stack identical rings if the
    // queue is already saturated).
    let glowBusy = false;
    const glowQueue = [];
    const GLOW_QUEUE_MAX = 3;
    function startGlow(type) {
        if (glowTimeout) clearTimeout(glowTimeout);
        glowBusy = true;
        // Force a reflow between rings so re-adding the SAME colour class restarts its
        // CSS animation (without this, an identical class back-to-back wouldn't replay).
        glowEl.className = 'glow-none';
        void glowEl.offsetWidth;
        glowEl.className = 'glow-' + type;
        // Safety fallback only — real advance is on animationend below.
        glowTimeout = setTimeout(() => { advanceGlow(); }, 1400);
    }
    function advanceGlow() {
        if (glowTimeout) { clearTimeout(glowTimeout); glowTimeout = null; }
        if (glowQueue.length > 0) {
            startGlow(glowQueue.shift());   // play the next queued shift immediately
            return;
        }
        glowBusy = false;
        // Don't clobber a persistent NOS/danger glow (those have no pulse animation).
        if (state.nosState === 'boost' || state.nosState === 'danger') return;
        glowEl.className = 'glow-none';
    }
    function triggerGlow(type, duration) {
        if (glowBusy) {
            if (glowQueue.length >= GLOW_QUEUE_MAX) glowQueue.shift();  // keep it from lagging behind
            glowQueue.push(type);
            return;
        }
        startGlow(type);
    }
    // Advance the moment a ring's fade-out keyframe finishes, so each ring's smooth CSS
    // fade always completes before the next one starts.
    glowEl.addEventListener('animationend', advanceGlow);

    function triggerGearGlow(type, duration) {
        gearEl.classList.remove('rev-match', 'bad-shift', 'bad-down', 'perfect-shift');
        gearEl.classList.add(type);
        setTimeout(() => gearEl.classList.remove(type), duration || 400);
    }

    // Redline limiter glow — persistent flicker while AT the limiter (dedicated overlay)
    let redlineOn = false;
    function setRedlineGlow(on) {
        if (on === redlineOn) return; // avoid restarting the CSS animation every frame
        redlineOn = on;
        if (redlineEl2) redlineEl2.classList.toggle('active', on);
        // Flare the night backlight in sync with the redline event.
        if (on) flareBacklight();
    }

    // Pulse the night backlight brighter in sync with a shift / redline event. No-op
    // when night mode is off (backlight not lit). Restart the anim by removing + reflow.
    function flareBacklight() {
        if (!backlightEl || !container.classList.contains('night')) return;
        backlightEl.classList.remove('bl-flare');
        void backlightEl.offsetWidth;   // reflow so the animation replays each time
        backlightEl.classList.add('bl-flare');
    }

    // Pre-redline APPROACH glow: as RPM climbs toward the redline, fade a steady red
    // ring IN — from APPROACH_START (a bit under redline) up to just before the line.
    // This is a smooth opacity ramp (no flicker); the hard bouncing flicker is a
    // separate overlay (setRedlineGlow) that takes over the instant the limiter fires.
    // While the hard limiter is active we hold this at full so there's no dark gap.
    const APPROACH_BAND = 0.10; // start fading in this far below the redline
    function updateRedlineApproach(rpmPct) {
        if (!redlineEl2) return;
        const redline = state.redline || 0.85;
        const start = redline - APPROACH_BAND;
        let a;
        if (redlineOn) {
            a = 1;                                   // limiter firing: full (flicker owns visuals)
        } else if (rpmPct <= start) {
            a = 0;
        } else {
            // ramp 0 -> 1 across the approach band, eased, capped just under the line
            const t = Math.min(1, (rpmPct - start) / APPROACH_BAND);
            a = t * t;                               // ease-in (quadratic) = slow build then rise
        }
        // Only write when it changed (rounded) — avoids a per-frame style mutation
        // while cruising well below the redline (a === 0 unchanged).
        const av = a.toFixed(3);
        if (av !== lastApproach) {
            lastApproach = av;
            redlineEl2.style.setProperty('--approach', av);
        }
    }
    let lastApproach = null;

    // --- Intro/Outro animation ---
    const outerTrackEl = () => svg.querySelector('.arc-track-outer');
    const innerTrackEl = () => svg.querySelector('.arc-track-inner');
    const redlineEl = () => svg.querySelector('.redline-zone');

    function animateIn() {
        exitToken++;   // cancel any pending exit-hide from a quick re-entry

        // The exit overrode the live-fill transitions (0.45s drain); restore the fast
        // live-update transitions and reset the bars to empty before the self-test.
        const arcSpeedEl = document.getElementById('arc-speed');
        if (arcSpeedEl) {
            arcSpeedEl.style.transition = 'stroke-dashoffset 0.06s linear';
            arcSpeedEl.style.strokeDashoffset = speedArcLen;
        }
        if (rpmMaskArc) {
            rpmMaskArc.style.transition = 'stroke-dashoffset 0.016s linear';
            rpmMaskArc.style.strokeDashoffset = rpmMaskLen;
        }

        // Start arcs hidden (dashoffset = full length), then sweep to 0
        const outerLen = getArcLength(OUTER_R, ARC_SWEEP);
        const innerLen = getArcLength(INNER_R, ARC_SWEEP);

        const ot = outerTrackEl();
        const it = innerTrackEl();
        const rl = redlineEl();

        if (ot) {
            ot.style.strokeDasharray = outerLen;
            ot.style.transition = 'none';
            ot.style.strokeDashoffset = outerLen;
            ot.getBoundingClientRect();
            ot.style.transition = 'stroke-dashoffset 1.6s cubic-bezier(0.4, 0, 0.2, 1)';
            ot.style.strokeDashoffset = '0';
        }
        if (it) {
            it.style.strokeDasharray = innerLen;
            it.style.transition = 'none';
            it.style.strokeDashoffset = innerLen;
            it.getBoundingClientRect();
            it.style.transition = 'stroke-dashoffset 1.8s cubic-bezier(0.4, 0, 0.2, 1) 0.2s';
            it.style.strokeDashoffset = '0';
        }
        if (rl) {
            const redLen = getArcLength(INNER_R, ARC_SWEEP * 0.15);
            rl.style.strokeDasharray = redLen;
            rl.style.transition = 'none';
            rl.style.strokeDashoffset = redLen;
            rl.getBoundingClientRect();
            rl.style.transition = 'stroke-dashoffset 1.0s cubic-bezier(0.4, 0, 0.2, 1) 1.2s';
            rl.style.strokeDashoffset = '0';
        }

        // HYBRID inner ring: draw its track + redline band in on the same power-up sweep
        // as the main rings (CSS hides them unless .hybrid, so this is harmless otherwise).
        // The blue rev fill itself is swept by runSelfTest below.
        const hyTrack = svg.querySelector('#hy-rpm-track');
        const hyRed = svg.querySelector('#hy-rpm-redline');
        if (hyTrack) {
            hyTrack.style.strokeDasharray = hyRpmLen;
            hyTrack.style.transition = 'none';
            hyTrack.style.strokeDashoffset = hyRpmLen;
            hyTrack.getBoundingClientRect();
            hyTrack.style.transition = 'stroke-dashoffset 1.8s cubic-bezier(0.4, 0, 0.2, 1) 0.2s';
            hyTrack.style.strokeDashoffset = '0';
        }
        if (hyRed) {
            const hyRedLen = getArcLength(HY_RPM_R, ARC_SWEEP * 0.15);
            hyRed.style.strokeDasharray = hyRedLen;
            hyRed.style.transition = 'none';
            hyRed.style.strokeDashoffset = hyRedLen;
            hyRed.getBoundingClientRect();
            hyRed.style.transition = 'stroke-dashoffset 1.0s cubic-bezier(0.4, 0, 0.2, 1) 1.2s';
            hyRed.style.strokeDashoffset = '0';
        }
        // Start the blue rev fill hidden so the self-test sweep reveals it from empty.
        if (hyRpmArc) {
            hyRpmArc.style.transition = 'stroke-dashoffset 0.04s linear';
            hyRpmArc.style.strokeDashoffset = hyRpmLen;
        }

        // Show container (scale + fade handled by CSS transition). Preserve theme.
        container.classList.remove('hidden');
        container.classList.add('visible');
        applyTheme(state.theme);

        // Ignition self-test sweep: after the rings draw in, sweep both the speed
        // and rpm bars up to max and back down, like a real cluster powering on.
        runSelfTest();
    }

    // Ignition self-test: sweep both bars up to max, then settle DOWN to where the
    // engine actually is — like a real cluster. Speed lands at 0; RPM lands at the
    // live idle value (not 0), so there's no snap when live updates take over.
    function runSelfTest() {
        selfTestActive = true;
        const arcSpeed = document.getElementById('arc-speed');
        const dur = 550; // ms each way
        const t0 = performance.now();
        function frame(now) {
            const elapsed = now - t0;
            // Live idle target for RPM (where the needle should rest after the sweep).
            const idlePct = Math.max(0, Math.min(1, (state.rpm || 0) / state.maxRpm));
            // On a hybrid in ICE mode the blue inner ring carries revs, so sweep IT too
            // (in e-mode it's CSS-hidden, so writing to it is a harmless no-op).
            const hySweep = state.hybrid && !state.electricNow;
            if (elapsed < dur) {
                // UP: 0 -> max
                const p = elapsed / dur;
                const eased = p * p * (3 - 2 * p);
                if (arcSpeed) arcSpeed.style.strokeDashoffset = speedArcLen * (1 - eased);
                if (rpmMaskArc) rpmMaskArc.style.strokeDashoffset = rpmMaskLen * (1 - eased);
                if (arcSpeedHaloEl) arcSpeedHaloEl.style.strokeDashoffset = speedArcLen * (1 - eased);
                if (rpmHaloArc) rpmHaloArc.style.strokeDashoffset = rpmMaskLen * (1 - eased);
                if (hySweep && hyRpmArc) hyRpmArc.style.strokeDashoffset = hyRpmLen * (1 - eased);
                updateShiftLights(eased);
            } else if (elapsed < dur * 2) {
                // DOWN: max -> resting value (speed 0, rpm -> idle)
                const p = (elapsed - dur) / dur;
                const eased = p * p * (3 - 2 * p);
                const speedFrac = 1 - eased;               // -> 0
                const rpmFrac = 1 - eased * (1 - idlePct); // -> idlePct
                if (arcSpeed) arcSpeed.style.strokeDashoffset = speedArcLen * (1 - speedFrac);
                if (rpmMaskArc) rpmMaskArc.style.strokeDashoffset = rpmMaskLen * (1 - rpmFrac);
                if (arcSpeedHaloEl) arcSpeedHaloEl.style.strokeDashoffset = speedArcLen * (1 - speedFrac);
                if (rpmHaloArc) rpmHaloArc.style.strokeDashoffset = rpmMaskLen * (1 - rpmFrac);
                if (hySweep && hyRpmArc) hyRpmArc.style.strokeDashoffset = hyRpmLen * (1 - rpmFrac);
                updateShiftLights(rpmFrac);
            } else {
                selfTestActive = false;
                return; // hand control back to live updates (already at idle -> no snap)
            }
            requestAnimationFrame(frame);
        }
        requestAnimationFrame(frame);
    }

    // Mode-change sweep (hybrid only): fired when the car switches EV <-> hybrid(ICE) mode
    // live. Re-plays the same power-up feel for the INNER RPM ring + 9 shift dots so the
    // switch reads like the cluster re-arming, instead of the ring popping to its value.
    //   -> switching INTO ICE: draw the inner track/redline back in, then sweep the blue
    //      rev fill + dots up to max and settle to idle (like runSelfTest, ring only).
    //   -> switching INTO EV: the ring is CSS-hidden, so just make sure the dots clear.
    // Speed + the EV split power ring are untouched (they stay live across the switch).
    function runModeSweep(toIce) {
        if (!toIce) {
            // Into e-mode: ring/dots get hidden by CSS (.emode). Clear the dots so none
            // stay lit under the hidden ring, and bail — nothing to sweep.
            updateShiftLights(0);
            updateRedlineApproach(0);
            return;
        }

        // STEP 1 — draw the background gauge (inner track + redline band) in FIRST. The
        // blue rev fill stays empty and does NOT move until this finishes, so the ring
        // reads as "gauge appears, THEN needle sweeps" instead of both at once (which
        // looked laggy). TRACK_DRAW is how long we hold the fill before sweeping it.
        const TRACK_DRAW = 500; // ms — matches the track draw-in transition below
        const hyTrack = svg.querySelector('#hy-rpm-track');
        const hyRed = svg.querySelector('#hy-rpm-redline');
        if (hyTrack) {
            hyTrack.style.transition = 'none';
            hyTrack.style.strokeDashoffset = hyRpmLen;
            hyTrack.getBoundingClientRect();
            hyTrack.style.transition = 'stroke-dashoffset 0.5s cubic-bezier(0.4, 0, 0.2, 1)';
            hyTrack.style.strokeDashoffset = '0';
        }
        if (hyRed) {
            const hyRedLen = getArcLength(HY_RPM_R, ARC_SWEEP * 0.15);
            hyRed.style.transition = 'none';
            hyRed.style.strokeDashoffset = hyRedLen;
            hyRed.getBoundingClientRect();
            hyRed.style.transition = 'stroke-dashoffset 0.5s cubic-bezier(0.4, 0, 0.2, 1) 0.15s';
            hyRed.style.strokeDashoffset = '0';
        }
        if (hyRpmArc) {
            hyRpmArc.style.transition = 'stroke-dashoffset 0.04s linear';
            hyRpmArc.style.strokeDashoffset = hyRpmLen;   // start empty, held during TRACK_DRAW
        }

        // STEP 2 — after the track has drawn in, sweep the blue rev fill + dots up, then
        // settle to the live idle value. modeSweepActive is set now (not after the delay)
        // so the live gauge writes stay suppressed through the whole track-draw + sweep.
        modeSweepActive = true;
        const dur = 450; // ms each way (a touch quicker than the ignition self-test)
        const t0 = performance.now();
        function frame(now) {
            // Cancelled if we flipped back out of ICE mid-sweep, or the gauge exited.
            if (!state.hybrid || state.electricNow || selfTestActive) {
                modeSweepActive = false;
                return;
            }
            // Hold the blue fill empty while the background gauge draws in.
            const sinceStart = now - t0;
            if (sinceStart < TRACK_DRAW) {
                if (hyRpmArc) hyRpmArc.style.strokeDashoffset = hyRpmLen;   // stay empty
                updateShiftLights(0);
                requestAnimationFrame(frame);
                return;
            }
            const elapsed = now - t0 - TRACK_DRAW;   // sweep clock starts after the draw-in
            const idlePct = Math.max(0, Math.min(1, (state.rpm || 0) / state.maxRpm));
            if (elapsed < dur) {
                const p = elapsed / dur;
                const eased = p * p * (3 - 2 * p);
                if (hyRpmArc) hyRpmArc.style.strokeDashoffset = hyRpmLen * (1 - eased);
                updateShiftLights(eased);
            } else if (elapsed < dur * 2) {
                const p = (elapsed - dur) / dur;
                const eased = p * p * (3 - 2 * p);
                const rpmFrac = 1 - eased * (1 - idlePct);   // -> idlePct
                if (hyRpmArc) hyRpmArc.style.strokeDashoffset = hyRpmLen * (1 - rpmFrac);
                updateShiftLights(rpmFrac);
            } else {
                modeSweepActive = false;
                return; // hand back to live updates (already at idle -> no snap)
            }
            requestAnimationFrame(frame);
        }
        requestAnimationFrame(frame);
    }

    // Exit = a reverse of the enter power-up. Enter order was:
    //   container scales/fades up  ->  tracks sweep in (outer, then inner, then redline)
    //   ->  self-test sweeps the live bars.
    // So the reverse is:  live bars drain  ->  tracks retract (redline, then inner, then
    //   outer — reverse stagger)  ->  container scales/fades down LAST. We keep the
    //   container visible through the retract (adding .hidden immediately would fade it
    //   in 1.0s and swallow the whole animation), then hide it at the end.
    function animateOut() {
        const token = ++exitToken;   // cancels if a 'show' re-enters mid-exit
        selfTestActive = false;      // stop any in-flight ignition sweep

        const outerLen = getArcLength(OUTER_R, ARC_SWEEP);
        const innerLen = getArcLength(INNER_R, ARC_SWEEP);
        const ot = outerTrackEl();
        const it = innerTrackEl();
        const rl = redlineEl();
        const arcSpeed = document.getElementById('arc-speed');

        // Clear redline flicker + approach glow immediately.
        setRedlineGlow(false);
        if (redlineEl2) redlineEl2.style.setProperty('--approach', '0');
        gearEl.classList.remove('rev-limit');

        // 1) Live bars drain first (needles sweep back to 0) — the mirror of the
        //    self-test that ran at the end of the enter.
        if (arcSpeed) {
            arcSpeed.style.transition = 'stroke-dashoffset 0.45s cubic-bezier(0.4, 0, 0.6, 1)';
            arcSpeed.style.strokeDashoffset = speedArcLen;
        }
        if (rpmMaskArc) {
            rpmMaskArc.style.transition = 'stroke-dashoffset 0.45s cubic-bezier(0.4, 0, 0.6, 1)';
            rpmMaskArc.style.strokeDashoffset = rpmMaskLen;
        }
        smoothSpeed = 0;   // reset eased speed so a re-entry starts clean (rpm smoothing lives in Lua)

        // 2) Tracks retract in REVERSE stagger (redline first, then inner, then outer).
        //    Durations mirror the enter (~0.55–0.75s) so it reads as the same motion
        //    played backwards.
        if (rl) {
            const redLen = getArcLength(INNER_R, ARC_SWEEP * 0.15);
            rl.style.transition = 'stroke-dashoffset 0.4s cubic-bezier(0.4, 0, 0.8, 1)';
            rl.style.strokeDashoffset = redLen;
        }
        if (it) {
            it.style.transition = 'stroke-dashoffset 0.6s cubic-bezier(0.4, 0, 0.8, 1) 0.12s';
            it.style.strokeDashoffset = innerLen;
        }
        if (ot) {
            ot.style.transition = 'stroke-dashoffset 0.7s cubic-bezier(0.4, 0, 0.8, 1) 0.28s';
            ot.style.strokeDashoffset = outerLen;
        }

        // 3) After the retract finishes, scale + fade the container down (CSS 1.0s).
        //    Guarded by the token so a mid-exit re-entry doesn't hide it after showing.
        setTimeout(function () {
            if (token !== exitToken) return;   // a 'show' happened — abort the hide
            container.classList.remove('visible', 'idle');
            container.classList.add('hidden');
        }, 1000);

        // Reset so the first theme sync on the NEXT vehicle entry doesn't fire a pulse.
        themeSeen = false;
        lastGearMode = null;   // don't flash the gearmode pill on the next car's first sync
        lastEmode = null;      // re-arm the mode-change sweep detector for the next car
        modeSweepActive = false;
        if (modeEl) modeEl.classList.remove('pulse-sport', 'pulse-eco');
        container.classList.remove('night');   // clear night backlight on exit
        container.classList.remove('ev');       // clear EV fuel-hide on exit
        container.classList.remove('hybrid', 'emode');  // clear hybrid layout on exit
        container.classList.remove('semi');     // clear semi/KERS charge arc on exit
        smoothSemiCharge = 0; smoothSemiBoost = 0;
        if (semiArc) semiArc.style.strokeDashoffset = semiArcLen;
    }

    // Apply a display mode. Four modes:
    //   'normal'  (DEFAULT) — full look via cheap GLOW HALOS (twin arcs, no per-frame blur).
    //   'full'    — max quality: live per-arc drop-shadow filters (expensive; high-end PCs).
    //   'lite'    — flat, no glow at all (biggest FPS win short of minimal).
    //   'minimal' — compact rectangle panel (rings hidden).
    // Normal + Full both get glow + vibration (the "fancy" tier); lite/minimal sit still.
    // CSS classes: .normal / .lite / .minimal (full = no class). .lite is ALSO applied for
    // minimal (shares the flat-paint stripping). The glow-halo twins show only under .normal.
    function applyMode(mode) {
        dispMode = (mode === 'normal' || mode === 'lite' || mode === 'minimal') ? mode : 'full';
        const fancy = (dispMode === 'normal' || dispMode === 'full');   // glow + vibration tier
        container.classList.toggle('normal', dispMode === 'normal');
        container.classList.toggle('lite', dispMode === 'lite' || dispMode === 'minimal');
        container.classList.toggle('minimal', dispMode === 'minimal');
        // Kill any lingering vibration offset so lite/minimal sit dead-still.
        if (!fancy) { rpmVib = 0; speedVib = 0; }
    }

    // Regen-mode STATUS PILL (EV only, after the E pill). Just the STYLE, one letter:
    //   coast -> 'C' (blue).   regen (D1/D2/D3) -> 'R', coloured by stage:
    //   D1/D2 = green, D3 = neon purple. Hidden on non-EVs. HOLD pulse while D3 holds.
    function updateRegenBadge() {
        if (!indRegenmode) return;
        // PURE EV only. Hybrids intentionally skip the C/R regen pill — the ⚡ pill carries
        // the mode there, and stacking both was cluttered (user asked: just the thunder).
        if (!state.electric || state.hybrid || !state.regenMode) {
            indRegenmode.className = 'indicator hidden';
            return;
        }
        const mode = state.regenMode;                 // 'coast'|'D1'|'D2'|'D3'
        let label, cls;
        if (mode === 'coast')   { label = 'C'; cls = 'regen-coast'; }   // blue
        else if (mode === 'D3') { label = 'R'; cls = 'regen-d3'; }      // neon purple
        else                    { label = 'R'; cls = 'regen-d12'; }     // D1/D2 green
        indRegenmode.textContent = label;
        indRegenmode.className = 'indicator ' + cls
            + (state.regenHolding ? ' regen-hold' : '');
    }

    // LAUNCH CONTROL pill. state.lc is the pre-resolved render state from the client
    // (derived from hk-handling's launch phase — see client.lua). The pill is HIDDEN unless
    // actually staging (neutral + handbrake); there's no bare-neutral 'idle' look (it used
    // to pop up on every stop-in-neutral). Map -> class:
    //   'off'   -> hidden
    //   'prep'  -> grey box + red pulse (neutral + handbrake held, staging)
    //   'armed' -> solid red + red pulse (staged: throttle held, about to fire)
    //   'boost' -> gold + gold pulse (launched, boost window)
    // ('idle' is still handled below as a harmless alias in case the client ever sends it.)
    let lastLc = null;
    function updateLaunchBadge() {
        if (!indLaunch) return;
        const s = state.lc || 'off';
        if (s === lastLc) return;   // deadband — only touch the DOM on a state change
        lastLc = s;
        if (s === 'off') { indLaunch.className = 'indicator hidden'; return; }
        const cls = (s === 'boost') ? 'lc-boost'
                  : (s === 'armed') ? 'lc-armed'
                  : (s === 'prep')  ? 'lc-idle lc-prep'   // grey base + red pulse ring
                  :                   'lc-idle';
        indLaunch.className = 'indicator ' + cls;
    }

    // --- NUI message handler ---
    window.addEventListener('message', function (e) {
        const data = e.data;
        if (!data || !data.type) return;

        switch (data.type) {
            case 'show':
                animateIn();
                break;

            case 'hide':
                animateOut();
                break;

            // FAST per-frame tick: only the live needle values. This is the only
            // message that arrives at 60fps, so it stays tiny.
            case 'tick':
                state.speed = data.speed || 0;
                state.rpm = data.rpm || 0;
                state.gear = data.gear !== undefined ? data.gear : -1;
                if (data.electric !== undefined) state.electric = !!data.electric;
                if (data.hybrid !== undefined) state.hybrid = !!data.hybrid;
                if (data.electricNow !== undefined) state.electricNow = !!data.electricNow;
                if (data.indIcon !== undefined) state.indIcon = data.indIcon;
                if (data.indColor !== undefined) state.indColor = data.indColor;
                if (data.gearLabel !== undefined) state.gearLabel = data.gearLabel;
                if (data.singleGear !== undefined) state.singleGear = !!data.singleGear;
                // CLUTCH gauge (manual only). clutchManual gates visibility; clutch = engagement
                // 0..1 (1=out/engaged, 0=in/pressed). Fill scaleY = engagement; colour by zone.
                if (data.clutchManual !== undefined) state.clutchManual = !!data.clutchManual;
                if (data.clutch !== undefined) state.clutch = data.clutch;
                if (clutchGauge) {
                    // Hide on hybrid/EV: the split power/regen ring + e-mode bar own that inner-left
                    // space, and electric drive has no driver clutch to show — the CLT bar would just
                    // sit on top of the regen bar. Only render it for pure-ICE manual cars.
                    const clutchHidden = state.hybrid || state.electric;
                    if (state.clutchManual && !clutchHidden) {
                        clutchGauge.classList.remove('hidden-clutch');
                        const eng = Math.max(0, Math.min(1, state.clutch));
                        if (clutchFill) clutchFill.style.transform = 'scaleY(' + eng + ')';
                        // zones: >0.9 engaged (cyan), 0.1..0.9 feathering (amber), <0.1 in/shift (red)
                        clutchGauge.classList.toggle('clutch-partial', eng <= 0.9 && eng > 0.1);
                        clutchGauge.classList.toggle('clutch-in', eng <= 0.1);
                    } else {
                        clutchGauge.classList.add('hidden-clutch');
                        clutchGauge.classList.remove('clutch-partial', 'clutch-in');
                    }
                }
                // TURBO gauge (turbo cars only). turboActive gates visibility; turboSpool = boost
                // 0..1 (fill scaleY), turboHit = punch 0..1 (flash white when boost slams online).
                if (data.turboActive !== undefined) state.turboActive = !!data.turboActive;
                if (data.turboSpool !== undefined) state.turboSpool = data.turboSpool;
                if (data.turboHit !== undefined) state.turboHit = data.turboHit;
                if (turboGauge) {
                    // In ANY electric mode the ICE (and its turbo) is off, so there is no boost to show —
                    // hk-handling also suppresses the turbo itself in EV mode. Covers pure EV (state.electric)
                    // and a hybrid currently running on electric (state.electricNow). A hybrid on its ICE
                    // still shows boost.
                    const evNow = state.electric || state.electricNow;
                    if (state.turboActive && !evNow) {
                        turboGauge.classList.remove('hidden-turbo');
                        const spool = Math.max(0, Math.min(1, state.turboSpool));
                        if (turboFill) turboFill.style.transform = 'scaleY(' + spool + ')';
                        // on-boost (spool high) shifts green; punch (>0.35) flashes white briefly
                        turboGauge.classList.toggle('turbo-boosting', spool > 0.45);
                        turboGauge.classList.toggle('turbo-hit', (state.turboHit || 0) > 0.35);
                    } else {
                        turboGauge.classList.add('hidden-turbo');
                        turboGauge.classList.remove('turbo-boosting', 'turbo-hit');
                    }
                }
                // SEMI / KERS hybrid: keeps its normal tach, so it is NOT .hybrid/.ev — it
                // just flips .semi so the thin charge arc becomes visible (CSS). Fields are
                // sent nil on non-semis, so absence clears it.
                if (data.semi !== undefined) state.semi = !!data.semi;
                if (data.semiCharge !== undefined) state.semiCharge = data.semiCharge || 0;
                if (data.semiBoost !== undefined) state.semiBoost = data.semiBoost || 0;
                // SEMI-LOOK full PHEV (918/P1) in e-mode: tach shows a throttle-driven GREEN bar
                // instead of revs. emodeThr carries the pedal input for that bar.
                if (data.emodeBar !== undefined) state.emodeBar = !!data.emodeBar;
                if (data.emodeThr !== undefined) state.emodeThr = data.emodeThr || 0;
                container.classList.toggle('semi', !!state.semi);
                // MODE-FLIP CROSSFADE (semi-look PHEV only). On the e-mode<->ICE edge the tach
                // bar swaps green-throttle <-> blue-rpm — both colour AND value jump, and this
                // car has no runModeSweep (hybrid-only). Add .mode-flip for a beat so CSS fades
                // the bar out, the swap lands in the invisible trough, then it fades back in.
                if (!!state.emodeBar !== lastEmodeBar) {
                    lastEmodeBar = !!state.emodeBar;
                    container.classList.add('mode-flip');
                    if (modeFlipTimer) clearTimeout(modeFlipTimer);
                    // hold hidden long enough for the swap to settle, then release for fade-in.
                    modeFlipTimer = setTimeout(function () {
                        container.classList.remove('mode-flip');
                        modeFlipTimer = null;
                    }, 170);
                }
                // .emode-bar: green throttle-bar theme on a semi-look PHEV while electric.
                container.classList.toggle('emode-bar', !!state.emodeBar);
                // Hybrid 3-ring layout: show the middle regen ring + thin inner RPM ring.
                container.classList.toggle('hybrid', !!state.hybrid);
                // .ev (fuel-hide, pure-EV split ring, no shift lights) applies to PURE EVs
                // only — hybrids keep their fuel + own 3-ring layout via .hybrid.
                container.classList.toggle('ev', !!state.electric && !state.hybrid);
                // e-mode marker (hybrid currently electric) — hides RPM ring/shift-lights.
                container.classList.toggle('emode', !!state.hybrid && !!state.electricNow);
                // Single-gear comfort auto (mode 0): full-auto, no manual shifting -> hide
                // the F1 shift-light dots (there's no shift to signal). RPM ring stays.
                container.classList.toggle('single-gear',
                    !!state.singleGear && !state.electric && !state.hybrid);
                // Hybrid EV<->ICE mode switch: re-play the ring/dots power-up sweep so the
                // change animates like the other gauges instead of the ring popping in.
                // (Skip during the ignition self-test and on the very first sync.)
                if (state.hybrid) {
                    const emodeNow = !!state.electricNow;
                    if (lastEmode !== null && emodeNow !== lastEmode && !selfTestActive) {
                        runModeSweep(!emodeNow);   // toIce = switching INTO ICE mode
                    }
                    lastEmode = emodeNow;
                } else {
                    lastEmode = null;   // reset so re-entering a hybrid re-arms cleanly
                }
                if (data.throttle !== undefined) state.throttle = data.throttle;
                // EV left-zone = TWO independent layers: GREEN regen (state.regen) as the
                // base + translucent GREY friction (state.friction) overlaid on top when the
                // brake pedal is pressed. Both can be non-zero at once (grey extends over
                // green). state.braking flags the pedal (for the minimal-mode bar colour).
                if (data.regen !== undefined) state.regen = data.regen;
                if (data.friction !== undefined) state.friction = data.friction;
                if (data.braking !== undefined) state.braking = !!data.braking;
                state.brake = Math.max(state.regen || 0, state.friction || 0);
                state.regenMode = data.regenMode || null;       // 'onepedal'|'coast'|nil
                state.regenHolding = !!data.regenHolding;
                if (data.lc !== undefined) state.lc = data.lc;   // launch-control render state
                updateRegenBadge();
                updateLaunchBadge();
                // updateGauge drives gear/speed text + (when not minimal) the rings, and
                // smooths throttle/brake (used below + by the EV ring).
                updateGauge();
                if (dispMode === 'minimal') {
                    // Split power meter shows when driving electric NOW: a pure EV, or a
                    // hybrid in e-mode (state.electric is currentElectric = either case).
                    // A hybrid in ICE mode (electric=false, hybrid=true) shows the normal
                    // RPM fill instead — engine revs. CSS gates the bars on .ev/.hybrid.
                    // PERF: drive the bars with the CSS var --fill (0..1) -> scaleX, NOT
                    // width %. width reflows the panel every frame (that was minimal being
                    // slower than the rings); scaleX is composite-only.
                    const splitMeter = state.electric;
                    if (splitMeter) {
                        // Center-split power meter: each side scales 0..1 of its half. The
                        // left zone shows whichever is larger — green regen, or grey when
                        // the brake pedal (friction) is the dominant/active source.
                        if (miniRpmThr) miniRpmThr.style.setProperty('--fill', smoothThrottle.toFixed(3));
                        if (miniRpmBrake) {
                            const leftMag = Math.max(smoothBrake, smoothFriction);
                            miniRpmBrake.style.setProperty('--fill', leftMag.toFixed(3));
                            miniRpmBrake.classList.toggle('friction', !!state.braking);
                        }
                    } else if (miniRpmFill) {
                        // EMODE-BAR (semi-look PHEV on electric): the single fill reads
                        // THROTTLE, not revs, and greens via CSS (.emode-bar). Everyone
                        // else: real rpm.
                        const f = state.emodeBar
                            ? Math.max(0, Math.min(1, smoothEmodeThr))
                            : Math.max(0, Math.min(1, state.rpm / state.maxRpm));
                        miniRpmFill.style.setProperty('--fill', f.toFixed(3));
                    }
                }
                break;

            // Display mode change (from /speedo). full | lite | minimal.
            case 'mode':
                applyMode(data.mode || 'full');
                break;

            // Regen LEVEL change (Coast/D1/D2/D3): brief flash on the status pill. (The
            // D1/D2/D3 LEVEL itself animates in the gear display; the live mode comes
            // from the tick's regenMode — this is just the change flash.)
            case 'regenMode':
                if (indRegenmode) {
                    indRegenmode.classList.remove('regen-flash');
                    void indRegenmode.offsetWidth;
                    indRegenmode.classList.add('regen-flash');
                }
                break;

            // Hybrid e-mode<->ICE toggle (hold-G): flash the mode indicator. The live
            // state (icon/colour) is already updated per-frame via the tick.
            case 'hybridMode':
                if (indGearmode) {
                    indGearmode.classList.remove('gearmode-flash');
                    void indGearmode.offsetWidth;
                    indGearmode.classList.add('gearmode-flash');
                }
                break;

            // SLOW state message: sent only when a slow-moving value changed. Updates
            // the indicators / NOS / fuel / theme without touching the 60fps path.
            case 'state':
                state.nosState = data.nosState || 'off';
                if (data.hasNos !== undefined) state.hasNos = !!data.hasNos;
                if (data.nosAmount !== undefined) state.nosAmount = data.nosAmount;
                if (data.nosBoostLevel !== undefined) state.nosBoostLevel = data.nosBoostLevel;
                if (data.nosPurge !== undefined) state.nosPurge = !!data.nosPurge;
                if (data.nosColor !== undefined) state.nosColor = data.nosColor;
                if (data.nosOverheat !== undefined) state.nosOverheat = !!data.nosOverheat;
                state.drift = !!data.drift;
                if (data.tcOff !== undefined) state.tcOff = !!data.tcOff;
                if (data.absOff !== undefined) state.absOff = !!data.absOff;
                if (data.blinker !== undefined) state.blinker = !!data.blinker;
                state.handbrake = !!data.handbrake;
                state.seatbelt = data.seatbelt !== undefined ? !!data.seatbelt : true;
                state.harness = !!data.harness;
                if (data.locked !== undefined) state.locked = !!data.locked;
                if (data.lights !== undefined) state.lights = data.lights;   // 0 off / 1 low / 2 high
                if (data.handsup !== undefined) state.handsup = !!data.handsup;
                if (data.gearMode !== undefined) state.gearMode = data.gearMode;
                if (data.drivetrain !== undefined) state.drivetrain = data.drivetrain;
                if (data.fuel !== undefined) state.fuel = data.fuel;
                if (data.maxSpeed && data.maxSpeed !== state.maxSpeed) {
                    state.maxSpeed = data.maxSpeed;
                    if (data.maxSpeed !== currentGaugeMax) {
                        rebuildSpeedTicks(data.maxSpeed);
                    }
                }
                if (data.maxRpm) state.maxRpm = data.maxRpm;
                if (data.unit) state.unit = data.unit;
                if (data.theme && data.theme !== state.theme) {
                    state.theme = data.theme;
                    applyTheme(data.theme);
                    // Pulse the inner ring only on a real in-vehicle switch — not the
                    // first state sync after entering a car (themeSeen gates that).
                    if (themeSeen) pulseModeChange(data.theme);
                }
                themeSeen = true;
                if (data.redline !== undefined) state.redline = data.redline;
                if (data.electric !== undefined) {
                    state.electric = !!data.electric;
                    // .ev is PURE-EV only (hides fuel, pure-EV split ring). A HYBRID in e-mode
                    // also reports electric=true but must keep its .hybrid 3-ring layout + fuel
                    // bar. Guarding on !state.hybrid mirrors the per-frame tick — WITHOUT it,
                    // every pill/slow-state update briefly re-added .ev on a hybrid, flipping
                    // the ring layout + hiding the fuel bar for a frame or two until the next
                    // tick corrected it (the reported RPM-gauge/fuel-bar flicker).
                    container.classList.toggle('ev', state.electric && !state.hybrid);
                    // Entering an EV: clear any lit shift-lights / redline glow so they
                    // don't stay stuck on (we stop updating them while electric).
                    if (state.electric) {
                        setRedlineGlow(false);
                        if (redlineEl2) redlineEl2.style.setProperty('--approach', '0');
                        gearEl.classList.remove('rev-limit');
                        for (let i = 0; i < shiftLightEls.length; i++) {
                            shiftLightEls[i].classList.remove('lit');
                        }
                        if (shiftLightsGroup) shiftLightsGroup.classList.remove('strobe');
                    }
                }
                // Night-mode LED backlight: toggle the .night class + set its colour.
                if (data.night !== undefined) {
                    container.classList.toggle('night', !!data.night);
                    if (data.night && data.backlight && backlightEl) {
                        backlightEl.style.setProperty('--bl-col', data.backlight);
                    }
                }
                // Re-render the slow indicators (NOS bar, lights, seatbelt, etc.).
                renderIndicators();
                break;

            case 'glow':
                // Shift glow: 'blue' = normal shift (all boxes), 'gold' = perfect (manual only)
                triggerGlow(data.glow, data.duration);
                if (data.glow === 'gold') triggerGearGlow('perfect-shift', data.duration);
                flareBacklight();   // pulse the night backlight in sync with the shift
                // blue = normal shift, no gear text change
                break;

            case 'revlimit':
                // At rev limiter: flash the gear number red AND flicker the outer
                // gauge with a light-red redline glow (bouncing-off-limiter effect)
                if (data.active) {
                    gearEl.classList.add('rev-limit');
                    setRedlineGlow(true);
                } else {
                    gearEl.classList.remove('rev-limit');
                    setRedlineGlow(false);
                }
                break;

            case 'idle':
                if (container.classList.contains('visible')) {
                    container.classList.toggle('idle', !!data.idle);
                }
                break;
        }
    });

    // --- Init ---
    buildGauge();
})();
