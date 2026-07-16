#!/usr/bin/env bash
set -euo pipefail

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
socket2 = "0.5"
EOF_CARGO_TOML

cat > "${PROJECT_DIR}/src/main.rs" <<'EOF_SRC_main'
//! rtp-to-webrtc
//!
//! Reçoit un flux RTP/H.264 sur un socket UDP (unicast ou multicast) et le
//! relaie en direct vers un ou plusieurs navigateurs via WebRTC.
//!
//! Architecture, en deux moitiés indépendantes :
//!
//!   [ source RTP ] --UDP:5004--> [ tâche listener ] --broadcast--> [ N connexions WebRTC ]
//!                                                                          ^
//!                                                             [ serveur HTTP axum: /offer ]
//!
//! Un seul socket UDP + un `broadcast` channel (plutôt qu'un socket par
//! connexion) : le flux RTP entrant est unique, indépendant du nombre de
//! navigateurs. On le lit une fois et on le diffuse en mémoire à chaque
//! `PeerConnection`.
//!
//! Découpage en modules :
//!   - `net`      : ouverture du socket UDP/multicast
//!   - `reorder`  : tampon de réordonnancement RTP (gigue réseau)
//!   - `h264`     : cache SPS/PPS (paramètres de décodage)
//!   - `listener` : boucle d'écoute + fan-out
//!   - `session`  : API webrtc-rs, piste vidéo, handler /offer
//!   - `error`    : conversion d'erreur en réponse HTTP

mod error;
mod h264;
mod listener;
mod net;
mod reorder;
mod session;

use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex};

use axum::routing::post;
use axum::Router;
use bytes::Bytes;
use tokio::net::UdpSocket;
use tokio::sync::broadcast;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;

use crate::session::AppState;

/// Adresse:port UDP d'écoute du flux RTP entrant.
const RTP_LISTEN_ADDR: &str = "127.0.0.1:5004";
/// Groupe multicast à rejoindre, ou `None` pour de l'unicast simple.
const MULTICAST_GROUP: Option<Ipv4Addr> = Some(Ipv4Addr::new(239, 0, 0, 1));
/// Adresse:port HTTP servant la page web et le endpoint de signaling.
const HTTP_LISTEN_ADDR: &str = "0.0.0.0:8080";
/// Capacité du broadcast : marge pour absorber un burst si un abonné est
/// momentanément lent (perte plutôt que blocage — cohérent avec RTP).
const BROADCAST_CAPACITY: usize = 1024;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();

    let api = Arc::new(session::build_api()?);
    let (rtp_tx, _) = broadcast::channel::<Bytes>(BROADCAST_CAPACITY);
    let sps_pps = Arc::new(Mutex::new(h264::ParameterSets::default()));

    let socket = UdpSocket::from_std(net::bind_rtp_socket(RTP_LISTEN_ADDR, MULTICAST_GROUP)?)?;
    tracing::info!("en écoute RTP (UDP) sur {RTP_LISTEN_ADDR}");
    tokio::spawn(listener::run(socket, rtp_tx.clone(), Arc::clone(&sps_pps)));

    let state = AppState { api, rtp_tx, sps_pps };
    let app = Router::new()
        .route("/offer", post(session::offer_handler))
        .nest_service("/", ServeDir::new("static"))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(HTTP_LISTEN_ADDR).await?;
    tracing::info!("interface web disponible sur http://{HTTP_LISTEN_ADDR}");
    axum::serve(listener, app).await?;

    Ok(())
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "rtp_to_webrtc=info,tower_http=info".into()),
        )
        .init();
}
EOF_SRC_main

cat > "${PROJECT_DIR}/src/error.rs" <<'EOF_SRC_error'
//! Conversion des erreurs internes en réponse HTTP 500 lisible.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

/// Enveloppe `anyhow::Error` pour l'exposer en HTTP 500 (pratique en
/// développement pour voir la cause côté client).
pub struct AppError(anyhow::Error);

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
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
EOF_SRC_error

cat > "${PROJECT_DIR}/src/net.rs" <<'EOF_SRC_net'
//! Ouverture du socket UDP d'écoute RTP (unicast ou multicast).

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket};

