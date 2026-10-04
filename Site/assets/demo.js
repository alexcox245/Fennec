// Fennec landing-page demo.
//
// The line is drawn from the demo audio itself. The page decodes the track,
// finds the crackle in it (sustained high-frequency hash and buffer dropouts)
// and the restart (a stretch of digital silence), and draws what it finds at
// the playback position. With sound on, the clock is the audio clock, so every
// glitch on screen is the glitch in your speakers. When the line goes flat,
// the fox runs along the bottom of the window.
(() => {
  "use strict";

  const AUDIO_URL = "assets/demo-audio.mp3";
  const FOX_URL = "assets/fennec-run.gif";

  // Detection, tuned against the demo track: no false positives in the clean
  // music, every simulated glitch caught.
  const HF_RATIO = 0.85;      // first-difference RMS over loudness
  const HF_RUN = 3;           // ...sustained for this many 1 ms frames
  const DROP_LEVEL = 0.004;   // a buffer of nothing inside loud music
  const DROP_RUN = 5;
  const LOUD_MIN = 0.02;
  const FLAT_LEVEL = 0.002;   // the restart: silence
  const FLAT_RUN = 200;       // ms; dropouts never last this long
  const EVENT_GAP = 20;       // ms between separate glitch events
  const THRESHOLD_WINDOW = 3; // s: Balanced sensitivity, two signals in three seconds

  const SPAN = 0.085;         // seconds of audio across the line
  const PERSIST = 0.15;       // a glitch stays on screen this long, as on a scope
  const CARRIER_PERIOD = 1 / 27.5;

  // The fox: source crop 1087 px wide; the paw moves ~1021 source px per
  // 1.16 s loop, so travel shares the gait's clock at any display width.
  const FOX_SOURCE_SPEED = 1021 / 1.16 / 1087; // fox widths per second

  const $ = (id) => document.getElementById(id);
  const canvas = $("scope");
  const ctx2d = canvas.getContext("2d");
  const captionEl = $("caption");
  const glyph = $("glyph");
  const notice = $("notice");
  const soundButton = $("sound");
  const soundLabel = $("sound-label");
  const screen = $("screen");
  const fox = $("fox");
  let foxImg = $("fox-img");

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const css = getComputedStyle(document.documentElement);
  const CREAM = css.getPropertyValue("--cream").trim() || "#FDDCAF";
  const DUNE = css.getPropertyValue("--dune").trim() || "#EF792D";
  const RULE = "rgba(253, 220, 175, 0.22)";

  let audioCtx = null;
  let buffer = null;
  let data = null;            // analysis, see analyse()
  let source = null;          // the playing AudioBufferSourceNode, when sound is on
  let soundStart = 0;         // audioCtx time at position 0 of the current loop
  let silentPos = 0;          // seconds into the loop, silent clock
  let lastTick = 0;
  let prevPos = 0;
  let visible = true;
  let foxReady = false;
  let foxRun = null;          // { start: ms timestamp }

  // ------------------------------------------------------------ analysis

  function analyse(buf) {
    const sr = buf.sampleRate;
    const n = buf.length;
    const mono = new Float32Array(n);
    for (let c = 0; c < buf.numberOfChannels; c++) {
      const ch = buf.getChannelData(c);
      for (let i = 0; i < n; i++) mono[i] += ch[i] / buf.numberOfChannels;
    }
    const hop = Math.max(1, Math.round(sr / 1000));
    const frames = Math.floor(n / hop);
    const rms = new Float32Array(frames);
    const hf = new Float32Array(frames);
    for (let f = 0; f < frames; f++) {
      let s = 0, d = 0;
      const a = f * hop;
      for (let i = a; i < a + hop; i++) {
        const v = mono[i];
        s += v * v;
        const dv = v - (i > 0 ? mono[i - 1] : 0);
        d += dv * dv;
      }
      rms[f] = Math.sqrt(s / hop);
      hf[f] = Math.sqrt(d / hop);
    }
    // Short-term loudness: 60 ms centred mean of power.
    const loud = new Float32Array(frames);
    const prefix = new Float64Array(frames + 1);
    for (let f = 0; f < frames; f++) prefix[f + 1] = prefix[f] + rms[f] * rms[f];
    for (let f = 0; f < frames; f++) {
      const lo = Math.max(0, f - 30), hi = Math.min(frames, f + 31);
      loud[f] = Math.sqrt((prefix[hi] - prefix[lo]) / (hi - lo));
    }

    const glitch = new Uint8Array(frames);
    const markRuns = (test, len) => {
      let run = 0;
      for (let f = 0; f < frames; f++) {
        run = test(f) ? run + 1 : 0;
        if (run >= len) for (let k = f - len + 1; k <= f; k++) glitch[k] = 1;
      }
    };
    markRuns((f) => loud[f] > LOUD_MIN && hf[f] / (loud[f] + 1e-4) > HF_RATIO, HF_RUN);
    markRuns((f) => loud[f] > LOUD_MIN && rms[f] < DROP_LEVEL, DROP_RUN);
    for (let f = 0; f < Math.min(frames, 300); f++) glitch[f] = 0; // the loop's fade-in

    const events = [];
    let last = -1e9;
    for (let f = 0; f < frames; f++) {
      if (!glitch[f]) continue;
      if (f - last > EVENT_GAP) events.push(f / 1000);
      last = f;
    }

    // The restart: the first long stretch of silence after the music starts.
    let flatStart = null, flatEnd = null, run = 0;
    for (let f = 1000; f < frames; f++) {
      if (loud[f] < FLAT_LEVEL) {
        run++;
        if (run === FLAT_RUN && flatStart === null) flatStart = (f - FLAT_RUN + 1) / 1000;
      } else {
        if (flatStart !== null && flatEnd === null && run >= FLAT_RUN) { flatEnd = f / 1000; break; }
        run = 0;
      }
    }

    // "Crackle detected" when a second signal lands inside the window.
    let detectAt = null;
    for (let i = 1; i < events.length; i++) {
      if (events[i] - events[i - 1] <= THRESHOLD_WINDOW) { detectAt = events[i]; break; }
    }

    // Normalise the calm line to the music's own typical loudness.
    const early = Array.from(loud.subarray(300, Math.min(frames, 4300))).sort((a, b) => a - b);
    const typical = early[Math.floor(early.length * 0.95)] || 0.1;

    return {
      sr, hop, frames, mono, loud, glitch, events, typical,
      duration: n / sr,
      detectAt, flatStart, flatEnd,
      doneAt: flatEnd !== null ? flatEnd + 0.4 : null,
    };
  }

  // ------------------------------------------------------------ the line

  function carrier(t) {
    const w = 2 * Math.PI * 55 * t;
    return Math.sin(w) + 0.35 * Math.sin(2 * w + 0.6) + 0.2 * Math.sin(0.5 * w + 1.1);
  }

  function loudAt(t) {
    const f = Math.min(data.frames - 1, Math.max(0, Math.floor(t * 1000)));
    return data.loud[f];
  }

  function sizeCanvas() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.round(canvas.clientWidth * dpr);
    const h = Math.round(canvas.clientHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    return dpr;
  }

  function drawLine(pos, faulty) {
    const dpr = sizeCanvas();
    const W = canvas.width, H = canvas.height, mid = H / 2;
    ctx2d.clearRect(0, 0, W, H);
    ctx2d.fillStyle = RULE;
    ctx2d.fillRect(0, Math.round(mid - dpr / 2), W, Math.max(1, Math.round(dpr)));

    const amp = H * 0.3;
    const points = Math.max(120, Math.min(700, Math.round(W / (2 * dpr)) * 2));
    let ys = new Float32Array(points);

    if (data) {
      // Hold steady on the carrier's period, like a triggered scope; jump to
      // a fresh glitch so it stays readable for a few frames.
      let start = Math.floor((pos - SPAN) / CARRIER_PERIOD) * CARRIER_PERIOD;
      const f1 = Math.floor(pos * 1000);
      for (let f = Math.max(0, f1 - PERSIST * 1000); f <= f1 && f < data.frames; f++) {
        if (data.glitch[f]) { start = f / 1000 - SPAN * 0.35; break; }
      }
      const norm = 1 / (data.typical * 1.55);
      for (let i = 0; i < points; i++) {
        const t = start + (SPAN * i) / (points - 1);
        const f = Math.floor(t * 1000);
        let v;
        if (t < 0 || f >= data.frames) v = 0;
        else if (data.glitch[f]) {
          const s = Math.min(data.mono.length - 1, Math.floor(t * data.sr));
          v = (data.mono[s] / data.typical) * 0.45;  // the sound itself
        } else v = carrier(t) * loudAt(t) * norm;
        const taper = Math.pow(Math.sin((Math.PI * i) / (points - 1)), 0.35);
        ys[i] = Math.max(-1.35, Math.min(1.35, v * taper));
      }
    } else {
      // Before the audio decodes: a calm line at typical height.
      for (let i = 0; i < points; i++) {
        const t = (SPAN * i) / (points - 1);
        ys[i] = carrier(t) / 1.55 * 0.8 * Math.pow(Math.sin((Math.PI * i) / (points - 1)), 0.35);
      }
    }

    ctx2d.beginPath();
    for (let i = 0; i < points; i++) {
      const x = (W * i) / (points - 1);
      const y = mid - ys[i] * amp;
      if (i === 0) ctx2d.moveTo(x, y); else ctx2d.lineTo(x, y);
    }
    ctx2d.strokeStyle = faulty ? DUNE : CREAM;
    ctx2d.lineWidth = (faulty ? 3.5 : 3) * dpr;
    ctx2d.lineJoin = "round";
    ctx2d.lineCap = "round";
    ctx2d.stroke();
  }

  // ------------------------------------------------------------ story state

  let shownCaption = captionEl.textContent;
  function setCaption(text) {
    if (text === shownCaption) return;
    shownCaption = text;
    if (reduceMotion.matches) { captionEl.textContent = text; return; }
    captionEl.classList.add("swap");
    setTimeout(() => {
      captionEl.textContent = shownCaption;
      captionEl.classList.remove("swap");
    }, 160);
  }

  function phase(pos) {
    const d = data;
    if (!d || d.detectAt === null || d.flatStart === null) return "listening";
    if (pos < d.detectAt) return "listening";
    if (pos < d.flatStart) return "detected";
    if (pos < d.doneAt) return "repairing";
    if (pos < d.doneAt + 5.5) return "done";
    return "listening-after";
  }

  function applyPhase(p) {
    const captions = {
      "listening": "Listening for crackling",
      "detected": "Crackle detected",
      "repairing": "Resolving…",
      "done": "Donesies",
      "listening-after": "Listening for crackling",
    };
    setCaption(captions[p]);
    glyph.dataset.state =
      p === "detected" ? "detected" : p === "repairing" ? "repairing" : "listening";
    notice.classList.toggle("show", p === "done");
  }

  // ------------------------------------------------------------ the fox

  function preloadFox() {
    if (foxImg.src) return;
    const img = new Image();
    img.onload = () => { foxReady = true; };
    img.src = FOX_URL;
    foxImg.src = FOX_URL;
  }

  function startFox() {
    if (!foxReady || reduceMotion.matches || foxRun) return;
    // Re-insert the image so the gait starts from its first frame.
    const fresh = foxImg.cloneNode();
    foxImg.replaceWith(fresh);
    fresh.src = FOX_URL;
    foxImg = fresh;
    foxRun = { start: performance.now() };
    fox.style.transform = `translate3d(${-fox.offsetWidth}px,0,0)`;
    fox.classList.add("running");
  }

  function stepFox(now) {
    if (!foxRun) return;
    const width = fox.offsetWidth;
    const x = -width + ((now - foxRun.start) / 1000) * FOX_SOURCE_SPEED * width;
    if (x > window.innerWidth) {
      fox.classList.remove("running");
      fox.style.transform = "";
      foxRun = null;
      return;
    }
    fox.style.transform = `translate3d(${x.toFixed(1)}px,0,0)`;
  }

  // ------------------------------------------------------------ clock

  function soundOn() { return source !== null; }

  function position(now) {
    if (!data) return 0;
    if (soundOn()) {
      return ((audioCtx.currentTime - soundStart) % data.duration + data.duration) % data.duration;
    }
    const dt = Math.min(0.1, (now - lastTick) / 1000);
    const running = visible && !document.hidden && !reduceMotion.matches;
    if (running) silentPos = (silentPos + dt) % data.duration;
    return silentPos;
  }

  function crossed(from, to, mark) {
    if (mark === null) return false;
    return from <= to ? from < mark && mark <= to : mark > from || mark <= to;
  }

  function frame(now) {
    const pos = position(now);
    lastTick = now;
    if (data) {
      if (pos !== prevPos && crossed(prevPos, pos, data.flatStart)) startFox();
      prevPos = pos;
      const p = phase(pos);
      applyPhase(p);
      drawLine(pos, p === "detected");
    } else {
      drawLine(0, false);
    }
    stepFox(now);
    requestAnimationFrame(frame);
  }

  // ------------------------------------------------------------ sound

  async function enableSound() {
    if (!audioCtx || !buffer) return;
    await audioCtx.resume();
    const offset = silentPos;
    source = audioCtx.createBufferSource();
    source.buffer = buffer;
    source.loop = true;
    const gain = audioCtx.createGain();
    gain.gain.value = 0.8;
    source.connect(gain).connect(audioCtx.destination);
    soundStart = audioCtx.currentTime - offset;
    source.start(0, offset);
    soundButton.setAttribute("aria-pressed", "true");
    soundLabel.textContent = "Mute";
  }

  function disableSound() {
    if (!source) return;
    silentPos = ((audioCtx.currentTime - soundStart) % data.duration + data.duration) % data.duration;
    source.stop();
    source.disconnect();
    source = null;
    audioCtx.suspend();
    soundButton.setAttribute("aria-pressed", "false");
    soundLabel.textContent = "Play with sound";
  }

  soundButton.addEventListener("click", () => {
    if (soundOn()) disableSound(); else enableSound();
  });

  // ------------------------------------------------------------ boot

  if ("IntersectionObserver" in window) {
    new IntersectionObserver((entries) => {
      visible = entries[0].isIntersecting;
    }, { threshold: 0.25 }).observe(screen);
  }

  async function load() {
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      audioCtx = new Ctx();
      const bytes = await (await fetch(AUDIO_URL)).arrayBuffer();
      buffer = await new Promise((resolve, reject) => {
        const p = audioCtx.decodeAudioData(bytes, resolve, reject);
        if (p && p.then) p.then(resolve, reject);
      });
      data = analyse(buffer);
      soundButton.disabled = false;
      soundLabel.textContent = "Play with sound";
      preloadFox();
    } catch (err) {
      soundLabel.textContent = "Demo unavailable";
      console.warn("Fennec demo: could not load audio", err);
    }
  }

  // For inspection from the console: timeline marks and the current position.
  window.fennecDemo = {
    get timeline() {
      return data && { duration: data.duration, events: data.events.length, detectAt: data.detectAt,
        flatStart: data.flatStart, flatEnd: data.flatEnd, doneAt: data.doneAt };
    },
    get position() { return prevPos; },
    seek(s) { silentPos = s; },
    renderAt(s) { const p = phase(s); applyPhase(p); drawLine(s, p === "detected"); return p; },
    runFox() { foxRun = null; startFox(); },
  };

  // On phones, the fox also runs once, two seconds after the page loads.
  const MOBILE = window.matchMedia("(max-width: 767px)");
  const INTRO_DELAY = 2000;
  window.addEventListener("load", () => {
    if (!MOBILE.matches || reduceMotion.matches) return;
    preloadFox();
    const due = performance.now() + INTRO_DELAY;
    const tryStart = () => {
      // Wait for the image, and for the page to be on screen, so the
      // crossing is seen from its start rather than mid-run.
      if (foxReady && !document.hidden) startFox();
      else setTimeout(tryStart, 100);
    };
    setTimeout(tryStart, Math.max(0, due - performance.now()));
  });

  lastTick = performance.now();
  requestAnimationFrame(frame);
  load();
})();
