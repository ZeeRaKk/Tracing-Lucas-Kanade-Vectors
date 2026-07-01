#!/usr/bin/env bash
set -euo pipefail

# Crée l'arborescence complète du projet rtp-bridge dans le dossier courant.
# Usage: ./gen_rtp_bridge.sh

PROJECT_DIR="rtp-bridge"

if [ -d "$PROJECT_DIR" ]; then
  echo "Erreur: le dossier '$PROJECT_DIR' existe déjà. Supprime-le ou lance ce script ailleurs." >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/src" "$PROJECT_DIR/static"
cd "$PROJECT_DIR"

cat > Cargo.toml << 'CARGO_EOF'
[package]
name = "rtp-bridge"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full"] }
webrtc = "0.11"
sdp = "0.6"
axum = { version = "0.7", features = ["ws"] }
tokio-tungstenite = "0.23"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
tracing = "0.1"
tracing-subscriber = "0.3"
futures-util = "0.3"
CARGO_EOF

cat > src/main.rs << 'MAIN_EOF'
mod sdp_parser;
mod signaling;

use anyhow::{Context, Result};
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
    routing::get,
    Router,
};
use futures_util::{SinkExt, StreamExt};
use signaling::SignalMsg;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tracing::{error, info, warn};
use webrtc::{
    api::{
        interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
        APIBuilder,
    },
    ice_transport::{ice_candidate::RTCIceCandidateInit, ice_server::RTCIceServer},
    interceptor::registry::Registry,
    peer_connection::{configuration::RTCConfiguration, sdp::session_description::RTCSessionDescription},
    rtp_transceiver::{
        rtp_codec::{RTCRtpCodecCapability, RTCRtpCodecParameters, RTPCodecType},
        rtp_transceiver_direction::RTCRtpTransceiverDirection,
        RTCRtpTransceiverInit,
    },
    track::track_local::{track_local_static_rtp::TrackLocalStaticRTP, TrackLocal},
};

// ---- Config en dur pour rester lisible. À sortir en argv/env si besoin. ----
const SDP_FILE_PATH: &str = "source.sdp";
const HTTP_BIND_ADDR: &str = "0.0.0.0:8080";

#[derive(Clone)]
struct AppState {
    track_info: Arc<sdp_parser::VideoTrackInfo>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    // 1. Parse le SDP source une fois au démarrage pour connaître le codec réel.
    let sdp_content = std::fs::read_to_string(SDP_FILE_PATH)
        .with_context(|| format!("impossible de lire {SDP_FILE_PATH}"))?;
    let track_info = sdp_parser::parse_sdp_file(&sdp_content)?;
    info!(
        "SDP source parsé: PT={} codec={} clock={} port={} fmtp={:?}",
        track_info.payload_type,
        track_info.mime_type,
        track_info.clock_rate,
        track_info.rtp_port,
        track_info.fmtp
    );

    let state = AppState {
        track_info: Arc::new(track_info),
    };

    // 2. Serveur HTTP/WS : sert index.html + endpoint de signaling.
    let app = Router::new()
        .route("/", get(serve_index))
        .route("/ws", get(ws_handler))
        .with_state(state);

    info!("Serveur démarré sur http://{HTTP_BIND_ADDR}");
    let listener = tokio::net::TcpListener::bind(HTTP_BIND_ADDR).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn serve_index() -> impl IntoResponse {
    axum::response::Html(include_str!("../static/index.html"))
}

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_signaling(socket, state))
}

/// Une session = un viewer = une PeerConnection dédiée, alimentée par le même flux RTP.
/// Pour du multi-viewer il faudrait un fan-out du flux RTP décodé une fois vers N tracks ;
/// ici on garde volontairement simple : un viewer à la fois se branche sur le socket UDP.
async fn handle_signaling(socket: WebSocket, state: AppState) {
    if let Err(e) = run_session(socket, state).await {
        error!("session terminée en erreur: {e:#}");
    }
}

