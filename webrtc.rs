//! rtp-to-webrtc
//!
//! Reçoit un flux RTP (VP8) sur un socket UDP local — via GStreamer/ffmpeg
//! capturant la Virtual Camera d'OBS Studio, ou en ligne de commande — et
//! le relaie en direct vers un ou plusieurs navigateurs via WebRTC.
//!
//! Pourquoi VP8 et pas H.264 : le décodeur H.264 *spécifique à WebRTC*
//! dans Chromium (module modules/video_coding/codecs/h264/, distinct du
//! décodeur H.264 générique utilisé par <video>) est optionnel et dépend
//! de flags de compilation qui varient selon les builds/versions — testé
//! en pratique, il peut être absent ou cassé sur certaines installations
//! Chromium alors que le même codec fonctionne ailleurs. VP8 est libre de
//! droits et systématiquement compilé dans tout Chromium standards-
//! compliant, sans cette variabilité. Voir le README pour le pipeline
//! d'émission (Virtual Camera OBS + GStreamer/ffmpeg en VP8).
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

use std::collections::BTreeMap;
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
use tokio::time::{interval, Duration, Instant};
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
/// Adresse du groupe multicast à rejoindre. Mettre `None` pour repasser en
/// unicast simple (comportement d'origine, `RTP_LISTEN_ADDR` seul suffit).
const MULTICAST_GROUP: Option<std::net::Ipv4Addr> = Some(std::net::Ipv4Addr::new(239, 0, 0, 1));
/// Port HTTP servant la page web et le endpoint de signaling.
const HTTP_LISTEN_ADDR: &str = "0.0.0.0:8080";

/// Ouvre le socket UDP d'écoute RTP. Si `MULTICAST_GROUP` est renseigné,
/// rejoint explicitement le groupe via `IP_ADD_MEMBERSHIP` — un simple
/// `bind()` sur l'adresse multicast NE SUFFIT PAS : le noyau ne route les
/// paquets multicast vers ce socket que si on a explicitement demandé à
/// rejoindre le groupe. C'est le piège qui expliquait "je reçois rien".
fn bind_rtp_socket(listen_addr: &str) -> anyhow::Result<std::net::UdpSocket> {
    use socket2::{Domain, Socket, Type};

    let port: u16 = listen_addr
        .rsplit(':')
        .next()
        .and_then(|p| p.parse().ok())
        .ok_or_else(|| anyhow::anyhow!("port introuvable dans {listen_addr}"))?;

    let socket = Socket::new(Domain::IPV4, Type::DGRAM, None)?;
    socket.set_reuse_address(true)?;

    if let Some(group) = MULTICAST_GROUP {
        // Bind sur l'adresse "any" + le port — PAS sur l'adresse du groupe
        // elle-même, contre-intuitif mais c'est ce qu'attend le noyau ici.
        socket.bind(&std::net::SocketAddrV4::new(std::net::Ipv4Addr::UNSPECIFIED, port).into())?;
        socket.join_multicast_v4(&group, &std::net::Ipv4Addr::UNSPECIFIED)?;
        tracing::info!("groupe multicast {group} rejoint sur le port {port}");
    } else {
        socket.bind(&listen_addr.parse::<std::net::SocketAddr>()?.into())?;
    }

    socket.set_nonblocking(true)?;
    Ok(socket.into())
}

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

    let std_socket = bind_rtp_socket(RTP_LISTEN_ADDR)?;
    let udp_socket = UdpSocket::from_std(std_socket)?;
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
/// Délai pendant lequel un paquet est retenu avant d'être relayé — laisse
/// le temps aux paquets arrivés en désordre de "rattraper" leur place.
/// Un vrai jitter buffer (GStreamer, etc.) adapte ce délai dynamiquement ;
/// ici c'est volontairement fixe et simple.
const JITTER_DELAY: Duration = Duration::from_millis(50);
/// Fréquence à laquelle on vérifie si des paquets sont prêts à sortir du
/// tampon. Doit rester petit devant JITTER_DELAY pour ne pas ajouter de
/// latence supplémentaire significative.
const REORDER_TICK: Duration = Duration::from_millis(5);

/// Convertit le numéro de séquence RTP 16 bits (qui reboucle après 65536
/// paquets, ~20 min à 50 paquets/s) en un numéro "étendu" 32 bits
/// monotone. Nécessaire pour trier correctement dans un `BTreeMap` sans
/// que le tri ne se casse à chaque rebouclage (0 redeviendrait "avant"
/// 65535 sans cette extension).
struct SeqExtender {
    last_seq16: Option<u16>,
    wraps: u32,
}