use socket2::{Domain, Socket, Type};

/// Ouvre le socket UDP d'écoute RTP.
///
/// Si `multicast_group` est renseigné, rejoint explicitement le groupe via
/// `IP_ADD_MEMBERSHIP` — un simple `bind()` sur l'adresse multicast NE
/// SUFFIT PAS : le noyau ne route les paquets multicast vers ce socket que
/// si on a explicitement demandé à rejoindre le groupe. C'est le piège qui
/// expliquait le "je ne reçois rien" en multicast.
pub fn bind_rtp_socket(
    listen_addr: &str,
    multicast_group: Option<Ipv4Addr>,
) -> anyhow::Result<UdpSocket> {
    let port = parse_port(listen_addr)?;

    let socket = Socket::new(Domain::IPV4, Type::DGRAM, None)?;
    socket.set_reuse_address(true)?;

    match multicast_group {
        Some(group) => {
            // Bind sur "any" + le port, PAS sur l'adresse du groupe
            // elle-même — contre-intuitif mais c'est ce qu'attend le noyau.
            socket.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())?;
            socket.join_multicast_v4(&group, &Ipv4Addr::UNSPECIFIED)?;
            tracing::info!("groupe multicast {group} rejoint sur le port {port}");
        }
        None => {
            socket.bind(&listen_addr.parse::<SocketAddr>()?.into())?;
        }
    }

    socket.set_nonblocking(true)?;
    Ok(socket.into())
}

fn parse_port(listen_addr: &str) -> anyhow::Result<u16> {
    listen_addr
        .rsplit(':')
        .next()
        .and_then(|p| p.parse().ok())
        .ok_or_else(|| anyhow::anyhow!("port introuvable dans {listen_addr}"))
}
EOF_SRC_net

cat > "${PROJECT_DIR}/src/reorder.rs" <<'EOF_SRC_reorder'
//! Tampon de réordonnancement RTP minimal.
//!
//! Absorbe le désordre et la gigue typiques d'une vraie interface réseau.
//! Constat en pratique : le loopback livre les paquets dans l'ordre, mais
//! une interface réelle (surtout en multicast) peut les réordonner, ce qui
//! casse le décodage côté navigateur sans ce tampon.

use std::collections::BTreeMap;

use bytes::Bytes;
use tokio::time::{Duration, Instant};

/// Délai pendant lequel un paquet est retenu avant d'être relayé — laisse
/// le temps aux paquets arrivés en désordre de "rattraper" leur place. Un
/// vrai jitter buffer (GStreamer, etc.) adapte ce délai dynamiquement ;
/// ici c'est volontairement fixe et simple.
pub const JITTER_DELAY: Duration = Duration::from_millis(50);

/// Fréquence à laquelle on vérifie si des paquets sont prêts à sortir du
/// tampon. Doit rester petit devant `JITTER_DELAY` pour ne pas ajouter de
/// latence significative.
pub const REORDER_TICK: Duration = Duration::from_millis(5);

/// Étend le numéro de séquence RTP 16 bits (qui reboucle après 65536
/// paquets) en un compteur 32 bits monotone. Sans ça, le tri par numéro de
/// séquence se casserait à chaque rebouclage (0 redeviendrait "avant"
/// 65535).
#[derive(Default)]
struct SeqExtender {
    last_seq16: Option<u16>,
    wraps: u32,
}

impl SeqExtender {
    fn extend(&mut self, seq16: u16) -> u32 {
        if let Some(last) = self.last_seq16 {
            // Écart signé en arithmétique 16 bits : un grand saut négatif
            // signale un rebouclage (65535 → 0) ; un grand saut positif, un
            // paquet très en retard d'avant un rebouclage déjà compté.
            let delta = seq16.wrapping_sub(last) as i16;
            if delta < -0x4000 {
                self.wraps += 1;
            } else if delta > 0x4000 {
                self.wraps = self.wraps.saturating_sub(1);
            }
        }
        self.last_seq16 = Some(seq16);
        (self.wraps << 16) | seq16 as u32
    }
}

