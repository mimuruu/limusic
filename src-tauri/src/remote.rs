//! Phone remote: a LAN HTTP API so the Android controller app can drive playback from bed.
//!
//! **Why this exists.** Limusic has no Spotify-Connect equivalent: the OS media keys and the tray
//! menu only work at the machine. This module exposes the very same [`AppState`] methods those
//! paths use (`resume_or_toggle`, `next_in_queue`, `user_seek`, …) over HTTP, so a phone on the
//! same WiFi can pause, skip, seek and pick a track without anyone getting up.
//!
//! **Bound to the LAN, not loopback.** Unlike [`crate::videoproxy`], which is reachable only from
//! this machine, this listener has to accept connections from the phone. That makes the token the
//! entire security boundary, and it is treated as one:
//!
//! * the server only binds while the `remote_enabled` setting is on, and the UI shows the user the
//!   exact IP it is reachable at so nobody leaves it on by accident;
//! * a device is admitted only by trading a short-lived 6-digit pairing code (shown in the desktop
//!   UI) for a long-lived device token, which is what every later request must carry;
//! * the pairing code is single-use, expires after [`PAIRING_TTL_SECS`], and is compared in
//!   constant time;
//! * tokens are stored as SHA-256 digests, so a copied `settings` table yields no usable token.
//!
//! **What it deliberately does not do.** No TLS (a self-signed cert on a home LAN buys a phone
//! warning, not privacy), and no auth/session endpoints: the remote can play music, never read the
//! Google session, change settings, or reach the account. `search` is the one read that touches
//! YouTube, and it goes out unauthenticated unless the user is signed in, exactly like the UI's.

use std::convert::Infallible;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine;
use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::header;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use sha2::{Digest, Sha256};
use tauri::{Emitter, Manager};

use crate::state::{AppState, RepeatMode};

/// Response body type. Small on purpose: this API answers with JSON, never a stream.
type Body = Full<Bytes>;

/// How long a pairing code stays valid. Long enough to walk to the phone and type six digits (and
/// mistype once), short enough that a glance at the screen is not a lasting grant.
pub const PAIRING_TTL_SECS: u64 = 300;

/// Default port. Deliberately not 8080 (the sync server's) and not something IANA-assigned, so a
/// collision on a home LAN is unlikely; the user can override it in Settings.
pub const DEFAULT_PORT: u16 = 4317;

/// Header the device token rides in.
const TOKEN_HEADER: &str = "x-limusic-token";

/// One paired phone.
struct Device {
    /// SHA-256 of the token, hex. The token itself is never stored: whoever copies the database
    /// gets a digest they cannot turn back into a credential.
    token_hash: String,
    /// What the phone called itself, for the "Paired devices" list.
    name: String,
    /// Unix seconds, for display.
    paired_at: i64,
}

/// Live remote server state: the listener's port and the pairing/device bookkeeping.
struct Remote {
    port: u16,
    /// The 6-digit code currently on screen, and when it stops being accepted. `None` when the
    /// user has not asked for a new one — pairing codes are minted on demand, never kept warm.
    pairing: Mutex<Option<(String, Instant)>>,
    devices: Mutex<Vec<Device>>,
    /// Set false by [`stop`]; the accept loop reads it each turn.
    running: AtomicBool,
}

/// The running server, if any. `None` before [`start`] or after [`stop`].
static REMOTE: OnceLock<Mutex<Option<Arc<Remote>>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Arc<Remote>>> {
    REMOTE.get_or_init(|| Mutex::new(None))
}

// --- settings persistence -------------------------------------------------------------------

/// Devices are stored as JSON in one settings row: a handful of small records with no query needs,
/// and the settings table is already where every other piece of app state of this kind lives.
const DEVICES_KEY: &str = "remote_devices";

