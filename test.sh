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
        rtp_codec::RTCRtpCodecCapability,
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

    // ---- Setup MediaEngine avec le set de codecs par défaut de webrtc-rs ----
    // On n'enregistre plus le codec "à la main" à partir du SDP source : les
    // paramètres par défaut (clock rate, fmtp standard) sont ceux que les
    // navigateurs attendent réellement. On garde le SDP source uniquement
    // pour connaître le payload type et le port UDP à écouter (cf. plus bas).
    let mut media_engine = MediaEngine::default();
    media_engine.register_default_codecs()?;

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

    // Track locale: le mime_type doit matcher un codec connu de
    // register_default_codecs() (H264, VP8, VP9, Opus...) pour que le
    // navigateur puisse le négocier dans son answer.
    let video_capability = RTCRtpCodecCapability {
        mime_type: state.track_info.mime_type.clone(),
        clock_rate: state.track_info.clock_rate,
        channels: 0,
        sdp_fmtp_line: state.track_info.fmtp.clone().unwrap_or_default(),
        rtcp_feedback: vec![],
    };
    let video_track = Arc::new(TrackLocalStaticRTP::new(
        video_capability,
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
                    info!(
                        "candidate ICE générée: type={:?} protocol={:?} address={:?}",
                        init.candidate.split(' ').nth(7),
                        init.candidate.split(' ').nth(2),
                        init.candidate.split(' ').nth(4)
                    );
                    let _ = ice_out_tx.send(SignalMsg::Ice { candidate: init });
                }
            }
        })
    }));

    // Diagnostic: on veut voir précisément où ça casse entre gathering,
    // connectivity checks ICE, handshake DTLS, et l'état agrégé final.
    pc.on_ice_gathering_state_change(Box::new(move |state| {
        info!("ICE gathering state: {state}");
        Box::pin(async {})
    }));

    pc.on_ice_connection_state_change(Box::new(move |state| {
        info!("ICE connection state: {state}");
        Box::pin(async {})
    }));

    pc.on_peer_connection_state_change(Box::new(move |state| {
        info!("Peer connection state (ICE+DTLS agrégé): {state}");
        Box::pin(async {})
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

    // Compteurs de diagnostic, affichés périodiquement plutôt qu'à chaque
    // paquet (sinon les logs explosent à 30-60 paquets/sec).
    let mut total_received: u64 = 0;
    let mut total_wrong_pt: u64 = 0;
    let mut total_written: u64 = 0;
    let mut total_write_errors: u64 = 0;
    let mut last_report = tokio::time::Instant::now();
    let report_interval = std::time::Duration::from_secs(2);

    loop {
        let (len, addr) = socket.recv_from(&mut buf).await?;
        total_received += 1;

        // Premier paquet reçu = confirmation que le bind UDP capte bien du trafic.
        if total_received == 1 {
            info!("premier paquet RTP reçu depuis {addr}, {len} octets");
        }

        let mut pkt_buf = &buf[..len];
        let packet = match webrtc::rtp::packet::Packet::unmarshal(&mut pkt_buf) {
            Ok(p) => p,
            Err(e) => {
                warn!("paquet RTP illisible, ignoré: {e}");
                continue;
            }
        };

        if packet.header.payload_type != track_info.payload_type {
            total_wrong_pt += 1;
            if total_wrong_pt == 1 {
                warn!(
                    "PT reçu={} ne correspond pas au PT attendu={} (issu du SDP) — paquet ignoré",
                    packet.header.payload_type, track_info.payload_type
                );
            }
            continue;
        }

        match track.write_rtp(&packet).await {
            Ok(_) => total_written += 1,
            Err(e) => {
                total_write_errors += 1;
                if total_write_errors == 1 {
                    warn!("écriture RTP vers la track a échoué: {e}");
                }
            }
        }

        if last_report.elapsed() >= report_interval {
            info!(
                "RTP stats [2s]: reçus={total_received} pt_invalide={total_wrong_pt} écrits={total_written} erreurs_écriture={total_write_errors} ssrc={} seq={} marker={}",
                packet.header.ssrc, packet.header.sequence_number, packet.header.marker
            );
            last_report = tokio::time::Instant::now();
        }
    }
}