/// Tampon de réordonnancement. Un paquet toujours manquant après
/// `JITTER_DELAY` est considéré perdu : on saute par-dessus plutôt que de
/// bloquer indéfiniment le flux.
#[derive(Default)]
pub struct ReorderBuffer {
    packets: BTreeMap<u32, (Bytes, Instant)>,
    next_expected: Option<u32>,
    extender: SeqExtender,
}

impl ReorderBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Insère un paquet à sa position selon son numéro de séquence RTP
    /// (octets 2-3 de l'en-tête, big-endian — RFC 3550 §5.1). Lu
    /// directement : un seul champ à taille fixe, pas besoin d'un parseur
    /// RTP complet ici.
    pub fn insert(&mut self, packet: Bytes) {
        let Some(seq_bytes) = packet.get(2..4) else {
            return; // trop court pour être un en-tête RTP valide
        };
        let seq16 = u16::from_be_bytes([seq_bytes[0], seq_bytes[1]]);
        let extended = self.extender.extend(seq16);
        self.packets.insert(extended, (packet, Instant::now()));
    }

    /// Déplace dans `out` tous les paquets prêts à être relayés, dans
    /// l'ordre, en sautant les manquants dont le délai d'attente est
    /// dépassé.
    pub fn drain_ready(&mut self, out: &mut Vec<Bytes>) {
        while let Some((&seq, &(_, arrival))) = self.packets.iter().next() {
            // Paquet retardataire pour une place déjà comblée : on le jette.
            if matches!(self.next_expected, Some(expected) if seq < expected) {
                self.packets.remove(&seq);
                continue;
            }

            let waited_enough = arrival.elapsed() >= JITTER_DELAY;
            let is_next = match self.next_expected {
                Some(expected) => seq >= expected,
                None => true,
            };

            if waited_enough && is_next {
                let (packet, _) = self.packets.remove(&seq).expect("clé itérée à l'instant");
                out.push(packet);
                // Si seq > expected, des paquets ont été perdus : on saute.
                self.next_expected = Some(seq.wrapping_add(1));
            } else {
                break; // le prochain paquet attendu n'a pas fini d'attendre
            }
        }
    }
}
EOF_SRC_reorder

cat > "${PROJECT_DIR}/src/h264.rs" <<'EOF_SRC_h264'
//! Cache des paramètres H.264 (SPS/PPS).
//!
//! Les SPS/PPS ne sont parfois envoyés qu'une fois au tout début du flux.
//! Un navigateur qui se connecte après ne les reçoit alors jamais, et son
//! décodeur H.264 échoue sur chaque frame ("no decodable frame"). On garde
//! donc en cache les derniers SPS/PPS vus passer, pour les réinjecter au
//! début du flux de chaque nouvelle connexion — indépendamment du réglage
//! `config-interval` côté source.

use std::sync::{Arc, Mutex};

use bytes::Bytes;
use webrtc::rtp::codecs::h264::H264Packet;
use webrtc::rtp::packetizer::Depacketizer;

/// Type NAL "Sequence Parameter Set".
const NAL_SPS: u8 = 7;
/// Type NAL "Picture Parameter Set".
const NAL_PPS: u8 = 8;
/// Types NAL des paquets d'agrégation/fragmentation (RFC 6184 §5.6-5.8) —
/// un SPS/PPS peut s'y cacher, donc on ne peut pas les écarter sur le seul
/// type de surface, il faut dépaqueter pour en avoir le cœur net.
const NAL_STAP_A: u8 = 24;
const NAL_FU_A: u8 = 28;
const NAL_FU_B: u8 = 29;

/// Longueur d'un en-tête RTP sans extension ni CSRC — le cas de notre flux.
const RTP_HEADER_LEN: usize = 12;

/// Derniers SPS et PPS observés, chacun sous forme du paquet RTP complet
/// prêt à être réécrit dans une piste sortante.
#[derive(Clone, Default)]
pub struct ParameterSets {
    pub sps: Option<Bytes>,
    pub pps: Option<Bytes>,
}

/// Cache partagé entre la tâche d'écoute RTP (qui le met à jour) et les
/// connexions WebRTC (qui le lisent à l'établissement).
pub type SharedParameterSets = Arc<Mutex<ParameterSets>>;

