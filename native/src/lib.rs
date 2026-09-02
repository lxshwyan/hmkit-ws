use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc,
    },
};

use futures_util::{SinkExt, StreamExt};
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::*,
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode},
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot, Mutex, RwLock},
};
use tokio_tungstenite::{
    accept_async, connect_async,
    tungstenite::{
        client::IntoClientRequest,
        protocol::{frame::coding::CloseCode, CloseFrame, Message},
    },
};

type OpenCallback = Arc<ThreadsafeFunction<(), (), (), Status, false>>;
type ErrorCallback = Arc<ThreadsafeFunction<String, (), String, Status, false>>;
type MessageCallback =
    Arc<ThreadsafeFunction<Either<String, Buffer>, (), Either<String, Buffer>, Status, false>>;
type CloseCallback = Arc<ThreadsafeFunction<NativeCloseEvent, (), NativeCloseEvent, Status, false>>;
type ControlCallback = Arc<ThreadsafeFunction<Buffer, (), Buffer, Status, false>>;
type PeerCallback = Arc<ThreadsafeFunction<u32, (), u32, Status, false>>;
type PeerMessageCallback =
    Arc<ThreadsafeFunction<NativePeerMessage, (), NativePeerMessage, Status, false>>;
type PeerCloseCallback =
    Arc<ThreadsafeFunction<NativePeerCloseEvent, (), NativePeerCloseEvent, Status, false>>;

#[napi(object)]
pub struct NativeClientConfig {
    pub headers: Option<HashMap<String, String>>,
}

#[napi(object)]
pub struct NativeCloseEvent {
    pub code: u32,
    pub reason: String,
    pub clean: bool,
}

#[napi(object)]
pub struct NativePeerMessage {
    pub peer_id: u32,
    pub data: Either<String, Buffer>,
}

#[napi(object)]
pub struct NativePeerCloseEvent {
    pub peer_id: u32,
    pub code: u32,
    pub reason: String,
    pub clean: bool,
}

#[napi]
pub struct NativeWebSocketClient {
    url: String,
    config: Option<NativeClientConfig>,
    writer: Arc<RwLock<Option<mpsc::Sender<Message>>>>,
    on_open: Option<OpenCallback>,
    on_error: Option<ErrorCallback>,
    on_message: Option<MessageCallback>,
    on_close: Option<CloseCallback>,
    on_ping: Option<ControlCallback>,
    on_pong: Option<ControlCallback>,
}

#[napi]
impl NativeWebSocketClient {
    #[napi(constructor)]
    pub fn new(url: String, config: Option<NativeClientConfig>) -> Self {
        Self {
            url,
            config,
            writer: Arc::new(RwLock::new(None)),
            on_open: None,
            on_error: None,
            on_message: None,
            on_close: None,
            on_ping: None,
            on_pong: None,
        }
    }