fn load_devices(db: &crate::db::Db) -> Vec<Device> {
    let Some(raw) = db.get_setting(DEVICES_KEY) else { return Vec::new() };
    let parsed: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap_or_default();
    parsed
        .into_iter()
        .filter_map(|v| {
            Some(Device {
                token_hash: v.get("tokenHash")?.as_str()?.to_owned(),
                name: v.get("name").and_then(|s| s.as_str()).unwrap_or("Phone").to_owned(),
                paired_at: v.get("pairedAt").and_then(serde_json::Value::as_i64).unwrap_or(0),
            })
        })
        .collect()
}

fn save_devices(db: &crate::db::Db, devices: &[Device]) {
    let json: Vec<serde_json::Value> = devices
        .iter()
        .map(|d| {
            serde_json::json!({
                "tokenHash": d.token_hash,
                "name": d.name,
                "pairedAt": d.paired_at,
            })
        })
        .collect();
    db.set_setting(DEVICES_KEY, &serde_json::Value::Array(json).to_string());
}

fn hash_token(token: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"limusic-remote-device-v1");
    digest.update(token.as_bytes());
    format!("{:x}", digest.finalize())
}

/// Constant-time comparison, so a wrong pairing code cannot be narrowed down by timing. Length is
/// allowed to leak, which is fine for a fixed-width 6-digit code.
fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// --- public surface -------------------------------------------------------------------------