async fn run_session(socket: WebSocket, state: AppState) -> Result<()> {
    let (mut ws_tx, mut ws_rx) = socket.split();

    // ---- Setup MediaEngine avec le codec exact déduit du SDP source ----
    let mut media_engine = MediaEngine::default();
    let capability = RTCRtpCodecCapability {
        mime_type: state.track_info.mime_type.clone(),
        clock_rate: state.track_info.clock_rate,
        channels: 0,
        sdp_fmtp_line: state.track_info.fmtp.clone().unwrap_or_default(),
        rtcp_feedback: vec![],
    };
    media_engine.register_codec(
        RTCRtpCodecParameters {
            capability: capability.clone(),
            payload_type: state.track_info.payload_type,
            ..Default::default()
        },
        RTPCodecType::Video,
    )?;

    let mut registry = Registry::new();
    registry = register_default_interceptors(registry, &mut media_engine)?;

    let api = APIBuilder::new()
        .with_media_engine(media_engine)
        .with_interceptor_registry(registry)
        .build();

    let config = RTCConfiguration {
        ice_servers: vec![RTCIceServer {
            urls: vec!["stun:stun.l.google.com:19302".to_owned()],
            ..Default::default()
        }],
        ..Default::default()
    };

    let pc = Arc::new(api.new_peer_connection(config).await?);

    // Track locale alimentée par le flux RTP source
    let video_track = Arc::new(TrackLocalStaticRTP::new(
        capability,
        "video".to_owned(),
        "rtp-bridge".to_owned(),
    ));

    pc.add_transceiver_from_track(
        Arc::clone(&video_track) as Arc<dyn TrackLocal + Send + Sync>,
        Some(RTCRtpTransceiverInit {
            direction: RTCRtpTransceiverDirection::Sendonly,
            send_encodings: vec![],
        }),
    )
    .await?;

    // Toute écriture sur le WebSocket passe par ce channel unique, pour éviter
    // de devoir cloner/partager le sink ws_tx entre plusieurs tâches.
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<SignalMsg>();

    let ice_out_tx = out_tx.clone();
    pc.on_ice_candidate(Box::new(move |candidate| {
        let ice_out_tx = ice_out_tx.clone();
        Box::pin(async move {
            if let Some(candidate) = candidate {
                if let Ok(init) = candidate.to_json() {
                    let _ = ice_out_tx.send(SignalMsg::Ice { candidate: init });
                }
            }
        })
    }));

    // ---- Crée l'offer et l'envoie au navigateur ----
    let offer = pc.create_offer(None).await?;
    pc.set_local_description(offer.clone()).await?;
    out_tx.send(SignalMsg::Offer { sdp: offer.sdp })?;

    // ---- Tâche d'écriture: unique propriétaire de ws_tx ----
    let send_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if let Ok(text) = serde_json::to_string(&msg) {
                if ws_tx.send(Message::Text(text)).await.is_err() {
                    break;
                }
            }
        }
    });

    // ---- Tâche de lecture: reçoit answer + ICE candidates du navigateur ----
    let pc_for_rx = Arc::clone(&pc);
    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = ws_rx.next().await {
            let Message::Text(text) = msg else { continue };
            match serde_json::from_str::<SignalMsg>(&text) {
                Ok(SignalMsg::Answer { sdp }) => {
                    let answer = match RTCSessionDescription::answer(sdp) {
                        Ok(a) => a,
                        Err(e) => {
                            error!("answer SDP invalide reçu du navigateur: {e}");
                            continue;
                        }
                    };
                    if let Err(e) = pc_for_rx.set_remote_description(answer).await {
                        error!("set_remote_description a échoué: {e}");
                    }
                }
                Ok(SignalMsg::Ice { candidate }) => {
                    if let Err(e) = pc_for_rx.add_ice_candidate(candidate).await {
                        warn!("add_ice_candidate a échoué: {e}");
                    }
                }
                Ok(SignalMsg::Offer { .. }) => {
                    warn!("offer inattendue reçue côté serveur, ignorée");
                }
                Err(e) => warn!("message de signaling illisible: {e}"),
            }
        }
    });

    // ---- Boucle de forward RTP: lit le socket UDP source et écrit dans la track ----
    let rtp_task = {
        let track_info = Arc::clone(&state.track_info);
        tokio::spawn(async move {
            if let Err(e) = forward_rtp(track_info, video_track).await {
                error!("boucle RTP terminée en erreur: {e:#}");
            }
        })
    };

    tokio::select! {
        _ = recv_task => {},
        _ = send_task => {},
        _ = rtp_task => {},
    }

    Ok(())
}