/// Met à jour le cache si `packet` transporte un SPS ou un PPS.
///
/// Optimisation du chemin chaud : la grande majorité des paquets sont des
/// slices vidéo, pas des SPS/PPS. On lit d'abord le type NAL de surface
/// (un octet, aucune allocation) et on ne construit un `H264Packet` /
/// dépaquetise réellement que pour les rares paquets susceptibles de
/// contenir un jeu de paramètres (single-NAL SPS/PPS, ou agrégat/fragment
/// qui pourrait en cacher un).
pub fn update_cache(packet: &Bytes, cache: &SharedParameterSets) {
    let Some(surface_type) = surface_nal_type(packet) else {
        return;
    };

    match surface_type {
        // Cas simple et courant : le paquet EST directement un SPS/PPS.
        NAL_SPS => store(cache, packet, |c| &mut c.sps),
        NAL_PPS => store(cache, packet, |c| &mut c.pps),
        // Agrégat/fragment : coûteux mais rare — on dépaquetise pour voir.
        NAL_STAP_A | NAL_FU_A | NAL_FU_B => inspect_aggregated(packet, cache),
        _ => {} // slice vidéo courant : rien à faire, chemin le moins cher
    }
}

/// Type NAL porté par le premier octet du payload RTP (5 bits de poids
/// faible), sans dépaquetiser. `None` si le paquet est trop court.
fn surface_nal_type(packet: &Bytes) -> Option<u8> {
    packet.get(RTP_HEADER_LEN).map(|b| b & 0x1F)
}

/// Chemin lent : dépaquetise réellement pour extraire le type NAL contenu
/// dans un agrégat (STAP-A) ou reconstitué depuis des fragments (FU-A/B).
fn inspect_aggregated(packet: &Bytes, cache: &SharedParameterSets) {
    let Ok(rtp_packet) = webrtc::rtp::packet::Packet::unmarshal(&mut packet.clone()) else {
        return;
    };
    let Ok(payload) = H264Packet::default().depacketize(&rtp_packet.payload) else {
        return;
    };

    // Payload dépaquetisé au format Annex B : start code puis NAL unit.
    let Some(nal_type) = payload
        .iter()
        .position(|&b| b == 0x01)
        .and_then(|sc_end| payload.get(sc_end + 1))
        .map(|first| first & 0x1F)
    else {
        return;
    };

    match nal_type {
        NAL_SPS => store(cache, packet, |c| &mut c.sps),
        NAL_PPS => store(cache, packet, |c| &mut c.pps),
        _ => {}
    }
}

/// Écrit le paquet dans le champ ciblé du cache (verrou pris brièvement).
fn store(cache: &SharedParameterSets, packet: &Bytes, field: fn(&mut ParameterSets) -> &mut Option<Bytes>) {
    if let Ok(mut c) = cache.lock() {
        *field(&mut c) = Some(packet.clone());
    }
}
EOF_SRC_h264

cat > "${PROJECT_DIR}/src/listener.rs" <<'EOF_SRC_listener'
//! Tâche d'écoute RTP : lit les datagrammes UDP, les réordonne, met à jour
//! le cache SPS/PPS au passage, et les diffuse à tous les abonnés.

use bytes::Bytes;
use tokio::net::UdpSocket;
use tokio::sync::broadcast;
use tokio::time::interval;

use crate::h264::{self, SharedParameterSets};
use crate::reorder::{ReorderBuffer, REORDER_TICK};

/// MTU réseau classique ; suffisant pour un paquet RTP/H.264 non fragmenté
/// (les NAL units plus grosses arrivent déjà fragmentées en FU-A, chaque
/// fragment tient dans ce buffer).
const RECV_BUF_LEN: usize = 1500;