    #[napi]
    pub async fn connect(&self) -> Result<()> {
        let mut request = self
            .url
            .as_str()
            .into_client_request()
            .map_err(|error| Error::new(Status::InvalidArg, error.to_string()))?;
        if let Some(headers) = self
            .config
            .as_ref()
            .and_then(|value| value.headers.as_ref())
        {
            for (name, value) in headers {
                let header_name = name
                    .parse::<tokio_tungstenite::tungstenite::http::HeaderName>()
                    .map_err(|error| Error::new(Status::InvalidArg, error.to_string()))?;
                let header_value = value
                    .parse::<tokio_tungstenite::tungstenite::http::HeaderValue>()
                    .map_err(|error| Error::new(Status::InvalidArg, error.to_string()))?;
                request.headers_mut().insert(header_name, header_value);
            }
        }
        let (stream, _) = connect_async(request)
            .await
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?;
        let (mut sink, mut source) = stream.split();
        let (sender, mut receiver) = mpsc::channel::<Message>(64);
        self.writer.write().await.replace(sender.clone());
        if let Some(callback) = &self.on_open {
            callback.call((), ThreadsafeFunctionCallMode::NonBlocking);
        }
        let on_message = self.on_message.clone();
        let on_error = self.on_error.clone();
        let on_close = self.on_close.clone();
        let on_ping = self.on_ping.clone();
        let on_pong = self.on_pong.clone();
        let writer = self.writer.clone();
        napi_ohos::tokio::spawn(async move {
            loop {
                napi_ohos::tokio::select! {
                  outbound = receiver.recv() => {
                    match outbound {
                      Some(message) => if let Err(error) = sink.send(message).await {
                        emit_error(&on_error, error.to_string()); break;
                      },
                      None => break,
                    }
                  },
                  inbound = source.next() => {
                    match inbound {
                      Some(Ok(Message::Text(value))) => if let Some(callback) = &on_message {
                        callback.call(Either::A(value.to_string()), ThreadsafeFunctionCallMode::NonBlocking);
                      },
                      Some(Ok(Message::Binary(value))) => if let Some(callback) = &on_message {
                        callback.call(Either::B(Buffer::from(value.to_vec())), ThreadsafeFunctionCallMode::NonBlocking);
                      },
                      Some(Ok(Message::Ping(value))) => {
                        if let Some(callback) = &on_ping {
                          callback.call(Buffer::from(value.to_vec()), ThreadsafeFunctionCallMode::NonBlocking);
                        }
                        if sender.send(Message::Pong(value)).await.is_err() { break; }
                      },
                      Some(Ok(Message::Pong(value))) => if let Some(callback) = &on_pong {
                        callback.call(Buffer::from(value.to_vec()), ThreadsafeFunctionCallMode::NonBlocking);
                      },
                      Some(Ok(Message::Close(frame))) => {
                        emit_close(&on_close, frame, true); break;
                      },
                      Some(Ok(_)) => {},
                      Some(Err(error)) => { emit_error(&on_error, error.to_string()); break; },
                      None => { emit_close(&on_close, None, false); break; },
                    }
                  }
                }
            }
            writer.write().await.take();
        });
        Ok(())
    }

    #[napi]
    pub async fn send(&self, data: Either<String, Buffer>) -> Result<()> {
        let message = match data {
            Either::A(value) => Message::Text(value.into()),
            Either::B(value) => Message::Binary(Vec::<u8>::from(value).into()),
        };
        self.send_message(message).await
    }

    #[napi]
    pub async fn ping(&self, data: Option<Buffer>) -> Result<()> {
        let value = data.map(Vec::<u8>::from).unwrap_or_default();
        if value.len() > 125 {
            return Err(Error::new(
                Status::InvalidArg,
                "Ping payload exceeds 125 bytes",
            ));
        }
        self.send_message(Message::Ping(value.into())).await
    }

    #[napi]
    pub async fn close(&self, code: Option<u32>, reason: Option<String>) -> Result<()> {
        let frame = CloseFrame {
            code: CloseCode::from(code.unwrap_or(1000) as u16),
            reason: reason.unwrap_or_default().into(),
        };
        self.send_message(Message::Close(Some(frame))).await
    }