/// Start the listener if it is not already running. Idempotent: the settings tab calls this every
/// time the user flips the switch, and a second call is a no-op rather than a second bind.
pub fn start(app: tauri::AppHandle) -> Result<u16, String> {
    {
        let guard = slot().lock().unwrap();
        if let Some(existing) = guard.as_ref() {
            return Ok(existing.port);
        }
    }
    let db = {
        let Some(state) = app.try_state::<Arc<AppState>>() else {
            return Err("app state not ready".into());
        };
        state.db.clone()
    };
    let port: u16 = db
        .get_setting("remote_port")
        .and_then(|p| p.parse().ok())
        .filter(|p| *p >= 1024)
        .unwrap_or(DEFAULT_PORT);

    // 0.0.0.0, not 127.0.0.1: the whole point is to accept the phone's connection. The token is
    // what keeps other LAN hosts out.
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
        .map_err(|e| format!("couldn't listen on port {port}: {e}"))?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let bound_port = listener.local_addr().map_err(|e| e.to_string())?.port();

    let remote = Arc::new(Remote {
        port: bound_port,
        pairing: Mutex::new(None),
        devices: Mutex::new(load_devices(&db)),
        running: AtomicBool::new(true),
    });
    *slot().lock().unwrap() = Some(remote.clone());

    let state = app.state::<Arc<AppState>>().inner().clone();
    let db_for_loop = db.clone();
    tauri::async_runtime::spawn(async move {
        let Ok(listener) = tokio::net::TcpListener::from_std(listener) else { return };
        tracing::info!(port = bound_port, "phone remote listening on the LAN");
        loop {
            if !remote.running.load(Ordering::Relaxed) {
                break;
            }
            let (stream, peer) = match listener.accept().await {
                Ok(v) => v,
                Err(e) => {
                    // Same reasoning as videoproxy: EMFILE/ENOBUFS return immediately and would
                    // otherwise spin a core for the rest of the process.
                    tracing::warn!(error = %e, "phone remote: accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            };
            let state = state.clone();
            let remote = remote.clone();
            let db = db_for_loop.clone();
            tauri::async_runtime::spawn(async move {
                let svc = service_fn(move |req| {
                    serve(req, peer.ip(), state.clone(), remote.clone(), db.clone())
                });
                let _ = http1::Builder::new()
                    .timer(TokioTimer::new())
                    .header_read_timeout(Duration::from_secs(15))
                    .serve_connection(TokioIo::new(stream), svc)
                    .await;
            });
        }
    });
    Ok(bound_port)
}

/// Stop the listener and drop the server state. Paired devices survive in the database, so turning
/// the switch back on does not force everyone to re-pair.
pub fn stop() {
    if let Some(remote) = slot().lock().unwrap().take() {
        remote.running.store(false, Ordering::Relaxed);
        *remote.pairing.lock().unwrap() = None;
        tracing::info!("phone remote stopped");
    }
}

/// Mint a fresh 6-digit pairing code and return it together with its lifetime in seconds. Replaces
/// any code still pending, so only the newest one is on screen.
pub fn new_pairing_code() -> (String, u64) {
    let code = format!("{:06}", rand::random::<u32>() % 1_000_000);
    if let Some(remote) = slot().lock().unwrap().as_ref() {
        *remote.pairing.lock().unwrap() = Some((code.clone(), Instant::now()));
    }
    (code, PAIRING_TTL_SECS)
}

/// Paired devices as the UI lists them: name, when, and an opaque index used to revoke. The token
/// hash never crosses the Tauri boundary.
pub fn device_list() -> Vec<serde_json::Value> {
    slot()
        .lock()
        .unwrap()
        .as_ref()
        .map(|r| {
            r.devices
                .lock()
                .unwrap()
                .iter()
                .enumerate()
                .map(|(i, d)| {
                    serde_json::json!({
                        "id": i,
                        "name": d.name,
                        "pairedAt": d.paired_at,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Revoke one device by its list index. The token stops working on the next request.
pub fn revoke_device(index: usize, db: &crate::db::Db) {
    if let Some(remote) = slot().lock().unwrap().as_ref() {
        let mut devices = remote.devices.lock().unwrap();
        if index < devices.len() {
            devices.remove(index);
        }
        save_devices(db, &devices);
    }
}

/// Whether the server is up, and where the phone should point.
pub fn status(db: &crate::db::Db) -> serde_json::Value {
    let port = slot()
        .lock()
        .unwrap()
        .as_ref()
        .map(|r| r.port)
        .unwrap_or_else(|| {
            db.get_setting("remote_port")
                .and_then(|p| p.parse().ok())
                .filter(|p| *p >= 1024)
                .unwrap_or(DEFAULT_PORT)
        });
    serde_json::json!({
        "enabled": slot().lock().unwrap().is_some(),
        "port": port,
        "addresses": lan_addresses(),
        "devices": device_list(),
    })
}

/// Every non-loopback IPv4 address of this machine, so the UI can show the phone which URL to
/// type. Best-effort: a machine with no route anywhere returns an empty list and the UI says so.
pub fn lan_addresses() -> Vec<String> {
    let Ok(sock) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) else { return Vec::new() };
    // No packet is sent — `connect` on a UDP socket only sets the default route, which is the
    // portable way to ask "which of my addresses would the LAN see".
    if sock.connect(("8.8.8.8", 80)).is_err() {
        return Vec::new();
    }
    match sock.local_addr() {
        Ok(SocketAddr::V4(addr)) if !addr.ip().is_loopback() => vec![addr.ip().to_string()],
        _ => Vec::new(),
    }
}

// --- HTTP -----------------------------------------------------------------------------------

/// `(status, json)` — every handler answers this, so the response builder is written once.
#[allow(clippy::type_complexity)]
type ApiResult = Result<(StatusCode, serde_json::Value), (StatusCode, String)>;

fn json_response(status: StatusCode, value: &serde_json::Value) -> Response<Body> {
    let text = value.to_string();
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        // The phone app is not a browser, but this also keeps an accidental browser visit from
        // being usefully proxied.
        .header(header::CACHE_CONTROL, "no-store")
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .header(header::ACCESS_CONTROL_ALLOW_HEADERS, "*")
        .body(Full::new(Bytes::from(text)))
        .unwrap()
}

fn error_response(status: StatusCode, message: &str) -> Response<Body> {
    json_response(status, &serde_json::json!({ "error": message }))
}

async fn serve(
    req: Request<Incoming>,
    _peer: IpAddr,
    state: Arc<AppState>,
    remote: Arc<Remote>,
    db: Arc<crate::db::Db>,
) -> Result<Response<Body>, Infallible> {
    // CORS preflight: the desktop UI (a webview on an origin of its own) and a browser opened at
    // the API both send one, and answering it here keeps the handler code free of HEAD/OPTIONS
    // special cases.
    if req.method() == Method::OPTIONS {
        return Ok(json_response(StatusCode::NO_CONTENT, &serde_json::json!({})));
    }
    let response = match handle(req, &state, &remote, &db).await {
        Ok((status, value)) => json_response(status, &value),
        Err((status, message)) => error_response(status, &message),
    };
    Ok(response)
}

async fn handle(
    req: Request<Incoming>,
    state: &Arc<AppState>,
    remote: &Arc<Remote>,
    db: &Arc<crate::db::Db>,
) -> ApiResult {
    let path = req.uri().path().to_owned();
    let query = req.uri().query().unwrap_or_default().to_owned();
    let method = req.method().clone();

    // Pairing is the only unauthenticated write, and it is gated on the code.
    if path == "/api/pair" && method == Method::POST {
        let body = read_json(req).await?;
        return pair(body, remote, db).await;
    }
    // A health probe, unauthenticated so the phone can say "something is there" before pairing.
    if path == "/api/ping" && method == Method::GET {
        return Ok((
            StatusCode::OK,
            serde_json::json!({ "app": "limusic", "paired": remote.devices.lock().unwrap().len() }),
        ));
    }

    // Everything below needs a device token.
    let token = req
        .headers()
        .get(TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    if !authorized(&token, remote) {
        return Err((StatusCode::UNAUTHORIZED, "pair this device first".into()));
    }

    // `method` moves into the tuple, so the fallback arm below reports the verb from `path`'s
    // companion borrow instead — hence the pre-computed string.
    let method_label = method.to_string();
    match (method, path.as_str()) {
        // --- reads ---
        (Method::GET, "/api/status") => {
            let mut snap = state.playback_snapshot().await;
            // Fold the queue's shape in so the phone can draw a queue button without a second
            // call on every poll.
            let q = state.queue_snapshot().await;
            if let Some(obj) = snap.as_object_mut() {
                obj.insert("queueLength".into(), q["items"].clone());
                obj.insert("shuffle".into(), q["shuffle"].clone());
                obj.insert("repeat".into(), q["repeat"].clone());
                obj.insert("sourceName".into(), q["sourceName"].clone());
            }
            Ok((StatusCode::OK, snap))
        }
        (Method::GET, "/api/queue") => Ok((StatusCode::OK, state.queue_snapshot().await)),
        (Method::GET, "/api/search") => {
            let q = query_param(&query, "q").unwrap_or_default();
            if q.trim().is_empty() {
                return Err((StatusCode::BAD_REQUEST, "missing ?q=".into()));
            }
            let client = match state.clients.get(innertube::METADATA_CLIENT) {
                Some(c) => c,
                None => return Err((StatusCode::INTERNAL_SERVER_ERROR, "no client".into())),
            };
            // `record_history: false`: a remote search is a remote control gesture, not something
            // the user typed into the app's own history.
            match state.it.search_songs(client, &q, false).await {
                Ok(result) => Ok((StatusCode::OK, serde_json::json!({ "items": result.items }))),
                Err(e) => Err((StatusCode::BAD_GATEWAY, e.to_string())),
            }
        }
        // --- transport ---
        (Method::POST, "/api/toggle") => {
            state.resume_or_toggle().await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/play-pause") => {
            let body = read_json(req).await.unwrap_or(serde_json::Value::Null);
            let want_play = body.get("playing").and_then(serde_json::Value::as_bool);
            let playing = !state.is_playing_snapshot();
            match want_play {
                // Explicit desired state, so a retried request can't double-toggle.
                Some(true) if !playing => state.resume_or_toggle().await,
                Some(false) if playing => state.resume_or_toggle().await,
                Some(_) => {}
                None => state.resume_or_toggle().await,
            }
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/next") => {
            state.clone().next_in_queue().await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/previous") => {
            state.clone().prev_in_queue().await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/seek") => {
            let body = read_json(req).await?;
            let Some(pos) = body.get("position").and_then(serde_json::Value::as_f64) else {
                return Err((StatusCode::BAD_REQUEST, "need {\"position\": seconds}".into()));
            };
            // mpv rejects a seek with no media loaded (`Raw(-12)`), which is the ordinary state of
            // a fresh install and of a phone that connected before anything was played. The raw
            // code means nothing to a phone app, so say what actually happened.
            state.user_seek(pos.max(0.0)).await.map_err(|e| {
                if e.contains("Raw(-12)") {
                    (StatusCode::CONFLICT, "nothing is playing yet".to_string())
                } else {
                    (StatusCode::CONFLICT, e)
                }
            })?;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/volume") => {
            let body = read_json(req).await?;
            let Some(vol) = body.get("volume").and_then(serde_json::Value::as_i64) else {
                return Err((StatusCode::BAD_REQUEST, "need {\"volume\": 0-100}".into()));
            };
            // Same clamp the UI's slider uses; mpv's own ceiling is higher, but a remote that can
            // exceed what the desktop shows would desync the two.
            let vol = vol.clamp(0, 100);
            state.player.set_volume(vol).map_err(|e| {
                let message = e.to_string();
                let message = if message.trim().is_empty() {
                    "the player refused that volume".to_string()
                } else {
                    message
                };
                (StatusCode::CONFLICT, message)
            })?;
            // Persisted here, unlike the UI path which saves it in `commitVolume` after a drag.
            // A phone has no drag: every call is a settled value, so a volume set from bed should
            // still be in force the next morning (and `/api/status` should report it, not the
            // last saved one).
            state.db.set_setting("volume", &vol.to_string());
            let _ = state.app.emit("volume", vol);
            Ok((StatusCode::OK, serde_json::json!({ "ok": true, "volume": vol })))
        }
        // --- queue ---
        (Method::POST, "/api/play-index") => {
            let body = read_json(req).await?;
            let Some(index) = body.get("index").and_then(serde_json::Value::as_u64) else {
                return Err((StatusCode::BAD_REQUEST, "need {\"index\": n}".into()));
            };
            state.clone().play_index(index as usize).await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/remove-from-queue") => {
            let body = read_json(req).await?;
            let Some(index) = body.get("index").and_then(serde_json::Value::as_u64) else {
                return Err((StatusCode::BAD_REQUEST, "need {\"index\": n}".into()));
            };
            state.clone().remove_from_queue(index as usize).await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/shuffle") => {
            state.clone().toggle_shuffle().await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/repeat") => {
            let body = read_json(req).await?;
            let mode = match body.get("mode").and_then(serde_json::Value::as_str) {
                Some("off") => RepeatMode::Off,
                Some("all") => RepeatMode::All,
                Some("one") => RepeatMode::One,
                other => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        format!("mode must be off|all|one, got {other:?}"),
                    ))
                }
            };
            state.clone().set_repeat(mode).await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        (Method::POST, "/api/play") => {
            // The phone sends back the `SongItem` it got from `/api/search` verbatim, so there is
            // no id-only path that would need a second round trip to seed the queue's metadata.
            let body = read_json(req).await?;
            let item: innertube::SongItem = serde_json::from_value(body)
                .map_err(|e| (StatusCode::BAD_REQUEST, format!("bad song item: {e}")))?;
            state.clone().play_song(item).await;
            Ok((StatusCode::OK, serde_json::json!({ "ok": true })))
        }
        _ => Err((StatusCode::NOT_FOUND, format!("no route for {method_label} {path}"))),
    }
}

async fn pair(
    body: serde_json::Value,
    remote: &Arc<Remote>,
    db: &Arc<crate::db::Db>,
) -> ApiResult {
    let code = body.get("code").and_then(serde_json::Value::as_str).unwrap_or_default();
    let name = body
        .get("name")
        .and_then(serde_json::Value::as_str)
        .filter(|n| !n.trim().is_empty())
        .unwrap_or("Phone")
        .chars()
        .take(48)
        .collect::<String>();

    let expired = {
        let guard = remote.pairing.lock().unwrap();
        match guard.as_ref() {
            None => return Err((StatusCode::FORBIDDEN, "no pairing code is active".into())),
            Some((_, at)) if at.elapsed() > Duration::from_secs(PAIRING_TTL_SECS) => true,
            Some((expected, _)) if !constant_time_eq(expected, code) => {
                return Err((StatusCode::FORBIDDEN, "wrong pairing code".into()))
            }
            Some(_) => false,
        }
    };
    if expired {
        *remote.pairing.lock().unwrap() = None;
        return Err((StatusCode::FORBIDDEN, "that pairing code expired".into()));
    }
    // Single-use: burn it before the token is handed out, so the same code cannot pair twice.
    *remote.pairing.lock().unwrap() = None;

    let token = {
        let raw = format!("{:016x}{:016x}", rand::random::<u64>(), rand::random::<u64>());
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw.as_bytes())
    };
    {
        let mut devices = remote.devices.lock().unwrap();
        devices.push(Device {
            token_hash: hash_token(&token),
            name,
            paired_at: crate::db::now_secs(),
        });
        save_devices(db, &devices);
    }
    tracing::info!("phone remote: device paired");
    Ok((StatusCode::OK, serde_json::json!({ "token": token })))
}

fn authorized(token: &str, remote: &Arc<Remote>) -> bool {
    if token.is_empty() {
        return false;
    }
    let hash = hash_token(token);
    remote.devices.lock().unwrap().iter().any(|d| constant_time_eq(&d.token_hash, &hash))
}

async fn read_json(req: Request<Incoming>) -> Result<serde_json::Value, (StatusCode, String)> {
    // Bounded: the only bodies this API takes are a song item from search (a few KB) and small
    // command objects. 1 MB is far past anything legitimate and keeps a hostile body from being
    // buffered into memory.
    const MAX_BODY: usize = 1024 * 1024;
    let bytes = req
        .into_body()
        .collect()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?
        .to_bytes();
    if bytes.len() > MAX_BODY {
        return Err((StatusCode::PAYLOAD_TOO_LARGE, "body too large".into()));
    }
    if bytes.is_empty() {
        return Ok(serde_json::Value::Null);
    }
    serde_json::from_slice(&bytes).map_err(|e| (StatusCode::BAD_REQUEST, format!("bad JSON: {e}")))
}

fn query_param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == key).then(|| urlencoding::decode(v).map(|c| c.into_owned()).unwrap_or_default())
    })
}

// hyper 1.x panics the moment it arms a timeout with no timer installed (the videoproxy.rs bug),
// so the accept path installs one.
use hyper_util::rt::TokioTimer;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_codes_are_six_digits() {
        for _ in 0..500 {
            let code = format!("{:06}", rand::random::<u32>() % 1_000_000);
            assert_eq!(code.len(), 6);
            assert!(code.chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn token_hashes_are_stable_and_salted() {
        assert_eq!(hash_token("abc"), hash_token("abc"));
        assert_ne!(hash_token("abc"), hash_token("abd"));
        // The version prefix means a digest of the bare token is not the stored value.
        let mut bare = Sha256::new();
        bare.update(b"abc");
        assert_ne!(hash_token("abc"), format!("{:x}", bare.finalize()));
    }

    #[test]
    fn constant_time_eq_matches_only_equal_strings() {
        assert!(constant_time_eq("123456", "123456"));
        assert!(!constant_time_eq("123456", "123457"));
        assert!(!constant_time_eq("123456", "12345"));
        assert!(!constant_time_eq("", "1"));
        assert!(constant_time_eq("", ""));
    }

    #[test]
    fn query_params_are_url_decoded() {
        assert_eq!(query_param("q=daft+punk", "q").as_deref(), Some("daft+punk"));
        assert_eq!(query_param("q=a%20b&x=1", "q").as_deref(), Some("a b"));
        assert_eq!(query_param("x=1", "q"), None);
    }

    /// The pairing state machine is the whole security boundary, so it is exercised end to end
    /// rather than by inspecting internals: a fresh code pairs once, the same code then fails,
    /// a wrong code never pairs, and a revoked token stops authenticating.
    fn test_remote() -> Arc<Remote> {
        Arc::new(Remote {
            port: 0,
            pairing: Mutex::new(None),
            devices: Mutex::new(Vec::new()),
            running: AtomicBool::new(true),
        })
    }

    /// An in-memory `Db` so the device list has somewhere to persist. `Db::open` takes a path; a
    /// scratch file under the temp dir is the least invasive way to get one without a real install.
    fn test_db(tag: &str) -> crate::db::Db {
        let path = std::env::temp_dir().join(format!("limusic-remote-test-{tag}.sqlite"));
        let _ = std::fs::remove_file(&path);
        crate::db::Db::open(&path).expect("open scratch db")
    }

    async fn try_pair(remote: &Arc<Remote>, db: &Arc<crate::db::Db>, code: &str) -> ApiResult {
        pair(serde_json::json!({ "code": code, "name": "Pixel" }), remote, db).await
    }

    #[tokio::test]
    async fn a_code_pairs_once_and_only_with_the_right_value() {
        let remote = test_remote();
        let db = Arc::new(test_db("pair-once"));

        // No code minted yet: nothing can pair.
        assert!(try_pair(&remote, &db, "000000").await.is_err());

        *remote.pairing.lock().unwrap() = Some(("123456".into(), Instant::now()));

        // The wrong code must not pair and must not burn the real one.
        let wrong = try_pair(&remote, &db, "654321").await;
        assert!(matches!(wrong, Err((StatusCode::FORBIDDEN, _))));
        assert!(remote.pairing.lock().unwrap().is_some(), "wrong guess keeps the code alive");

        let ok = try_pair(&remote, &db, "123456").await.expect("right code pairs");
        let token = ok.1["token"].as_str().unwrap().to_owned();
        assert!(!token.is_empty());
        assert!(authorized(&token, &remote));

        // Single-use: the same code is spent, and no second device appears.
        assert!(try_pair(&remote, &db, "123456").await.is_err());
        assert_eq!(remote.devices.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn an_expired_code_is_refused() {
        let remote = test_remote();
        let db = Arc::new(test_db("expired"));
        // Backdate past the TTL rather than sleeping for it.
        let old = Instant::now() - Duration::from_secs(PAIRING_TTL_SECS + 1);
        *remote.pairing.lock().unwrap() = Some(("123456".into(), old));

        assert!(matches!(
            try_pair(&remote, &db, "123456").await,
            Err((StatusCode::FORBIDDEN, _))
        ));
        assert!(remote.devices.lock().unwrap().is_empty());
        // And the dead code is cleared, so a later attempt is still refused.
        assert!(remote.pairing.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn a_paired_token_survives_a_reload_and_revocation_kills_it() {
        let dir = std::env::temp_dir();
        let path = dir.join("limusic-remote-test-reload.sqlite");
        let _ = std::fs::remove_file(&path);
        let db = Arc::new(crate::db::Db::open(&path).expect("open scratch db"));

        let remote = test_remote();
        *remote.pairing.lock().unwrap() = Some(("123456".into(), Instant::now()));
        let token =
            try_pair(&remote, &db, "123456").await.unwrap().1["token"].as_str().unwrap().to_owned();
        assert!(authorized(&token, &remote));

        // The device is in the database, so a restart (a fresh `Remote` loading from the same Db)
        // still trusts the token. This is what makes turning the switch off and on again painless.
        let reloaded = Arc::new(Remote {
            port: 0,
            pairing: Mutex::new(None),
            devices: Mutex::new(load_devices(&db)),
            running: AtomicBool::new(true),
        });
        assert!(authorized(&token, &reloaded), "a paired phone survives a restart");

        // Revoking drops it from the stored list for good.
        save_devices(&db, &[]);
        let after_revoke = Arc::new(Remote {
            port: 0,
            pairing: Mutex::new(None),
            devices: Mutex::new(load_devices(&db)),
            running: AtomicBool::new(true),
        });
        assert!(!authorized(&token, &after_revoke));
    }

    #[test]
    fn unknown_and_empty_tokens_are_unauthorized() {
        let remote = test_remote();
        assert!(!authorized("", &remote));
        assert!(!authorized("nonsense", &remote));
    }
}