/// Boucle infinie : lit des datagrammes, les fait transiter par le tampon
/// de réordonnancement, puis relaie ceux qui sont prêts.
pub async fn run(socket: UdpSocket, tx: broadcast::Sender<Bytes>, sps_pps: SharedParameterSets) {
    let mut buf = vec![0u8; RECV_BUF_LEN];
    let mut reorder = ReorderBuffer::new();
    let mut ticker = interval(REORDER_TICK);
    let mut ready = Vec::new();

    loop {
        tokio::select! {
            result = socket.recv(&mut buf) => match result {
                Ok(n) => reorder.insert(Bytes::copy_from_slice(&buf[..n])),
                Err(e) => {
                    tracing::error!("lecture du socket UDP interrompue: {e}");
                    break;
                }
            },
            _ = ticker.tick() => {
                reorder.drain_ready(&mut ready);
                for packet in ready.drain(..) {
                    h264::update_cache(&packet, &sps_pps);
                    // send() n'échoue que s'il n'y a aucun abonné : normal
                    // tant qu'aucun navigateur n'est connecté, on l'ignore.
                    let _ = tx.send(packet);
                }
            }
        }
    }
}
EOF_SRC_listener

cat > "${PROJECT_DIR}/src/session.rs" <<'EOF_SRC_session'
//! Construction de l'API webrtc-rs et gestion d'une session (endpoint
//! `/offer`) : création de la `PeerConnection`, piste vidéo sortante,
//! relais du flux RTP diffusé vers le navigateur.

use std::sync::Arc;

use axum::{extract::State, Json};
use bytes::Bytes;
use tokio::sync::broadcast;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264};
use webrtc::api::{APIBuilder, API};
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::track::track_local::track_local_static_rtp::TrackLocalStaticRTP;
use webrtc::track::track_local::{TrackLocal, TrackLocalWriter};

use crate::error::AppError;
use crate::h264::SharedParameterSets;

const STUN_SERVER: &str = "stun:stun.l.google.com:19302";
const H264_FMTP: &str = "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f";

/// État partagé injecté dans chaque handler axum.
#[derive(Clone)]
pub struct AppState {
    /// API webrtc-rs (MediaEngine + interceptors) — construite une fois,
    /// coûteuse à recréer par connexion.
    pub api: Arc<API>,
    /// Diffuse chaque paquet RTP lu sur le socket. Une connexion = un
    /// abonné (`subscribe()`).
    pub rtp_tx: broadcast::Sender<Bytes>,
    /// Cache SPS/PPS, réinjecté au début de chaque nouvelle connexion.
    pub sps_pps: SharedParameterSets,
}

/// Construit l'objet `API` : moteur média (codecs) + interceptors (NACK,
/// rapports RTCP...). À faire une seule fois pour tout le process.
pub fn build_api() -> anyhow::Result<API> {
    let mut media_engine = MediaEngine::default();
    media_engine.register_default_codecs()?;

    let registry = register_default_interceptors(Registry::new(), &mut media_engine)?;

    Ok(APIBuilder::new()
        .with_media_engine(media_engine)
        .with_interceptor_registry(registry)
        .build())
}

/// `POST /offer` — reçoit l'offre SDP du navigateur, crée une
/// `PeerConnection` avec une piste vidéo sortante, renvoie l'answer.
///
/// Négociation "non-trickle" : on attend la fin de la collecte ICE avant de
/// répondre, pour ne renvoyer qu'un seul SDP complet. Plus simple qu'un
/// échange trickle bidirectionnel, au prix d'un peu de latence à la
/// connexion.
pub async fn offer_handler(
    State(state): State<AppState>,
    Json(offer): Json<RTCSessionDescription>,
) -> Result<Json<RTCSessionDescription>, AppError> {
    let config = RTCConfiguration {
        ice_servers: vec![RTCIceServer {
            urls: vec![STUN_SERVER.to_owned()],
            ..Default::default()
        }],
        ..Default::default()
    };

    let pc = Arc::new(state.api.new_peer_connection(config).await?);
    let video_track = Arc::new(new_video_track());

    let rtp_sender = pc
        .add_track(Arc::clone(&video_track) as Arc<dyn TrackLocal + Send + Sync>)
        .await?;

    drain_rtcp(rtp_sender);
    spawn_forwarder(&state, Arc::clone(&video_track));
    close_on_failure(&pc);

    pc.set_remote_description(offer).await?;
    let answer = pc.create_answer(None).await?;

    // S'abonner à la fin de collecte ICE *avant* set_local_description :
    // c'est set_local_description qui déclenche la collecte.
    let mut gather_complete = pc.gathering_complete_promise().await;
    pc.set_local_description(answer).await?;
    let _ = gather_complete.recv().await;

    let local = pc
        .local_description()
        .await
        .ok_or_else(|| anyhow::anyhow!("description locale absente après la collecte ICE"))?;

    Ok(Json(local))
}