    async fn send_message(&self, message: Message) -> Result<()> {
        let writer = self.writer.read().await;
        let sender = writer
            .as_ref()
            .ok_or_else(|| Error::new(Status::GenericFailure, "WebSocket is not connected"))?;
        sender
            .send(message)
            .await
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))
    }

    #[napi]
    pub unsafe fn on_open(&mut self, callback: Function<(), ()>) -> Result<()> {
        self.on_open = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_error(&mut self, callback: Function<String, ()>) -> Result<()> {
        self.on_error = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_message(
        &mut self,
        callback: Function<Either<String, Buffer>, ()>,
    ) -> Result<()> {
        self.on_message = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_close(&mut self, callback: Function<NativeCloseEvent, ()>) -> Result<()> {
        self.on_close = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_ping(&mut self, callback: Function<Buffer, ()>) -> Result<()> {
        self.on_ping = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_pong(&mut self, callback: Function<Buffer, ()>) -> Result<()> {
        self.on_pong = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
}

#[napi]
pub struct NativeWebSocketServer {
    peers: Arc<RwLock<HashMap<u32, mpsc::Sender<Message>>>>,
    shutdown: Arc<Mutex<Option<oneshot::Sender<()>>>>,
    next_peer_id: Arc<AtomicU32>,
    on_peer_open: Option<PeerCallback>,
    on_peer_message: Option<PeerMessageCallback>,
    on_peer_close: Option<PeerCloseCallback>,
    on_error: Option<ErrorCallback>,
}

#[napi]
impl NativeWebSocketServer {
    #[napi(constructor)]
    pub fn new() -> Self {
        Self {
            peers: Arc::new(RwLock::new(HashMap::new())),
            shutdown: Arc::new(Mutex::new(None)),
            next_peer_id: Arc::new(AtomicU32::new(1)),
            on_peer_open: None,
            on_peer_message: None,
            on_peer_close: None,
            on_error: None,
        }
    }

    #[napi]
    pub async fn start(&self, host: String, port: u32) -> Result<u32> {
        let listener = TcpListener::bind(format!("{}:{}", host, port))
            .await
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?;
        let actual_port = listener
            .local_addr()
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?
            .port() as u32;
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        self.shutdown.lock().await.replace(shutdown_tx);
        let peers = self.peers.clone();
        let next_id = self.next_peer_id.clone();
        let on_open = self.on_peer_open.clone();
        let on_message = self.on_peer_message.clone();
        let on_close = self.on_peer_close.clone();
        let on_error = self.on_error.clone();
        napi_ohos::tokio::spawn(async move {
            loop {
                napi_ohos::tokio::select! {
                  _ = &mut shutdown_rx => break,
                  accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => {
                      let peer_id = next_id.fetch_add(1, Ordering::Relaxed);
                      let peer_map = peers.clone(); let open_cb = on_open.clone();
                      let message_cb = on_message.clone(); let close_cb = on_close.clone(); let error_cb = on_error.clone();
                      napi_ohos::tokio::spawn(async move {
                        if let Err(error) = run_peer(peer_id, stream, peer_map, open_cb, message_cb, close_cb).await {
                          emit_error(&error_cb, error);
                        }
                      });
                    },
                    Err(error) => emit_error(&on_error, error.to_string()),
                  }
                }
            }
            peers.write().await.clear();
        });
        Ok(actual_port)
    }

    #[napi]
    pub async fn send(&self, peer_id: u32, data: Either<String, Buffer>) -> Result<()> {
        let message = match data {
            Either::A(value) => Message::Text(value.into()),
            Either::B(value) => Message::Binary(Vec::<u8>::from(value).into()),
        };
        let peers = self.peers.read().await;
        let sender = peers
            .get(&peer_id)
            .ok_or_else(|| Error::new(Status::InvalidArg, "Unknown peer"))?;
        sender
            .send(message)
            .await
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))
    }

    #[napi]
    pub async fn broadcast(&self, data: Either<String, Buffer>) -> Result<()> {
        let peers = self.peers.read().await;
        for sender in peers.values() {
            let message = match &data {
                Either::A(value) => Message::Text(value.clone().into()),
                Either::B(value) => Message::Binary(value.to_vec().into()),
            };
            sender
                .send(message)
                .await
                .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?;
        }
        Ok(())
    }

    #[napi]
    pub async fn close_peer(
        &self,
        peer_id: u32,
        code: Option<u32>,
        reason: Option<String>,
    ) -> Result<()> {
        let peers = self.peers.read().await;
        if let Some(sender) = peers.get(&peer_id) {
            let frame = CloseFrame {
                code: CloseCode::from(code.unwrap_or(1000) as u16),
                reason: reason.unwrap_or_default().into(),
            };
            sender
                .send(Message::Close(Some(frame)))
                .await
                .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?;
        }
        Ok(())
    }

    #[napi]
    pub async fn stop(&self) -> Result<()> {
        if let Some(sender) = self.shutdown.lock().await.take() {
            let _ = sender.send(());
        }
        Ok(())
    }

    #[napi]
    pub unsafe fn on_peer_open(&mut self, callback: Function<u32, ()>) -> Result<()> {
        self.on_peer_open = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_peer_message(
        &mut self,
        callback: Function<NativePeerMessage, ()>,
    ) -> Result<()> {
        self.on_peer_message = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_peer_close(
        &mut self,
        callback: Function<NativePeerCloseEvent, ()>,
    ) -> Result<()> {
        self.on_peer_close = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
    #[napi]
    pub unsafe fn on_error(&mut self, callback: Function<String, ()>) -> Result<()> {
        self.on_error = Some(Arc::new(
            callback
                .build_threadsafe_function()
                .callee_handled::<false>()
                .build()?,
        ));
        Ok(())
    }
}

async fn run_peer(
    peer_id: u32,
    stream: TcpStream,
    peers: Arc<RwLock<HashMap<u32, mpsc::Sender<Message>>>>,
    on_open: Option<PeerCallback>,
    on_message: Option<PeerMessageCallback>,
    on_close: Option<PeerCloseCallback>,
) -> std::result::Result<(), String> {
    let websocket = accept_async(stream)
        .await
        .map_err(|error| error.to_string())?;
    let (mut sink, mut source) = websocket.split();
    let (sender, mut receiver) = mpsc::channel::<Message>(64);
    peers.write().await.insert(peer_id, sender.clone());
    if let Some(callback) = &on_open {
        callback.call(peer_id, ThreadsafeFunctionCallMode::NonBlocking);
    }
    let mut close_event = NativePeerCloseEvent {
        peer_id,
        code: 1006,
        reason: String::new(),
        clean: false,
    };
    loop {
        napi_ohos::tokio::select! {
          outbound = receiver.recv() => match outbound {
            Some(message) => if let Err(error) = sink.send(message).await { peers.write().await.remove(&peer_id); return Err(error.to_string()); },
            None => break,
          },
          inbound = source.next() => match inbound {
            Some(Ok(Message::Text(value))) => if let Some(callback) = &on_message {
              callback.call(NativePeerMessage { peer_id, data: Either::A(value.to_string()) }, ThreadsafeFunctionCallMode::NonBlocking);
            },
            Some(Ok(Message::Binary(value))) => if let Some(callback) = &on_message {
              callback.call(NativePeerMessage { peer_id, data: Either::B(Buffer::from(value.to_vec())) }, ThreadsafeFunctionCallMode::NonBlocking);
            },
            Some(Ok(Message::Ping(value))) => { if sender.send(Message::Pong(value)).await.is_err() { break; } },
            Some(Ok(Message::Close(frame))) => {
              if let Some(frame) = frame { close_event.code = u16::from(frame.code) as u32; close_event.reason = frame.reason.to_string(); close_event.clean = true; }
              break;
            },
            Some(Ok(_)) => {},
            Some(Err(error)) => { peers.write().await.remove(&peer_id); return Err(error.to_string()); },
            None => break,
          }
        }
    }
    peers.write().await.remove(&peer_id);
    if let Some(callback) = &on_close {
        callback.call(close_event, ThreadsafeFunctionCallMode::NonBlocking);
    }
    Ok(())
}

fn emit_error(callback: &Option<ErrorCallback>, message: String) {
    if let Some(callback) = callback {
        callback.call(message, ThreadsafeFunctionCallMode::NonBlocking);
    }
}

fn emit_close(callback: &Option<CloseCallback>, frame: Option<CloseFrame>, clean: bool) {
    if let Some(callback) = callback {
        let event = match frame {
            Some(frame) => NativeCloseEvent {
                code: u16::from(frame.code) as u32,
                reason: frame.reason.to_string(),
                clean,
            },
            None => NativeCloseEvent {
                code: 1006,
                reason: String::new(),
                clean: false,
            },
        };
        callback.call(event, ThreadsafeFunctionCallMode::NonBlocking);
    }
}
