//! Generic WebSocket connection shared by [`crate::overrides`] and [`crate::prices`].

use std::{
    marker::PhantomData,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use futures_util::StreamExt;
use tokio::sync::{Mutex, Notify};
use tokio_tungstenite::{connect_async, tungstenite::Message};

use crate::error::{Error, Result};

const RECONNECT_INITIAL: Duration = Duration::from_secs(1);
const RECONNECT_MAX: Duration = Duration::from_secs(30);

/// Implemented by each WS source to supply the snapshot type and frame logic.
pub(crate) trait WsHandler: Send + Sync + 'static {
    type Snapshot: Default + Send + Sync + 'static;

    /// Parse `text` and apply it to `snapshot`. Returns `true` when the
    /// snapshot was updated.
    fn apply_frame(snapshot: &mut Arc<Self::Snapshot>, text: &str) -> bool;

    fn closed_error() -> Error;
    fn timeout_error(timeout: Duration) -> Error;
}

#[derive(Default)]
struct WsShared<S> {
    snapshot: Arc<S>,
    has_frame: bool,
    closed: bool,
    last_use: Option<Instant>,
    task: Option<tokio::task::JoinHandle<()>>,
}

#[derive(Default)]
struct WsState<S> {
    shared: Mutex<WsShared<S>>,
    frame_notify: Notify,
    /// Calls currently waiting for a first frame — idle teardown is deferred
    /// while any exist (matters when `idle_timeout` is very small).
    waiters: AtomicUsize,
}

/// Lazy-connect WebSocket source: connects on first use, reconnects with
/// exponential backoff, and tears down after `idle_timeout` without calls.
pub(crate) struct WsConnection<H: WsHandler> {
    url: String,
    idle_timeout: Duration,
    first_frame_timeout: Duration,
    state: Arc<WsState<H::Snapshot>>,
    _marker: PhantomData<H>,
}

impl<H: WsHandler> WsConnection<H> {
    pub fn new(url: String, idle_timeout: Duration, first_frame_timeout: Duration) -> Self {
        Self {
            url,
            idle_timeout,
            first_frame_timeout,
            state: Arc::new(WsState::default()),
            _marker: PhantomData,
        }
    }

    pub async fn get_snapshot(&self) -> Result<Arc<H::Snapshot>> {
        // Warm path: a single lock acquisition. Record demand, ensure the read
        // loop is alive (respawn if it died), then hand out a buffered frame's
        // Arc immediately if present.
        {
            let mut shared = self.state.shared.lock().await;
            if shared.closed {
                return Err(H::closed_error());
            }
            shared.last_use = Some(Instant::now());
            let running = shared.task.as_ref().is_some_and(|t| !t.is_finished());
            if !running {
                shared.task = Some(tokio::spawn(run_ws_loop::<H>(
                    self.state.clone(),
                    self.url.clone(),
                    self.idle_timeout,
                )));
            }
            if shared.has_frame {
                return Ok(shared.snapshot.clone());
            }
        }

        let deadline = tokio::time::Instant::now() + self.first_frame_timeout;
        self.state.waiters.fetch_add(1, Ordering::SeqCst);
        let result = self.wait_for_snapshot(deadline).await;
        self.state.waiters.fetch_sub(1, Ordering::SeqCst);
        result
    }

    async fn wait_for_snapshot(
        &self,
        deadline: tokio::time::Instant,
    ) -> Result<Arc<H::Snapshot>> {
        loop {
            // Register for notification BEFORE checking state, so a frame
            // landing in between can't be missed.
            let notified = self.state.frame_notify.notified();
            {
                let shared = self.state.shared.lock().await;
                if shared.closed {
                    return Err(H::closed_error());
                }
                if shared.has_frame {
                    // Arc clone: one refcount bump, not a deep copy.
                    return Ok(shared.snapshot.clone());
                }
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return Err(H::timeout_error(self.first_frame_timeout));
            }
        }
    }

    pub fn close(&self) {
        let state = self.state.clone();
        tokio::spawn(async move {
            let mut shared = state.shared.lock().await;
            shared.closed = true;
            if let Some(task) = shared.task.take() {
                task.abort();
            }
            drop(shared);
            state.frame_notify.notify_waiters();
        });
    }
}

async fn run_ws_loop<H: WsHandler>(
    state: Arc<WsState<H::Snapshot>>,
    url: String,
    idle_timeout: Duration,
) {
    let mut backoff = RECONNECT_INITIAL;

    loop {
        if let Ok((stream, _)) = connect_async(&url).await {
            backoff = RECONNECT_INITIAL;
            let (_, mut read) = stream.split();

            loop {
                let dl = idle_deadline::<H>(&state, idle_timeout).await;
                tokio::select! {
                    message = read.next() => match message {
                        Some(Ok(Message::Text(text))) => {
                            handle_frame::<H>(&state, text.as_str()).await;
                        }
                        Some(Ok(_)) => {}
                        Some(Err(_)) | None => break, // reconnect
                    },
                    _ = tokio::time::sleep_until(dl) => {
                        if idle_expired::<H>(&state, idle_timeout).await {
                            return;
                        }
                    }
                }
            }
        }

        // Between reconnect attempts, still honor the idle timeout so a dead
        // endpoint doesn't keep an unused source reconnecting forever.
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(RECONNECT_MAX);
        if idle_expired::<H>(&state, idle_timeout).await {
            return;
        }
    }
}

async fn handle_frame<H: WsHandler>(state: &WsState<H::Snapshot>, text: &str) {
    let mut shared = state.shared.lock().await;
    if H::apply_frame(&mut shared.snapshot, text) {
        shared.has_frame = true;
        drop(shared);
        state.frame_notify.notify_waiters();
    }
}

async fn idle_deadline<H: WsHandler>(
    state: &WsState<H::Snapshot>,
    idle_timeout: Duration,
) -> tokio::time::Instant {
    // While a call is waiting for its first frame, push the deadline out so a
    // tiny idle_timeout can't tear the connection down before delivery.
    if state.waiters.load(Ordering::SeqCst) > 0 {
        return tokio::time::Instant::now() + Duration::from_secs(1);
    }
    let shared = state.shared.lock().await;
    let last_use = shared.last_use.unwrap_or_else(Instant::now);
    tokio::time::Instant::now() + idle_timeout.saturating_sub(last_use.elapsed())
}

/// True (and marks the snapshot as needing a fresh frame) when the source has
/// been unused for longer than the idle timeout and nobody is waiting.
async fn idle_expired<H: WsHandler>(
    state: &WsState<H::Snapshot>,
    idle_timeout: Duration,
) -> bool {
    if state.waiters.load(Ordering::SeqCst) > 0 {
        return false;
    }
    let mut shared = state.shared.lock().await;
    let expired = shared
        .last_use
        .is_none_or(|last_use| last_use.elapsed() >= idle_timeout);
    if expired {
        shared.has_frame = false;
    }
    expired
}