/// La piste vidéo H.264 sortante, alimentée par le flux RTP entrant.
fn new_video_track() -> TrackLocalStaticRTP {
    TrackLocalStaticRTP::new(
        RTCRtpCodecCapability {
            mime_type: MIME_TYPE_H264.to_owned(),
            clock_rate: 90_000,
            channels: 0,
            sdp_fmtp_line: H264_FMTP.to_owned(),
            rtcp_feedback: vec![],
        },
        "video".to_owned(),
        "rtp-to-webrtc".to_owned(),
    )
}

/// Draine en continu les RTCP (PLI, NACK...) renvoyés par le navigateur.
/// Sans cette lecture, le buffer interne se bloque et casse la piste. On
/// ne s'intéresse pas au contenu, seulement à vider le buffer.
fn drain_rtcp(rtp_sender: Arc<webrtc::rtp_transceiver::rtp_sender::RTCRtpSender>) {
    tokio::spawn(async move {
        let mut buf = vec![0u8; 1500];
        while rtp_sender.read(&mut buf).await.is_ok() {}
    });
}

/// Abonne cette connexion au flux diffusé et relaie chaque paquet vers sa
/// piste. Réinjecte d'abord les SPS/PPS en cache (best effort — la
/// connexion peut ne pas être tout à fait prête, le flux live prend le
/// relais ensuite).
fn spawn_forwarder(state: &AppState, track: Arc<TrackLocalStaticRTP>) {
    let mut rtp_rx = state.rtp_tx.subscribe();
    let sps_pps = Arc::clone(&state.sps_pps);

    tokio::spawn(async move {
        if let Some((sps, pps)) = snapshot_parameter_sets(&sps_pps) {
            if let Some(sps) = sps {
                let _ = track.write(&sps).await;
            }
            if let Some(pps) = pps {
                let _ = track.write(&pps).await;
            }
        }

        while let Ok(packet) = rtp_rx.recv().await {
            if let Err(e) = track.write(&packet).await {
                tracing::debug!("relais RTP terminé (navigateur déconnecté ?): {e}");
                break;
            }
        }
    });
}

/// Copie les SPS/PPS hors du verrou pour ne pas le tenir pendant les
/// écritures asynchrones (`.await`).
fn snapshot_parameter_sets(sps_pps: &SharedParameterSets) -> Option<(Option<Bytes>, Option<Bytes>)> {
    let guard = sps_pps.lock().ok()?;
    Some((guard.sps.clone(), guard.pps.clone()))
}

/// Ferme proprement la `PeerConnection` si elle passe en état `Failed`.
fn close_on_failure(pc: &Arc<webrtc::peer_connection::RTCPeerConnection>) {
    let pc_weak = Arc::downgrade(pc);
    pc.on_peer_connection_state_change(Box::new(move |s: RTCPeerConnectionState| {
        tracing::info!("état de la connexion: {s}");
        if s == RTCPeerConnectionState::Failed {
            if let Some(pc) = pc_weak.upgrade() {
                tokio::spawn(async move {
                    let _ = pc.close().await;
                });
            }
        }
        Box::pin(async {})
    }));
}
EOF_SRC_session

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
    <code>UDP :5004</code> — envoyé par GStreamer/ffmpeg capturant la Virtual
    Camera d'OBS Studio, ou en ligne de commande — vers cette page.
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
  <strong>OBS Studio :</strong> démarrez la Virtual Camera (bouton en bas à droite), puis capturez-la avec GStreamer/ffmpeg en VP8 (ci-dessous).
  La sortie RTP directe d'OBS (Custom Output FFmpeg) n'est pas utilisée : elle ne propose que du H.264, dont le décodage côté navigateur s'est
  révélé peu fiable selon les builds Chromium. Détails dans le README.<br><br>
  <strong>Flux de test :</strong><br>
  gst-launch-1.0 videotestsrc ! video/x-raw,width=640,height=480 ! vp8enc deadline=1 cpu-used=5 ! rtpvp8pay ! udpsink host=127.0.0.1 port=5004 sync=true<br>
  ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 -c:v libvpx -deadline realtime -cpu-used 5 -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"<br><br>
  <strong>Depuis la Virtual Camera OBS (Linux, /dev/video10) :</strong><br>
  ffmpeg -f v4l2 -i /dev/video10 -c:v libvpx -deadline realtime -cpu-used 5 -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"
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
EOF_INDEX_HTML

