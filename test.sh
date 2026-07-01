#!/usr/bin/env bash
set -euo pipefail

# Génère l'arborescence complète du projet rtp-to-webrtc dans le
# répertoire courant (ou dans $1 si fourni).

PROJECT_DIR="${1:-rtp-to-webrtc}"

echo "Création du projet dans ./${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}/src" "${PROJECT_DIR}/static"

cat > "${PROJECT_DIR}/Cargo.toml" <<'EOF_CARGO_TOML'
[package]
name = "rtp-to-webrtc"
version = "0.1.0"
edition = "2021"

[dependencies]
# Coeur WebRTC (API async basée sur Tokio, branche stable 0.17.x)
webrtc = "0.17"

# Runtime async
tokio = { version = "1", features = ["full"] }

# Serveur HTTP de signaling + fichiers statiques
axum = "0.7"
tower-http = { version = "0.5", features = ["fs", "trace"] }

# (dé)sérialisation des messages SDP échangés avec le navigateur
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Logs
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

anyhow = "1"
bytes = "1"
EOF_CARGO_TOML

cat > "${PROJECT_DIR}/src/main.rs" <<'EOF_MAIN_RS'
//! rtp-to-webrtc
//!
//! Reçoit un flux RTP (VP8) sur un socket UDP local — envoyé par ffmpeg,
//! GStreamer, ou n'importe quel autre outil — et le relaie en direct vers
//! un ou plusieurs navigateurs via WebRTC.
//!
//! Architecture, en deux moitiés indépendantes :
//!
//!   [ ffmpeg/GStreamer ] --UDP:5004--> [ tâche rtp_listener ] --broadcast--> [ N connexions WebRTC ]
//!                                                                                  ^
//!                                                                     [ serveur HTTP axum: /offer ]
//!
//! Pourquoi un seul socket UDP + un `broadcast` channel plutôt qu'un socket
//! par connexion ? Parce que le flux RTP entrant est unique et indépendant
//! du nombre de navigateurs qui le regardent. On le lit une seule fois et
//! on le fan-out en mémoire vers chaque `PeerConnection` : ça évite le
//! `SO_REUSEADDR` et permet nativement plusieurs viewers simultanés (à la
//! manière de l'exemple `broadcast` du dépôt webrtc-rs).

use std::sync::Arc;

use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use bytes::Bytes;
use tokio::net::UdpSocket;
use tokio::sync::broadcast;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;

use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_VP8};
use webrtc::api::{APIBuilder, API};
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::track::track_local::track_local_static_rtp::TrackLocalStaticRTP;
use webrtc::track::track_local::{TrackLocal, TrackLocalWriter};

/// Port UDP sur lequel on attend le flux RTP entrant (voir README pour les
/// commandes ffmpeg/GStreamer).
const RTP_LISTEN_ADDR: &str = "127.0.0.1:5004";
/// Port HTTP servant la page web et le endpoint de signaling.
const HTTP_LISTEN_ADDR: &str = "0.0.0.0:8080";

#[derive(Clone)]
struct AppState {
    /// L'API webrtc-rs, construite une seule fois au démarrage (elle porte
    /// le MediaEngine + les interceptors, coûteuse à recréer par connexion).
    api: Arc<API>,
    /// Chaque paquet RTP lu sur le socket UDP est diffusé ici. Une
    /// connexion WebRTC = un nouvel abonné (`subscribe()`).
    rtp_tx: broadcast::Sender<Bytes>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "rtp_to_webrtc=info,tower_http=info".into()),
        )
        .init();

    let api = Arc::new(build_webrtc_api()?);

    // Capacité du channel : marge pour absorber un burst si un abonné est
    // temporairement lent (perte de paquets plutôt que blocage — cohérent
    // avec la nature best-effort de RTP).
    let (rtp_tx, _) = broadcast::channel::<Bytes>(1024);

    let udp_socket = UdpSocket::bind(RTP_LISTEN_ADDR).await?;
    tracing::info!("en écoute RTP (UDP) sur {RTP_LISTEN_ADDR}");
    tokio::spawn(rtp_listener(udp_socket, rtp_tx.clone()));

    let state = AppState { api, rtp_tx };

    let app = Router::new()
        .route("/offer", post(offer_handler))
        .nest_service("/", ServeDir::new("static"))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(HTTP_LISTEN_ADDR).await?;
    tracing::info!("interface web disponible sur http://{HTTP_LISTEN_ADDR}");
    axum::serve(listener, app).await?;

    Ok(())
}

/// Construit l'objet `API` webrtc-rs : moteur média (codecs) + interceptors
/// (NACK, RTCP reports, etc.). À faire une seule fois pour tout le process.
fn build_webrtc_api() -> anyhow::Result<API> {
    let mut media_engine = MediaEngine::default();
    media_engine.register_default_codecs()?;

    let mut registry = Registry::new();
    registry = register_default_interceptors(registry, &mut media_engine)?;

    Ok(APIBuilder::new()
        .with_media_engine(media_engine)
        .with_interceptor_registry(registry)
        .build())
}