/// Lit en continu les paquets RTP depuis le socket UDP source, filtre par
/// payload type attendu (au cas où plusieurs flux arrivent sur le même port),
/// et les réinjecte dans la track WebRTC locale.
async fn forward_rtp(
    track_info: Arc<sdp_parser::VideoTrackInfo>,
    track: Arc<TrackLocalStaticRTP>,
) -> Result<()> {
    let socket = UdpSocket::bind(("0.0.0.0", track_info.rtp_port))
        .await
        .with_context(|| format!("bind UDP échoué sur le port {}", track_info.rtp_port))?;
    info!("écoute RTP sur 0.0.0.0:{}", track_info.rtp_port);

    let mut buf = [0u8; 1500];
    loop {
        let (len, _addr) = socket.recv_from(&mut buf).await?;
        let mut pkt_buf = &buf[..len];

        let packet = match webrtc::rtp::packet::Packet::unmarshal(&mut pkt_buf) {
            Ok(p) => p,
            Err(e) => {
                warn!("paquet RTP illisible, ignoré: {e}");
                continue;
            }
        };

        if packet.header.payload_type != track_info.payload_type {
            // probablement un autre flux (ex: audio mêlé sur le même port) -> on ignore
            continue;
        }

        if let Err(e) = track.write_rtp(&packet).await {
            warn!("écriture RTP vers la track a échoué: {e}");
        }
    }
}
MAIN_EOF

cat > src/sdp_parser.rs << 'SDPP_EOF'
use anyhow::{anyhow, Context, Result};
use sdp::description::session::SessionDescription;
use std::io::Cursor;

/// Ce qu'on extrait du .sdp source pour configurer la track WebRTC
/// et filtrer les paquets RTP entrants.
#[derive(Debug, Clone)]
pub struct VideoTrackInfo {
    pub payload_type: u8,
    pub mime_type: String, // ex: "video/H264"
    pub clock_rate: u32,
    pub fmtp: Option<String>, // ex: "profile-level-id=42e01f;packetization-mode=1"
    pub rtp_port: u16,
}

pub fn parse_sdp_file(sdp_content: &str) -> Result<VideoTrackInfo> {
    let mut reader = Cursor::new(sdp_content.as_bytes());
    let sdp = SessionDescription::unmarshal(&mut reader).context("SDP invalide ou illisible")?;

    let media = sdp
        .media_descriptions
        .iter()
        .find(|m| m.media_name.media == "video")
        .ok_or_else(|| anyhow!("aucune section 'm=video' trouvée dans le SDP"))?;

    let rtp_port = media.media_name.port.value as u16;

    let pt_str = media
        .media_name
        .formats
        .first()
        .ok_or_else(|| anyhow!("aucun payload type déclaré pour la section video"))?;
    let payload_type: u8 = pt_str.parse().context("payload type non numérique")?;

    // Cherche l'attribut a=rtpmap:<pt> <codec>/<clockrate>
    let rtpmap_value = media
        .attributes
        .iter()
        .find(|a| a.key == "rtpmap")
        .and_then(|a| a.value.clone())
        .ok_or_else(|| anyhow!("aucun a=rtpmap trouvé pour PT {payload_type}"))?;

    let mut parts = rtpmap_value.split_whitespace();
    let found_pt: u8 = parts
        .next()
        .ok_or_else(|| anyhow!("rtpmap malformé"))?
        .parse()
        .context("PT du rtpmap non numérique")?;
    if found_pt != payload_type {
        return Err(anyhow!(
            "incohérence: PT déclaré dans m=video ({payload_type}) != PT du rtpmap ({found_pt})"
        ));
    }

    let codec_clock = parts
        .next()
        .ok_or_else(|| anyhow!("rtpmap sans partie codec/clockrate"))?;
    let mut codec_parts = codec_clock.split('/');
    let codec_name = codec_parts
        .next()
        .ok_or_else(|| anyhow!("rtpmap sans nom de codec"))?
        .to_uppercase();
    let clock_rate: u32 = codec_parts
        .next()
        .unwrap_or("90000")
        .parse()
        .unwrap_or(90000);

    // fmtp optionnel (important pour H264 : profile-level-id, packetization-mode)
    let fmtp = media
        .attributes
        .iter()
        .find(|a| a.key == "fmtp")
        .and_then(|a| a.value.clone())
        .and_then(|v| v.split_once(' ').map(|(_, params)| params.to_string()));

    Ok(VideoTrackInfo {
        payload_type,
        mime_type: format!("video/{codec_name}"),
        clock_rate,
        fmtp,
        rtp_port,
    })
}
SDPP_EOF