impl SeqExtender {
    fn new() -> Self {
        Self {
            last_seq16: None,
            wraps: 0,
        }
    }

    fn extend(&mut self, seq16: u16) -> u32 {
        if let Some(last) = self.last_seq16 {
            // Écart signé en arithmétique 16 bits : un grand saut négatif
            // signale qu'on vient de reboucler (65535 → 0). Un grand saut
            // positif signale un paquet très en retard, d'avant un
            // rebouclage déjà pris en compte — cas rare, mais on corrige.
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

/// Tampon de réordonnancement RTP minimal. Absorbe le désordre/la gigue
/// typiques d'une vraie interface réseau (constaté : loopback marche,
/// interface réelle casse le décodage côté navigateur sans ça). Un
/// paquet toujours manquant après `JITTER_DELAY` est considéré perdu :
/// on saute par-dessus plutôt que de bloquer indéfiniment le flux.
struct ReorderBuffer {
    packets: BTreeMap<u32, (Bytes, Instant)>,
    next_expected: Option<u32>,
    extender: SeqExtender,
}

impl ReorderBuffer {
    fn new() -> Self {
        Self {
            packets: BTreeMap::new(),
            next_expected: None,
            extender: SeqExtender::new(),
        }
    }

    /// Insère un paquet fraîchement reçu à sa position selon son numéro
    /// de séquence RTP (octets 2-3 de l'en-tête, network byte order —
    /// RFC 3550 section 5.1). Lu directement plutôt que via le crate
    /// `rtp` : un seul champ à taille fixe, pas besoin d'un parseur
    /// complet pour ça.
    fn insert(&mut self, packet: Bytes) {
        let Some(seq_bytes) = packet.get(2..4) else {
            return; // trop court pour être un en-tête RTP valide
        };
        let seq16 = u16::from_be_bytes([seq_bytes[0], seq_bytes[1]]);
        let extended_seq = self.extender.extend(seq16);
        self.packets.insert(extended_seq, (packet, Instant::now()));
    }

    /// Déplace dans `out` tous les paquets prêts à être relayés, dans
    /// l'ordre, en sautant les paquets manquants dont le délai d'attente
    /// est dépassé plutôt que d'attendre indéfiniment.
    fn drain_ready(&mut self, out: &mut Vec<Bytes>) {
        loop {
            let Some((&seq, &(_, arrival))) = self.packets.iter().next() else {
                break;
            };

            let ready_anyway = match self.next_expected {
                Some(expected) => seq >= expected,
                None => true,
            };

            match self.next_expected {
                Some(expected) if seq < expected => {
                    // Doublon, ou paquet retardataire pour une place déjà
                    // comblée : on le jette silencieusement.
                    self.packets.remove(&seq);
                }
                _ if ready_anyway && arrival.elapsed() >= JITTER_DELAY => {
                    let (packet, _) = self.packets.remove(&seq).unwrap();
                    out.push(packet);
                    // Si seq > expected, un ou plusieurs paquets ont été
                    // considérés perdus : on saute directement après seq.
                    self.next_expected = Some(seq.wrapping_add(1));
                }
                _ => break, // le prochain paquet attendu n'a pas fini d'attendre
            }
        }
    }
}

async fn rtp_listener(socket: UdpSocket, tx: broadcast::Sender<Bytes>) {
    // MTU réseau classique ; suffisant pour un paquet RTP/H.264 non fragmenté
    // (les NAL units plus grosses arrivent déjà fragmentées en FU-A par
    // l'émetteur, chaque fragment tient dans ce buffer).
    let mut buf = vec![0u8; 1500];
    let mut reorder = ReorderBuffer::new();
    let mut ticker = interval(REORDER_TICK);
    let mut ready = Vec::new();

    loop {
        tokio::select! {
            recv_result = socket.recv(&mut buf) => {
                match recv_result {
                    Ok(n) => reorder.insert(Bytes::copy_from_slice(&buf[..n])),
                    Err(e) => {
                        tracing::error!("lecture du socket UDP interrompue: {e}");
                        break;
                    }
                }
            }
            _ = ticker.tick() => {
                reorder.drain_ready(&mut ready);
                for packet in ready.drain(..) {
                    // send() ne renvoie une erreur que s'il n'y a aucun
                    // abonné : normal tant qu'aucun navigateur n'est
                    // connecté, on l'ignore plutôt que de logguer en boucle.
                    let _ = tx.send(packet);
                }
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