/// Boucle infinie : lit des datagrammes UDP et les redistribue tels quels
/// (ce sont déjà des paquets RTP sérialisés) à tous les abonnés du channel.
async fn rtp_listener(socket: UdpSocket, tx: broadcast::Sender<Bytes>) {
    // MTU réseau classique ; largement suffisant pour un paquet RTP/VP8.
    let mut buf = vec![0u8; 1500];
    loop {
        match socket.recv(&mut buf).await {
            Ok(n) => {
                // send() ne renvoie une erreur que s'il n'y a aucun abonné :
                // c'est normal tant qu'aucun navigateur n'est connecté, on
                // ignore donc l'erreur plutôt que de logguer en boucle.
                let _ = tx.send(Bytes::copy_from_slice(&buf[..n]));
            }
            Err(e) => {
                tracing::error!("lecture du socket UDP interrompue: {e}");
                break;
            }
        }
    }
}

/// POST /offer
///
/// Reçoit l'offre SDP générée par le navigateur (`RTCPeerConnection.
/// createOffer()`), crée une `PeerConnection` côté serveur avec une piste
/// vidéo sortante, répond avec l'answer SDP correspondante.
///
/// Négociation "non-trickle" : on attend la fin de la collecte ICE avant de
/// répondre, pour ne renvoyer qu'un seul SDP complet. Plus simple à
/// implémenter qu'un échange trickle-ICE bidirectionnel, au prix d'une
/// latence de connexion un peu plus élevée — largement suffisant ici.
async fn offer_handler(
    State(state): State<AppState>,
    Json(offer): Json<RTCSessionDescription>,
) -> Result<Json<RTCSessionDescription>, AppError> {
    let config = RTCConfiguration {
        ice_servers: vec![RTCIceServer {
            urls: vec!["stun:stun.l.google.com:19302".to_owned()],
            ..Default::default()
        }],
        ..Default::default()
    };

    let peer_connection = Arc::new(state.api.new_peer_connection(config).await?);

    // Piste vidéo sortante : c'est elle qu'on alimente avec les paquets RTP
    // reçus par UDP. Le navigateur la recevra via l'évènement `ontrack`.
    let video_track = Arc::new(TrackLocalStaticRTP::new(
        RTCRtpCodecCapability {
            mime_type: MIME_TYPE_VP8.to_owned(),
            ..Default::default()
        },
        "video".to_owned(),
        "rtp-to-webrtc".to_owned(),
    ));

    let rtp_sender = peer_connection
        .add_track(Arc::clone(&video_track) as Arc<dyn TrackLocal + Send + Sync>)
        .await?;

    // Les RTCP (PLI, NACK...) renvoyés par le navigateur doivent être lus
    // en continu, sinon leur buffer interne se bloque et casse la piste.
    // On ne s'intéresse pas à leur contenu ici, juste à les drainer.
    tokio::spawn(async move {
        let mut rtcp_buf = vec![0u8; 1500];
        while rtp_sender.read(&mut rtcp_buf).await.is_ok() {}
    });

    // Un abonnement dédié par connexion : chaque navigateur reçoit sa
    // propre copie du flux, indépendamment des autres.
    let mut rtp_rx = state.rtp_tx.subscribe();
    let forward_track = Arc::clone(&video_track);
    tokio::spawn(async move {
        while let Ok(packet) = rtp_rx.recv().await {
            if let Err(e) = forward_track.write(&packet).await {
                // Piste fermée (navigateur déconnecté) : on arrête la tâche.
                tracing::debug!("relais RTP terminé: {e}");
                break;
            }
        }
    });

    {
        let pc = Arc::clone(&peer_connection);
        peer_connection.on_peer_connection_state_change(Box::new(move |s: RTCPeerConnectionState| {
            tracing::info!("état de la connexion: {s}");
            if s == RTCPeerConnectionState::Failed {
                let pc = Arc::clone(&pc);
                tokio::spawn(async move {
                    let _ = pc.close().await;
                });
            }
            Box::pin(async {})
        }));
    }

    peer_connection.set_remote_description(offer).await?;

    let answer = peer_connection.create_answer(None).await?;

    // On s'abonne à la promesse de fin de collecte ICE *avant* de fixer la
    // description locale : c'est ce qui déclenche la collecte.
    let mut gather_complete = peer_connection.gathering_complete_promise().await;
    peer_connection.set_local_description(answer).await?;
    let _ = gather_complete.recv().await;

    let local_description = peer_connection
        .local_description()
        .await
        .ok_or_else(|| anyhow::anyhow!("description locale absente après la collecte ICE"))?;

    Ok(Json(local_description))
}

/// Wrapper d'erreur pour convertir `anyhow::Error` / `webrtc::Error` en
/// réponse HTTP 500 lisible côté client (utile pendant le développement).
struct AppError(anyhow::Error);

impl axum::response::IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        tracing::error!("erreur lors du traitement de l'offre: {:#}", self.0);
        (StatusCode::INTERNAL_SERVER_ERROR, self.0.to_string()).into_response()
    }
}

impl<E> From<E> for AppError
where
    E: Into<anyhow::Error>,
{
    fn from(err: E) -> Self {
        Self(err.into())
    }
}
EOF_MAIN_RS