cat > "${PROJECT_DIR}/README.md" <<'EOF_README_MD'
# rtp-to-webrtc

Relais d'un flux RTP (VP8) reçu en UDP vers un ou plusieurs navigateurs via
WebRTC, basé sur `webrtc-rs`. Inspiré de l'exemple officiel
[`rtp-to-webrtc`](https://github.com/webrtc-rs/webrtc/tree/master/examples/examples/rtp-to-webrtc),
avec :

- un serveur HTTP (`axum`) qui sert la page web **et** le endpoint de
  signaling `/offer`, au lieu du copier-coller de SDP en ligne de commande
  de l'exemple d'origine ;
- un seul socket UDP diffusé (`tokio::sync::broadcast`) vers toutes les
  connexions WebRTC actives, pour supporter plusieurs viewers simultanés
  sans rouvrir un socket par client ;
- un panneau de debug affichant en direct les candidats ICE collectés par
  le navigateur (`static/index.html`), utile pour diagnostiquer des
  blocages de connexion sans naviguer dans `chrome://webrtc-internals`.

## Structure

```
rtp-to-webrtc/
├── Cargo.toml
├── src/main.rs      # serveur : réception RTP + signaling WebRTC
└── static/index.html # page web : négociation + lecture vidéo + stats live
```

## Pourquoi VP8 (et pas H.264)

On est passé par H.264 à un moment (pour utiliser la sortie RTP native
d'OBS Studio, qui ne propose que des encodeurs H.264), mais ça s'est avéré
peu fiable : le décodeur H.264 *spécifique à WebRTC* dans Chromium
(`modules/video_coding/codecs/h264/`, un module FFmpeg distinct du
décodeur H.264 générique utilisé par `<video>`) dépend de flags de
compilation qui varient selon les versions/builds de Chromium. En
pratique, il peut être présent et fonctionnel sur une machine, absent ou
cassé sur une autre — même Chromium, même méthode d'installation,
versions différentes. Le symptôme typique dans les logs Chromium :

```
avcodec_open2 error ...
decoder_database failed to initialize decoder
```

VP8 est libre de droits et systématiquement compilé dans tout Chromium
standards-compliant, sans cette variabilité — c'est le choix le plus
robuste pour un déploiement dont on ne maîtrise pas le navigateur cible.

## Lancer le serveur

```bash
cargo run
```

- Interface web : http://localhost:8080
- Port RTP (UDP) : `127.0.0.1:5004`

## Émettre depuis OBS Studio (via la Virtual Camera)

La sortie RTP directe d'OBS (Custom Output FFmpeg) n'est **pas** utilisée
ici : elle n'offre que des encodeurs H.264, écarté pour la raison
ci-dessus. On passe par la Virtual Camera d'OBS, capturée par un vrai
ffmpeg/GStreamer qui encode en VP8.

**1. Activer la Virtual Camera (Linux)** — nécessite `v4l2loopback`,
absent par défaut :

```bash
sudo apt install v4l2loopback-dkms   # ou pacman/dnf selon la distro
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="OBS Virtual Camera" exclusive_caps=1
```

Pour que ça persiste après redémarrage :

```bash
echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback devices=1 video_nr=10 card_label="OBS Virtual Camera" exclusive_caps=1' | sudo tee /etc/modprobe.d/v4l2loopback.conf
```

Vérifiez avec `v4l2-ctl --list-devices` que `/dev/video10` apparaît, puis
démarrez la Virtual Camera dans OBS (bouton en bas à droite).

**2. Capturer et streamer en VP8**

```bash
ffmpeg -f v4l2 -i /dev/video10 -c:v libvpx -deadline realtime -cpu-used 5 -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"
```

(adaptez `-f v4l2 -i /dev/video10` selon l'OS : `dshow` sur Windows,
`avfoundation` sur macOS)

## Flux de test sans OBS

GStreamer :

```bash
gst-launch-1.0 videotestsrc ! video/x-raw,width=640,height=480 ! \
  vp8enc deadline=1 cpu-used=5 ! rtpvp8pay ! udpsink host=127.0.0.1 port=5004 sync=true
```

ffmpeg :

```bash
ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 \
  -c:v libvpx -deadline realtime -cpu-used 5 \
  -f rtp "rtp://127.0.0.1:5004?pkt_size=1200"
```

Pour streamer un **fichier** plutôt qu'une source de test, remplacez la
source par `filesrc location=... ! decodebin ! videoconvert` (GStreamer)
ou `-re -i fichier.mp4` (ffmpeg) — le `-re`/`sync=true` est essentiel : il
force la lecture au rythme réel plutôt qu'en rafale.

## Pièges rencontrés en pratique (et retenus pour la suite)

- **Écran noir au départ** : si le navigateur se connecte après le début
  du flux, il peut rater la première keyframe et rester noir jusqu'à la
  suivante. Le plus fiable reste de connecter le navigateur avant de
  démarrer l'émission.
- **`bind() :::0 failed` dans les logs Chromium** : dans notre cas, ça
  s'est avéré être un candidat ICE IPv6 qui bloquait indéfiniment
  `iceGatheringState` sur une machine précise (jamais reproduit ailleurs).
  `static/index.html` a maintenant un timeout de 3s sur l'attente de fin
  de collecte ICE côté client (voir `waitForIceGatheringComplete`) pour ne
  plus jamais bloquer indéfiniment sur ce genre de cas.
- **Paquets RTP reçus (confirmé par la console de stats) mais rien ne
  s'affiche** : dans notre cas, c'était le décodeur H.264 WebRTC absent
  sur une version de Chromium précise (voir section VP8 ci-dessus) — pas
  un problème réseau. Si ça se reproduit en VP8, vérifier plutôt le
  panneau "Candidats ICE (debug)" et `chrome://webrtc-internals`.
- **Sur Oracle Cloud (OCI) spécifiquement** : penser aux Security
  Lists/Network Security Groups du VCN, une couche indépendante de
  `firewalld` côté OS.
- **OBS + sortie RTP directe (Custom Output FFmpeg)** : le muxer `rtp`
  intégré à l'ffmpeg embarqué dans OBS s'est montré peu fiable
  (`Invalid argument` à l'ouverture du socket) sur plusieurs versions —
  d'où le choix de la Virtual Camera plutôt que de s'acharner dessus.

## Choix techniques (à valider/ajuster selon vos contraintes)

- **Négociation non-trickle avec timeout de secours** : on attend
  `gathering_complete_promise` côté serveur, et côté client un maximum de
  3s avant d'envoyer l'offre avec les candidats déjà obtenus. Un vrai
  trickle ICE bidirectionnel serait plus robuste sur des réseaux
  difficiles, mais demande de faire transiter les candidats individuels
  après l'échange SDP initial — plus de code des deux côtés.
- **Un seul socket UDP + `broadcast` channel** plutôt qu'un socket par
  connexion : le flux RTP entrant est unique, indépendant du nombre de
  navigateurs.

## Pistes d'amélioration

- Trickle ICE complet pour réduire encore la latence de connexion.
- Support audio (Opus) en plus de la vidéo.
- Fermeture propre des `PeerConnection` en écoutant l'état `Disconnected`
  côté serveur (actuellement seul `Failed` déclenche `close()`).
EOF_README_MD

echo "Terminé. Pour lancer :"
echo "  cd ${PROJECT_DIR} && cargo run"
