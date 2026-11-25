// ============================================================
// hk-racecam — radial speed-blur overlay (WebGL)
//
// Renders a TRUE radial "zoom" blur of the live game image:
//   * sharp center (forward road stays clear)
//   * edges streak toward/away from center, scaling with speed
//   * transparent where not blurring, so the real game shows through
//
// It reads the live game frame via FiveM's undocumented "external_texture"
// hook: a 1x1 placeholder texture flagged by a specific TEXTURE_WRAP_T knock
// sequence gets its GPU storage swapped for the game backbuffer each frame.
// Mechanism verified from CitizenFX upstream + fivem-glsl source, cross-checked
// with Grok (live). The sampler is bound to texture unit 0.
//
// Driven by the Lua client via NUI messages:
//   { action:'blurConfig', cfg:{...} }  — push tunables (once, on engage)
//   { action:'blur', amount:0..1 }      — per-change speed-driven blur amount
//   { action:'blurOff' }                — stop & hide
// ============================================================
(function () {
    'use strict';

    var canvas = document.getElementById('blur-canvas');
    if (!canvas) return;

    // Runtime-tunable config (defaults mirror Config.MotionBlur.Glsl in Lua;
    // overwritten by the 'blurConfig' message).
    var CFG = {
        MaxRadius: 18.0,       // max streak length in px (at full amount)
        SharpRadius: 0.34,     // center sharp-zone radius (0..1 of half-diagonal)
        Feather: 0.45,         // ramp width past SharpRadius (0..1)
        MaxBlurSamples: 12,    // taps along the streak
        ResolutionScale: 0.5,  // GL backbuffer scale vs screen
        Opacity: 1.0,          // overall blur opacity multiplier (lower = more transparent)
    };

    var amount = 0.0;          // current blur amount 0..1
    var running = false;       // RAF loop active
    var rafId = null;

    // ---- Shaders ------------------------------------------------
    // The fragment shader compiles MaxBlurSamples in as a constant loop bound
    // (GLSL ES 1.00 requires a constant loop count), so it's rebuilt if the
    // sample count changes.
    var VERTEX_SRC =
        'attribute vec2 a_position;' +
        'attribute vec2 a_texcoord;' +
        'varying vec2 v_uv;' +
        'void main() {' +
        '  gl_Position = vec4(a_position, 0.0, 1.0);' +
        '  v_uv = a_texcoord;' +
        '}';

    function fragmentSrc(samples) {
        var n = Math.max(2, Math.min(32, samples | 0));
        return (
            'precision mediump float;' +
            'varying vec2 v_uv;' +
            'uniform sampler2D external_texture;' + // MUST be unit 0 / this name (canonical)
            'uniform vec2  u_resolution;' +
            'uniform float u_amount;' +     // 0..1 speed-driven blur amount
            'uniform float u_maxRadius;' +  // px
            'uniform float u_sharp;' +      // sharp-zone radius (0..1)
            'uniform float u_feather;' +    // feather width (0..1)
            'uniform float u_opacity;' +    // overall opacity multiplier
            'void main() {' +
            '  vec2 center = vec2(0.5, 0.5);' +
            '  vec2 toC = center - v_uv;' +              // vector toward screen center
            // distance from center, normalized so the corner = 1.0
            '  float dist = length((v_uv - center) * (u_resolution / min(u_resolution.x, u_resolution.y)));' +
            '  float edge = smoothstep(u_sharp, u_sharp + u_feather, dist);' +
            '  float strength = edge * u_amount;' +
            '  if (strength <= 0.001) { discard; }' +    // center & idle: transparent
            // streak length in UV space (px -> uv via height)
            '  float streak = (u_maxRadius * strength) / u_resolution.y;' +
            '  vec3 sum = vec3(0.0);' +
            '  for (int i = 0; i < ' + n + '; i++) {' +
            '    float t = float(i) / float(' + (n - 1) + ');' +  // 0..1 toward center
            '    vec2 samplePos = v_uv + toC * (t * streak);' +
            '    sum += texture2D(external_texture, samplePos).rgb;' +
            '  }' +
            '  sum /= float(' + n + ');' +
            '  gl_FragColor = vec4(sum, strength * u_opacity);' + // alpha = blend over real game
            '}'
        );
    }

    // ---- GL state ----------------------------------------------
    var gl = null, program = null, gameTex = null;
    var loc = {};            // uniform/attrib locations
    var builtSamples = -1;   // sample count the current program was built with

    function compile(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
            console.error('[hk-racecam blur] shader compile: ' + gl.getShaderInfoLog(s));
            gl.deleteShader(s);
            return null;
        }
        return s;
    }

    function buildProgram(samples) {
        var vs = compile(gl.VERTEX_SHADER, VERTEX_SRC);
        var fs = compile(gl.FRAGMENT_SHADER, fragmentSrc(samples));
        if (!vs || !fs) return false;
        var p = gl.createProgram();
        gl.attachShader(p, vs);
        gl.attachShader(p, fs);
        gl.linkProgram(p);
        if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
            console.error('[hk-racecam blur] link: ' + gl.getProgramInfoLog(p));
            return false;
        }
        if (program) gl.deleteProgram(program);
        program = p;
        gl.useProgram(program);

        loc.position   = gl.getAttribLocation(program, 'a_position');
        loc.texcoord   = gl.getAttribLocation(program, 'a_texcoord');
        loc.tex        = gl.getUniformLocation(program, 'external_texture');
        loc.resolution = gl.getUniformLocation(program, 'u_resolution');
        loc.amount     = gl.getUniformLocation(program, 'u_amount');
        loc.maxRadius  = gl.getUniformLocation(program, 'u_maxRadius');
        loc.sharp      = gl.getUniformLocation(program, 'u_sharp');
        loc.feather    = gl.getUniformLocation(program, 'u_feather');
        loc.opacity    = gl.getUniformLocation(program, 'u_opacity');
        gl.uniform1i(loc.tex, 0);  // sampler -> texture unit 0

        builtSamples = samples;
        return true;
    }

    // THE MAGIC: create a 1x1 placeholder, then knock TEXTURE_WRAP_T in the
    // exact CLAMP->MIRRORED_REPEAT->REPEAT->CLAMP order. FiveM's CEF intercepts
    // this sequence and swaps the texture's storage for the live game frame.
    function createGameTexture() {
        var tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
            new Uint8Array([0, 0, 255, 255]));  // opaque-blue tell if the hook fails
        // NEAREST + CLAMP are REQUIRED: the swapped-in game texture is non-power-
        // of-two; LINEAR/mipmap filtering makes a NPOT texture non-renderable
        // (samples black). And every call here MUST be texParameterf (float) —
        // FiveM's CEF pattern-matches the FLOAT variant of the WRAP_T knock;
        // texParameteri does NOT trigger the hook (verified vs CitizenFX source).
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        // --- magic knock sequence (do not reorder / skip / change to texParameteri) ---
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
        gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        return tex;
    }

    function setupBuffers() {
        var posBuf = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
        gl.enableVertexAttribArray(loc.position);
        gl.vertexAttribPointer(loc.position, 2, gl.FLOAT, false, 0, 0);

        var uvBuf = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, uvBuf);
        // No Y flip — the external texture arrives in this orientation already.
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
        gl.enableVertexAttribArray(loc.texcoord);
        gl.vertexAttribPointer(loc.texcoord, 2, gl.FLOAT, false, 0, 0);
    }

    function resize() {
        if (!gl) return;
        var s = CFG.ResolutionScale || 0.5;
        var w = Math.max(1, Math.floor(window.innerWidth * s));
        var h = Math.max(1, Math.floor(window.innerHeight * s));
        if (canvas.width !== w || canvas.height !== h) {
            canvas.width = w;
            canvas.height = h;
        }
        gl.viewport(0, 0, w, h);
    }

    function initGL() {
        if (gl) return true;
        // Context attributes matter for the hook. desynchronized:true is present
        // in both canonical streaming sources (cfx-ui, liquiad) — include it.
        // alpha:true is kept (unlike raw-stream cfx-ui) because this is a blur
        // OVERLAY that composites over the live game via the transparent center;
        // fivem-glsl's blur path also uses alpha:true and still gets the texture.
        // Must be WebGL1 ('webgl') — the hook is not wired for 'webgl2'.
        gl = canvas.getContext('webgl', {
            alpha: true, antialias: false, depth: false, stencil: false,
            premultipliedAlpha: false,  // we output straight (non-premultiplied) alpha;
                                        // without this the canvas compositor darkens/halos
                                        // the partially-transparent blur (the dark disc).
            desynchronized: true, failIfMajorPerformanceCaveat: false,
        });
        if (!gl) { console.error('[hk-racecam blur] no WebGL'); return false; }
        if (!buildProgram(CFG.MaxBlurSamples)) return false;
        gameTex = createGameTexture();
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, gameTex);
        setupBuffers();
        gl.clearColor(0, 0, 0, 0);
        gl.disable(gl.DEPTH_TEST);
        window.addEventListener('resize', resize);
        resize();
        return true;
    }

    function renderFrame() {
        if (!running) return;
        if ((CFG.MaxBlurSamples | 0) !== builtSamples) {
            buildProgram(CFG.MaxBlurSamples);
            setupBuffers();
        }
        gl.useProgram(program);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, gameTex);
        gl.uniform2f(loc.resolution, canvas.width, canvas.height);
        gl.uniform1f(loc.amount, amount);
        gl.uniform1f(loc.maxRadius, CFG.MaxRadius);
        gl.uniform1f(loc.sharp, CFG.SharpRadius);
        gl.uniform1f(loc.feather, CFG.Feather);
        gl.uniform1f(loc.opacity, (CFG.Opacity !== undefined ? CFG.Opacity : 1.0));
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        // NOTE: no gl.finish() here. gl.finish() blocks the CPU until the GPU is
        // done every frame — a major stutter source that made the camera feel
        // janky. requestAnimationFrame already paces us; the game frame fills in
        // within a couple of ticks without forcing a sync.
        rafId = requestAnimationFrame(renderFrame);
    }

    function start() {
        if (running) return;
        if (!initGL()) return;
        running = true;
        canvas.style.display = 'block';
        resize();
        rafId = requestAnimationFrame(renderFrame);
    }

    function stop() {
        running = false;
        if (rafId) { cancelAnimationFrame(rafId); rafId = null; }
        canvas.style.display = 'none';
    }

    // ---- NUI message bridge ------------------------------------
    window.addEventListener('message', function (e) {
        var d = e.data || {};
        if (d.action === 'blurConfig') {
            if (d.cfg) { for (var k in d.cfg) { if (d.cfg.hasOwnProperty(k)) CFG[k] = d.cfg[k]; } }
            // Just store config — do NOT start the loop here. Warming up on engage
            // meant the full-screen GL draw ran the entire time you were in the
            // race cam (even at zero blur), costing framerate and making the
            // camera feel janky. The loop now starts only when blur is actually
            // needed (first 'blur' with amount > 0). Tradeoff: the first ~1-3
            // frames as it crosses the speed threshold may flash the placeholder
            // briefly — acceptable vs a constant perf drain.
        } else if (d.action === 'blur') {
            amount = Math.max(0, Math.min(1, d.amount || 0));
            if (amount > 0.001) start();   // ensure running (no-op if already)
            else stop();                   // below threshold: fully stop the loop (no idle cost)
        } else if (d.action === 'blurOff') {
            amount = 0;
            stop();
        } else if (d.action === 'blurKill') {
            // Hard stop + drop the GL context's per-frame work entirely.
            amount = 0;
            stop();
        }
    });

    window.__hkBlur = { CFG: CFG, start: start, stop: stop };
})();