cat > src/signaling.rs << 'SIG_EOF'
use serde::{Deserialize, Serialize};
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

/// Messages échangés sur le WebSocket de signaling, dans les deux sens.
/// Le tag "type" permet au JS de faire un simple switch sur le champ.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SignalMsg {
    Offer { sdp: String },
    Answer { sdp: String },
    Ice { candidate: RTCIceCandidateInit },
}
SIG_EOF

cat > static/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>RTP → WebRTC Viewer</title>
<style>
  body { font-family: sans-serif; background: #111; color: #eee; text-align: center; }
  video { width: 80%; max-width: 900px; margin-top: 20px; background: #000; }
  #status { font-family: monospace; margin-top: 10px; color: #8f8; }
  #status.error { color: #f88; }
</style>
</head>
<body>
  <h1>Flux RTP relayé en WebRTC</h1>
  <video id="video" autoplay playsinline controls></video>
  <div id="status">connexion...</div>

<script>
(() => {
  const videoEl = document.getElementById('video');
  const statusEl = document.getElementById('status');

  const setStatus = (text, isError = false) => {
    statusEl.textContent = text;
    statusEl.className = isError ? 'error' : '';
  };

  const wsProtocol = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${wsProtocol}://${location.host}/ws`);

  const pc = new RTCPeerConnection({
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
  });

  // On ne fait que recevoir de la vidéo, on n'envoie rien depuis le navigateur.
  pc.addTransceiver('video', { direction: 'recvonly' });

  pc.ontrack = (event) => {
    videoEl.srcObject = event.streams[0];
    setStatus('flux reçu, lecture en cours');
  };

  pc.oniceconnectionstatechange = () => {
    setStatus(`ICE: ${pc.iceConnectionState}`, pc.iceConnectionState === 'failed');
  };

  pc.onicecandidate = (event) => {
    if (event.candidate) {
      ws.send(JSON.stringify({ type: 'ice', candidate: event.candidate.toJSON() }));
    }
  };

  ws.onopen = () => setStatus('websocket connecté, attente de l\'offer serveur');

  ws.onerror = () => setStatus('erreur websocket', true);

  ws.onclose = () => setStatus('websocket fermé', true);

  ws.onmessage = async (msg) => {
    let data;
    try {
      data = JSON.parse(msg.data);
    } catch (e) {
      console.error('message de signaling illisible', e);
      return;
    }

    switch (data.type) {
      case 'offer': {
        await pc.setRemoteDescription({ type: 'offer', sdp: data.sdp });
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        ws.send(JSON.stringify({ type: 'answer', sdp: answer.sdp }));
        setStatus('answer envoyée, négociation ICE en cours');
        break;
      }
      case 'ice': {
        try {
          await pc.addIceCandidate(data.candidate);
        } catch (e) {
          console.warn('ICE candidate rejetée', e);
        }
        break;
      }
      default:
        console.warn('type de message inconnu:', data.type);
    }
  };
})();
</script>
</body>
</html>
HTML_EOF

cat > source.sdp.example << 'SDPEX_EOF'
v=0
o=- 0 0 IN IP4 127.0.0.1
s=RTP Stream
c=IN IP4 127.0.0.1
t=0 0
m=video 5004 RTP/AVP 96
a=rtpmap:96 H264/90000
a=fmtp:96 profile-level-id=42e01f;packetization-mode=1
SDPEX_EOF

cat > README.md << 'README_EOF'
# rtp-bridge

Relaie un flux RTP (vidéo) vers une page web via WebRTC, sans passer par un SFU externe.

## Utilisation

1. Place ton fichier SDP source à la racine sous le nom `source.sdp`
   (voir `source.sdp.example` pour le format attendu).
2. `cargo build --release`
3. `cargo run --release`
4. Ouvre `http://localhost:8080` dans un navigateur.
5. Pointe ta source RTP vers `udp://<ip-du-serveur>:<port du m=video dans le SDP>`.

## Ce que fait le code

- `src/sdp_parser.rs` : lit le `.sdp`, en extrait le payload type, le codec
  (mime_type), le clock rate, le `fmtp` et le port RTP attendu.
- `src/main.rs` :
  - configure un `MediaEngine` webrtc-rs avec **exactement** le codec déclaré
    dans le SDP (pas de négociation multi-codec, pas de devinette),
  - ouvre une session par connexion WebSocket entrante (`/ws`),
  - crée une `PeerConnection` + une `TrackLocalStaticRTP` en mode `sendonly`,
  - fait l'offer/answer + trickle ICE avec le navigateur via WebSocket,
  - écoute le port UDP indiqué dans le SDP, filtre les paquets par payload
    type, et les réinjecte tels quels dans la track (pas de transcodage).
- `static/index.html` : page unique, `RTCPeerConnection` natif du navigateur,
  pas de SDK externe. Affiche le flux dans une balise `<video>`.

## Limites connues / points à durcir si besoin

- **Un seul flux RTP consommé par session WebSocket.** Si deux navigateurs se
  connectent en même temps, chacun ouvre son propre `bind()` UDP sur le même
  port → ça va échouer au 2e `bind`. Pour du multi-viewer, il faut découpler
  la lecture UDP (une seule tâche globale) du fan-out vers plusieurs tracks
  via un channel broadcast — je peux l'ajouter si tu en as besoin.
- **Pas de gestion de perte de paquets / réordonnancement RTP** au-delà de ce
  que `webrtc-rs` fait nativement dans la track. Si ta source a du jitter
  important, il faudra un jitter buffer explicite.
- **`fmtp` recopié tel quel** depuis le SDP source. Si le navigateur cible ne
  supporte pas le profil H264 exact annoncé (ex: High Profile), la connexion
  s'établira mais l'image peut ne pas s'afficher — à vérifier avec ta source
  réelle.
- **Pas d'audio.** Si ton SDP a aussi une section `m=audio`, il faut dupliquer
  le mécanisme (deuxième `VideoTrackInfo`-like struct, deuxième track, filtre
  par PT séparé). Dis-le si c'est ton cas, je l'ajoute proprement.
README_EOF

cat > .gitignore << 'GITIGNORE_EOF'
/target
source.sdp
GITIGNORE_EOF


if command -v git >/dev/null 2>&1; then
  git init -q
  git config user.email "dev@example.com"
  git config user.name "rtp-bridge"
  git add -A
  git commit -q -m "Initial commit: RTP -> WebRTC bridge (Rust + webrtc-rs, single HTML page)"
  echo "Repo git initialisé avec un premier commit."
else
  echo "git non trouvé, dossier créé sans init git."
fi

echo "Projet généré dans ./$PROJECT_DIR"
echo "Prochaines étapes:"
echo "  1. cp <ton_fichier>.sdp $PROJECT_DIR/source.sdp"
echo "  2. cd $PROJECT_DIR && cargo build --release"
echo "  3. cargo run --release"
