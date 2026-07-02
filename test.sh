<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>rtp-to-webrtc · console de réception</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #10131a;
    --panel: #171b24;
    --panel-border: #262c39;
    --text: #e7e5df;
    --muted: #8a8f9c;
    --amber: #e8a33d;
    --teal: #4fd1c5;
    --red: #e2574c;
    --mono: "IBM Plex Mono", ui-monospace, monospace;
    --display: "Space Grotesk", sans-serif;
  }

  * { box-sizing: border-box; }

  body {
    margin: 0;
    min-height: 100vh;
    background:
      radial-gradient(circle at 15% 0%, rgba(232, 163, 61, 0.06), transparent 45%),
      var(--bg);
    color: var(--text);
    font-family: var(--display);
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 48px 20px 80px;
  }

  header {
    width: 100%;
    max-width: 980px;
    margin-bottom: 32px;
  }

  .eyebrow {
    font-family: var(--mono);
    font-size: 12px;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--amber);
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .eyebrow::before {
    content: "";
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--amber);
  }

  h1 {
    font-size: clamp(28px, 4vw, 40px);
    font-weight: 700;
    margin: 10px 0 6px;
    letter-spacing: -0.01em;
  }

  p.lede {
    color: var(--muted);
    font-size: 15px;
    max-width: 620px;
    line-height: 1.55;
    margin: 0;
  }

  code {
    font-family: var(--mono);
    background: rgba(255,255,255,0.06);
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 0.92em;
  }

  main {
    width: 100%;
    max-width: 980px;
    display: grid;
    grid-template-columns: 1.5fr 1fr;
    gap: 20px;
  }

  @media (max-width: 760px) {
    main { grid-template-columns: 1fr; }
  }

  .panel {
    background: var(--panel);
    border: 1px solid var(--panel-border);
    border-radius: 14px;
    overflow: hidden;
  }

  .monitor {
    display: flex;
    flex-direction: column;
  }

  .screen {
    position: relative;
    aspect-ratio: 16 / 9;
    background:
      repeating-linear-gradient(0deg, rgba(255,255,255,0.02) 0 1px, transparent 1px 3px),
      #05070b;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .screen video {
    width: 100%;
    height: 100%;
    object-fit: contain;
    background: #000;
  }

  .screen .placeholder {
    font-family: var(--mono);
    color: var(--muted);
    font-size: 13px;
    text-align: center;
    padding: 0 24px;
  }

  .screen .placeholder .big {
    font-size: 34px;
    color: #2c3242;
    margin-bottom: 10px;
  }

  .controls {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 16px 20px;
    border-top: 1px solid var(--panel-border);
  }

  button#connect {
    font-family: var(--display);
    font-weight: 600;
    font-size: 14px;
    background: var(--amber);
    color: #1a1305;
    border: none;
    padding: 10px 22px;
    border-radius: 8px;
    cursor: pointer;
    transition: filter 0.15s ease, transform 0.15s ease;
  }

  button#connect:hover { filter: brightness(1.08); }
  button#connect:active { transform: scale(0.98); }
  button#connect:disabled { opacity: 0.5; cursor: default; }

  .status-line {
    font-family: var(--mono);
    font-size: 13px;
    color: var(--muted);
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--muted);
    flex-shrink: 0;
    transition: background 0.2s ease, box-shadow 0.2s ease;
  }
  .dot.live { background: var(--teal); box-shadow: 0 0 8px var(--teal); }
  .dot.err { background: var(--red); box-shadow: 0 0 8px var(--red); }

  .readout {
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 18px;
  }

  .readout h2 {
    font-family: var(--mono);
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.1em;
    color: var(--muted);
    margin: 0 0 10px;
    font-weight: 500;
  }

  .stat-row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    font-family: var(--mono);
    font-size: 13px;
    padding: 7px 0;
    border-bottom: 1px dashed var(--panel-border);
  }
  .stat-row:last-child { border-bottom: none; }

  .stat-row .k { color: var(--muted); }
  .stat-row .v { color: var(--text); font-weight: 500; }
  .stat-row .v.accent { color: var(--teal); }

  .bars {
    display: flex;
    align-items: flex-end;
    gap: 3px;
    height: 28px;
    margin-top: 4px;
  }
  .bars span {
    flex: 1;
    background: var(--panel-border);
    border-radius: 2px;
    height: 15%;
    transition: height 0.25s ease, background 0.25s ease;
  }
  .bars span.on { background: var(--teal); }

  footer {
    max-width: 980px;
    width: 100%;
    margin-top: 26px;
    font-family: var(--mono);
    font-size: 12.5px;
    color: var(--muted);
    line-height: 1.7;
  }
  footer strong { color: var(--text); font-weight: 500; }
</style>
</head>
<body>

