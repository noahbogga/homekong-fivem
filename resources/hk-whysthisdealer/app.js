// hk-whysthisdealer NUI audio.
// One <audio> per bouncing vehicle (keyed by net id). Lua drives play/stop and
// streams, every frame, the network-synced playback position + distance volume.
// We continuously correct each element toward that shared position so all
// players hear the same moment of the clip, and we keep retrying play() for
// clients whose autoplay was blocked (remote players have no user gesture).

const host = document.getElementById('wtd-audio-host');
const players = {}; // netId -> { el, started }

const DRIFT_TOLERANCE = 0.35; // seconds; reseek if we drift more than this

function makeAudio() {
	const a = document.createElement('audio');
	a.src = 'whysthisdealer.mp3';
	a.loop = false;
	a.preload = 'auto';
	a.volume = 0.0;
	host.appendChild(a);
	return a;
}

window.addEventListener('message', (e) => {
	const d = e.data || {};
	const id = d.id;

	if (d.action === 'play') {
		let p = players[id];
		if (!p) { p = { el: makeAudio(), started: false }; players[id] = p; }
		try { p.el.currentTime = Math.max(0, d.offset || 0); } catch (_) {}
		p.el.volume = 0.0;
		p.el.play().then(() => { p.started = true; }).catch(() => { p.started = false; });
	}

	else if (d.action === 'sync') {
		const p = players[id];
		if (!p) return;
		const a = p.el;

		// volume
		let v = d.vol;
		if (v < 0) v = 0; if (v > 1) v = 1;
		a.volume = v;

		// keep trying to start if autoplay was blocked earlier
		if (a.paused) {
			a.play().then(() => { p.started = true; }).catch(() => {});
		}

		// correct drift toward the shared network-synced position
		if (typeof d.pos === 'number' && isFinite(a.duration) && a.duration > 0) {
			const target = Math.min(d.pos, a.duration - 0.05);
			if (target >= 0 && Math.abs(a.currentTime - target) > DRIFT_TOLERANCE) {
				try { a.currentTime = target; } catch (_) {}
			}
		}
	}

	else if (d.action === 'stop') {
		const p = players[id];
		if (p) {
			p.el.pause();
			p.el.remove();
			delete players[id];
		}
	}
});