cat > "${PROJECT_DIR}/static/index.html" <<'EOF_INDEX_HTML'
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
    Le serveur relaie tel quel le flux RTP (VP8) qu'il reçoit sur
    <code>UDP :5004</code> — envoyé par ffmpeg ou GStreamer — vers cette page.
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
  </section>
</main>

<footer>
  <strong>Émettre un flux de test :</strong><br>
  gst-launch-1.0 videotestsrc ! video/x-raw,width=640,height=480 ! vp8enc deadline=1 ! rtpvp8pay ! udpsink host=127.0.0.1 port=5004<br>
  ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 -vcodec libvpx -deadline realtime -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"
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
  function waitForIceGatheringComplete(peerConnection) {
    if (peerConnection.iceGatheringState === 'complete') return Promise.resolve();
    return new Promise((resolve) => {
      function check() {
        if (peerConnection.iceGatheringState === 'complete') {
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
EOF_INDEX_HTML

cat > "${PROJECT_DIR}/README.md" <<'EOF_README_MD'
# rtp-to-webrtc

Relais d'un flux RTP (VP8) reçu en UDP vers un ou plusieurs navigateurs via
WebRTC, basé sur `webrtc-rs`. Inspiré de l'exemple officiel
[`rtp-to-webrtc`](https://github.com/webrtc-rs/webrtc/tree/master/examples/examples/rtp-to-webrtc),
mais avec :

- un serveur HTTP (`axum`) qui sert la page web **et** le endpoint de
  signaling `/offer`, au lieu du copier-coller de SDP en ligne de commande
  de l'exemple d'origine ;
- un seul socket UDP diffusé (`tokio::sync::broadcast`) vers toutes les
  connexions WebRTC actives, pour supporter plusieurs viewers simultanés
  sans rouvrir un socket par client.

## Structure

```
rtp-to-webrtc/
├── Cargo.toml
├── src/main.rs      # serveur : réception RTP + signaling WebRTC
└── static/index.html # page web : négociation + lecture vidéo + stats live
```

## Choix techniques (à valider/ajuster selon vos contraintes)

- **Négociation non-trickle** (on attend `gathering_complete_promise` avant
  de répondre) : plus simple à implémenter côté serveur ET côté client
  qu'un échange trickle-ICE bidirectionnel, au prix d'une latence de
  connexion un peu plus élevée. Pour de la production avec beaucoup de
  clients ou des réseaux difficiles, le trickle ICE serait préférable —
  je peux l'ajouter si besoin.
- **Un seul socket UDP + `broadcast` channel** plutôt qu'un socket par
  connexion : le flux RTP entrant est unique, indépendant du nombre de
  navigateurs. C'est aussi ce que fait l'exemple `broadcast` du dépôt
  webrtc-rs, en plus simple.
- **VP8** comme codec, comme l'exemple d'origine (large compatibilité
  navigateur, encodeur logiciel simple avec ffmpeg/GStreamer). Passer en
  H.264 est possible mais demande un encodeur matériel ou plus de réglages
  côté ffmpeg pour la compatibilité navigateur.

## Lancer le serveur

```bash
cargo run
```

- Interface web : http://localhost:8080
- Port RTP (UDP) : `127.0.0.1:5004`

## Envoyer un flux de test

Avec GStreamer :

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,width=640,height=480 ! \
  vp8enc error-resilient=partitions keyframe-max-dist=10 auto-alt-ref=true cpu-used=5 deadline=1 ! \
  rtpvp8pay ! udpsink host=127.0.0.1 port=5004
```

Avec ffmpeg :

```bash
ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 \
  -vcodec libvpx -cpu-used 5 -deadline realtime -g 10 -error-resilient 1 -auto-alt-ref 1 \
  -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"
```

Ouvrez ensuite http://localhost:8080 et cliquez sur « Se connecter ».

## Note sur la vérification de compilation

J'ai tenté de compiler ce projet dans mon bac à sable pour le valider,
mais le seul `rustc` disponible via `apt` (1.75.0, Ubuntu 24.04) est trop
ancien pour la profondeur actuelle de l'arbre de dépendances de `webrtc`
et `axum` (certaines crates transitives exigent désormais l'édition 2024).
Le réseau du bac à sable ne permet pas d'installer `rustup`/une toolchain
plus récente. J'ai donc relu le code à la main et vérifié chaque signature
d'API douteuse (`TrackLocalStaticRTP::write`, `gathering_complete_promise`,
`on_peer_connection_state_change`, etc.) sur `docs.rs`, mais je vous
recommande un `cargo build` de votre côté (avec une toolchain stable
récente, ≥ 1.82) avant de considérer le code comme définitif — dites-moi
les éventuelles erreurs et je corrige.

## Pistes d'amélioration

- Trickle ICE pour réduire la latence de connexion.
- Support audio (Opus) en plus de la vidéo.
- Fermeture propre des `PeerConnection` en écoutant l'état `Disconnected`
  côté serveur (actuellement seul `Failed` déclenche `close()`).
EOF_README_MD

echo "Terminé. Pour lancer :"
echo "  cd ${PROJECT_DIR} && cargo run"