<header>
  <div class="eyebrow">rtp · webrtc-rs</div>
  <h1>Console de réception RTP&nbsp;→&nbsp;WebRTC</h1>
  <p class="lede">
    Ce navigateur négocie une connexion WebRTC avec le serveur Rust.
    Le serveur relaie tel quel le flux RTP (H.264) qu'il reçoit sur
    <code>UDP :5004</code> — envoyé par OBS Studio (sortie FFmpeg personnalisée),
    ffmpeg, ou GStreamer — vers cette page.
  </p>
</header>

<main>
  <section class="panel monitor">
    <div class="screen">
      <video id="video" autoplay playsinline></video>
      <div class="placeholder" id="placeholder">
        <div class="big">◌</div>
        aucun flux — cliquez sur « Se connecter »
      </div>
    </div>
    <div class="controls">
      <button id="connect">Se connecter</button>
      <div class="status-line">
        <span class="dot" id="dot"></span>
        <span id="status-text">déconnecté</span>
      </div>
    </div>
  </section>

  <section class="panel readout">
    <div>
      <h2>Connexion</h2>
      <div class="stat-row"><span class="k">état ICE</span><span class="v" id="ice-state">—</span></div>
      <div class="stat-row"><span class="k">état signaling</span><span class="v" id="signaling-state">—</span></div>
      <div class="stat-row"><span class="k">codec</span><span class="v" id="codec">—</span></div>
    </div>
    <div>
      <h2>Flux entrant (getStats)</h2>
      <div class="stat-row"><span class="k">paquets RTP reçus</span><span class="v accent" id="packets">0</span></div>
      <div class="stat-row"><span class="k">débit</span><span class="v accent" id="bitrate">0 kbps</span></div>
      <div class="stat-row"><span class="k">paquets perdus</span><span class="v" id="lost">0</span></div>
      <div class="bars" id="bars"></div>
    </div>
    <div>
      <h2>Candidats ICE (debug)</h2>
      <pre id="ice-log" style="font-family:var(--mono);font-size:11.5px;color:var(--muted);white-space:pre-wrap;margin:0;max-height:180px;overflow-y:auto;line-height:1.6">en attente de connexion…</pre>
    </div>
  </section>
</main>

<footer>
  <strong>OBS Studio :</strong> Réglages → Sortie → Mode avancé → Enregistrement → Type : Sortie personnalisée (FFmpeg) →
  URL <code>rtp://127.0.0.1:5004</code>, conteneur <code>rtp</code>, encodeur H.264, audio désactivé. Détails dans le README.<br><br>
  <strong>Flux de test (sans OBS) :</strong><br>
  gst-launch-1.0 videotestsrc ! video/x-raw,width=640,height=480 ! x264enc tune=zerolatency speed-preset=ultrafast ! rtph264pay config-interval=1 ! udpsink host=127.0.0.1 port=5004 sync=true<br>
  ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 -c:v libx264 -profile:v baseline -preset ultrafast -tune zerolatency -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"
</footer>

<script>
(() => {
  const connectBtn = document.getElementById('connect');
  const videoEl = document.getElementById('video');
  const placeholder = document.getElementById('placeholder');
  const dot = document.getElementById('dot');
  const statusText = document.getElementById('status-text');
  const iceStateEl = document.getElementById('ice-state');
  const signalingStateEl = document.getElementById('signaling-state');
  const codecEl = document.getElementById('codec');
  const packetsEl = document.getElementById('packets');
  const bitrateEl = document.getElementById('bitrate');
  const lostEl = document.getElementById('lost');
  const barsEl = document.getElementById('bars');
  const iceLogEl = document.getElementById('ice-log');

  const BAR_COUNT = 24;
  for (let i = 0; i < BAR_COUNT; i++) {
    const s = document.createElement('span');
    barsEl.appendChild(s);
  }
  const bars = [...barsEl.children];
  let barCursor = 0;

  let pc = null;
  let statsTimer = null;
  let lastBytes = 0;
  let lastTimestamp = 0;

  function setStatus(text, mode) {
    statusText.textContent = text;
    dot.className = 'dot' + (mode ? ' ' + mode : '');
  }

  // Attend la fin de la collecte ICE locale : on préfère un échange SDP
  // "non-trickle" côté client aussi, symétrique à ce que fait le serveur.
  //
  // Filet de sécurité : un timeout de 3s. Sur certaines machines,
  // iceGatheringState peut ne jamais atteindre 'complete' (observé avec un
  // échec de bind() sur une famille d'adresse absente du noyau) — sans ce
  // timeout, connect() reste bloqué indéfiniment avant même d'appeler
  // /offer. On envoie alors l'offre avec les candidats déjà collectés
  // plutôt que d'attendre éternellement les derniers.
  function waitForIceGatheringComplete(peerConnection, timeoutMs = 3000) {
    if (peerConnection.iceGatheringState === 'complete') return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        peerConnection.removeEventListener('icegatheringstatechange', check);
        iceLogEl.textContent += `[timeout] collecte ICE non terminée après ${timeoutMs}ms — envoi avec les candidats déjà obtenus\n`;
        resolve();
      }, timeoutMs);
      function check() {
        if (peerConnection.iceGatheringState === 'complete') {
          clearTimeout(timer);
          peerConnection.removeEventListener('icegatheringstatechange', check);
          resolve();
        }
      }
      peerConnection.addEventListener('icegatheringstatechange', check);
    });
  }

  async function connect() {
    connectBtn.disabled = true;
    setStatus('négociation…', null);

    pc = new RTCPeerConnection({
      iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
    });

    iceLogEl.textContent = '';
    let candidateCount = 0;
    pc.onicecandidate = (event) => {
      const t = new Date().toISOString().slice(11, 23);
      if (event.candidate) {
        candidateCount++;
        const c = event.candidate;
        // c.type = host / srflx / relay / prflx — c'est LA ligne qui nous
        // intéresse : si on ne voit jamais "host", rien n'est généré
        // localement, indépendamment du réseau externe.
        iceLogEl.textContent += `[${t}] candidat #${candidateCount} — type=${c.type} proto=${c.protocol} adresse=${c.address}:${c.port}\n`;
      } else {
        iceLogEl.textContent += `[${t}] fin de la collecte ICE (${candidateCount} candidat(s) au total)\n`;
      }
      iceLogEl.scrollTop = iceLogEl.scrollHeight;
    };
    pc.onicegatheringstatechange = () => {
      const t = new Date().toISOString().slice(11, 23);
      iceLogEl.textContent += `[${t}] iceGatheringState → ${pc.iceGatheringState}\n`;
      iceLogEl.scrollTop = iceLogEl.scrollHeight;
    };

    // On ne fait que recevoir : c'est le serveur qui pousse la vidéo.
    pc.addTransceiver('video', { direction: 'recvonly' });

    pc.ontrack = (event) => {
      videoEl.srcObject = event.streams[0];
      placeholder.style.display = 'none';
    };

    pc.oniceconnectionstatechange = () => {
      iceStateEl.textContent = pc.iceConnectionState;
      if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
        setStatus('en direct', 'live');
      } else if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected') {
        setStatus('connexion perdue', 'err');
      }
    };
    pc.onsignalingstatechange = () => {
      signalingStateEl.textContent = pc.signalingState;
    };

    try {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitForIceGatheringComplete(pc);

      const res = await fetch('/offer', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(pc.localDescription),
      });
      if (!res.ok) throw new Error(`le serveur a répondu ${res.status}`);
      const answer = await res.json();
      await pc.setRemoteDescription(answer);

      startStatsPolling();
      connectBtn.textContent = 'Se déconnecter';
      connectBtn.disabled = false;
      connectBtn.onclick = disconnect;
    } catch (err) {
      console.error(err);
      setStatus(`erreur : ${err.message}`, 'err');
      connectBtn.disabled = false;
    }
  }

  function disconnect() {
    stopStatsPolling();
    if (pc) { pc.close(); pc = null; }
    videoEl.srcObject = null;
    placeholder.style.display = '';
    setStatus('déconnecté', null);
    iceStateEl.textContent = '—';
    signalingStateEl.textContent = '—';
    codecEl.textContent = '—';
    packetsEl.textContent = '0';
    bitrateEl.textContent = '0 kbps';
    lostEl.textContent = '0';
    bars.forEach(b => { b.style.height = '15%'; b.classList.remove('on'); });
    connectBtn.textContent = 'Se connecter';
    connectBtn.onclick = connect;
  }

  function pushBar(active) {
    const bar = bars[barCursor % BAR_COUNT];
    bar.style.height = active ? (30 + Math.random() * 70) + '%' : '15%';
    bar.classList.toggle('on', active);
    barCursor++;
  }

  function startStatsPolling() {
    lastBytes = 0;
    lastTimestamp = 0;
    statsTimer = setInterval(async () => {
      if (!pc) return;
      const stats = await pc.getStats();
      stats.forEach((report) => {
        if (report.type === 'inbound-rtp' && report.kind === 'video') {
          packetsEl.textContent = report.packetsReceived ?? 0;
          lostEl.textContent = report.packetsLost ?? 0;

          if (lastTimestamp && report.bytesReceived != null) {
            const deltaBytes = report.bytesReceived - lastBytes;
            const deltaMs = report.timestamp - lastTimestamp;
            if (deltaMs > 0) {
              const kbps = Math.max(0, Math.round((deltaBytes * 8) / deltaMs));
              bitrateEl.textContent = `${kbps} kbps`;
              pushBar(kbps > 0);
            }
          }
          lastBytes = report.bytesReceived ?? lastBytes;
          lastTimestamp = report.timestamp;
        }
        if (report.type === 'codec' && report.mimeType) {
          codecEl.textContent = report.mimeType;
        }
      });
    }, 800);
  }

  function stopStatsPolling() {
    if (statsTimer) clearInterval(statsTimer);
    statsTimer = null;
  }

  connectBtn.onclick = connect;
})();
</script>

</body>
</html>
