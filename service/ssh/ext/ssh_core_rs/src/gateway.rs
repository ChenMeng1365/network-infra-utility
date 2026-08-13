//! IPC 网关 — TCP 监听、JSON-RPC 路由、推送、反向 RPC。
//! 对应 Erlang 端的 ssh_ipc_gateway.erl。
//!
//! 核心设计（与 Erlang 端完全对齐）：
//!   - 监听 127.0.0.1 随机端口，写入端点文件供 Ruby 读取
//!   - hello 握手认证（auth_token）
//!   - 路由表：method → 处理函数
//!   - 推送：push_event / push_batch（notification，无 id）
//!   - 反向 RPC：synchronous_push（Rust→Ruby 带 id 的请求，阻塞等响应）

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, Mutex, RwLock};
use tracing::{debug, error, info, warn};

use crate::proto;

/// RPC 处理函数类型：接收 params，返回 Result<Value, String>
type RpcHandler = Arc<
    dyn Fn(Value) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value, String>> + Send>>
        + Send
        + Sync,
>;

/// 反向 RPC 待处理条目
struct ReversePending {
    tx: oneshot::Sender<Result<Value, String>>,
}

/// 客户端连接信息
struct ClientInfo {
    writer_tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    authed: bool,
    reader_handle: Option<tokio::task::JoinHandle<()>>,
}

/// 网关共享状态
pub struct Gateway {
    auth_token: String,
    routes: RwLock<HashMap<String, RpcHandler>>,
    clients: RwLock<Vec<Arc<Mutex<ClientInfo>>>>,
    reverse_pending: Mutex<HashMap<i64, ReversePending>>,
    next_reverse_id: AtomicI64,
}

impl Gateway {
    /// 创建网关实例
    pub fn new(auth_token: String) -> Arc<Self> {
        Arc::new(Self {
            auth_token,
            routes: RwLock::new(HashMap::new()),
            clients: RwLock::new(Vec::new()),
            reverse_pending: Mutex::new(HashMap::new()),
            next_reverse_id: AtomicI64::new(1000000),
        })
    }

    /// 注册 RPC 路由
    pub async fn register_route<F, Fut>(&self, method: &str, handler: F)
    where
        F: Fn(Value) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = Result<Value, String>> + Send + 'static,
    {
        let handler_arc: RpcHandler = Arc::new(move |params| {
            let f = handler(params);
            Box::pin(f)
        });
        self.routes.write().await.insert(method.to_string(), handler_arc);
    }

    /// 启动 TCP 监听并写入端点文件
    pub async fn start(self: Arc<Self>, endpoint_file: PathBuf) -> Result<(), String> {
        // 监听 127.0.0.1:0（OS 分配端口）
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| format!("bind failed: {}", e))?;

        let port = listener
            .local_addr()
            .map_err(|e| format!("local_addr failed: {}", e))?
            .port();

        // 写入端点文件：第一行 tcp://127.0.0.1:<port>，第二行 auth_token
        let endpoint_content = format!("tcp://127.0.0.1:{}\n{}", port, self.auth_token);
        std::fs::write(&endpoint_file, &endpoint_content)
            .map_err(|e| format!("write endpoint file failed: {}", e))?;

        // 设置文件权限（Unix: 600）
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&endpoint_file)
                .map_err(|e| format!("metadata failed: {}", e))?
                .permissions();
            perms.set_mode(0o600);
            let _ = std::fs::set_permissions(&endpoint_file, perms);
        }

        info!("IPC gateway listening on 127.0.0.1:{}", port);
        info!("endpoint file: {}", endpoint_file.display());

        // 接受连接循环
        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    debug!("new client connection from {}", addr);
                    let gw = Arc::clone(&self);
                    tokio::spawn(async move {
                        gw.handle_client(stream).await;
                    });
                }
                Err(e) => {
                    error!("accept failed: {}", e);
                }
            }
        }
    }

    /// 处理单个客户端连接
    async fn handle_client(self: Arc<Self>, stream: TcpStream) {
        let (reader, mut writer) = stream.into_split();

        // 创建写通道
        let (writer_tx, mut writer_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();

        let client = Arc::new(Mutex::new(ClientInfo {
            writer_tx: writer_tx.clone(),
            authed: false,
            reader_handle: None,
        }));

        // 注册客户端
        self.clients.write().await.push(Arc::clone(&client));

        // 启动写任务
        let write_task = tokio::spawn(async move {
            while let Some(data) = writer_rx.recv().await {
                if writer.write_all(&data).await.is_err() {
                    break;
                }
            }
        });

        // 读取循环
        let buf_reader = BufReader::new(reader);
        let mut lines = buf_reader.lines();
        let mut leftover = String::new();

        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    let frame = if leftover.is_empty() {
                        line
                    } else {
                        format!("{}{}", leftover, line)
                    };
                    leftover.clear();

                    if frame.is_empty() {
                        continue;
                    }

                    // 检查消息大小
                    if frame.len() > proto::MAX_MSG_SIZE {
                        warn!("message too large ({} bytes), discarding", frame.len());
                        continue;
                    }

                    let msg = match proto::decode(frame.as_bytes()) {
                        Ok(m) => m,
                        Err(e) => {
                            warn!("decode error: {}", e);
                            continue;
                        }
                    };

                    self.handle_message(msg, &client).await;
                }
                Ok(None) => {
                    // EOF
                    debug!("client disconnected");
                    break;
                }
                Err(e) => {
                    debug!("read error: {}", e);
                    break;
                }
            }
        }

        // 清理：从客户端列表移除
        self.clients.write().await.retain(|c| {
            !Arc::ptr_eq(c, &client)
        });

        write_task.abort();
    }

    /// 处理收到的消息
    async fn handle_message(&self, msg: proto::Message, client: &Arc<Mutex<ClientInfo>>) {
        match msg {
            proto::Message::Request { id, method, params } => {
                if method == "hello" {
                    // hello 握手认证
                    let result = self.handle_hello(&params).await;
                    match result {
                        Ok(resp) => {
                            // 认证成功
                            client.lock().await.authed = true;
                            self.send_response(id, &resp, client).await;
                        }
                        Err(e) => {
                            self.send_error(id, -32001, &e, client).await;
                        }
                    }
                    return;
                }

                // 检查是否已认证
                if !client.lock().await.authed {
                    self.send_error(id, -32000, "not authenticated", client).await;
                    return;
                }

                // 路由到处理函数
                let handler = self.routes.read().await.get(&method).cloned();
                match handler {
                    Some(h) => {
                        let client_clone = Arc::clone(client);
                        let id_clone = id;
                        let self_clone = Arc::new(()); // 不需要 self，直接用闭包
                        tokio::spawn(async move {
                            let _ = self_clone; // 消除警告
                            match h(params).await {
                                Ok(result) => {
                                    client_clone
                                        .lock()
                                        .await
                                        .writer_tx
                                        .send(proto::frame(&proto::encode_response(id_clone, &result)))
                                        .ok();
                                }
                                Err(e) => {
                                    client_clone
                                        .lock()
                                        .await
                                        .writer_tx
                                        .send(proto::frame(&proto::encode_error(id_clone, -32603, &e)))
                                        .ok();
                                }
                            }
                        });
                    }
                    None => {
                        self.send_error(id, -32601, &format!("method not found: {}", method), client)
                            .await;
                    }
                }
            }
            proto::Message::Response { id, result, error } => {
                // 反向 RPC 的响应
                let mut pending = self.reverse_pending.lock().await;
                if let Some(entry) = pending.remove(&id) {
                    if let Some(err) = error {
                        let _ = entry.tx.send(Err(err.to_string()));
                    } else {
                        let _ = entry.tx.send(Ok(result.unwrap_or(Value::Null)));
                    }
                }
            }
            proto::Message::Notification { .. } => {
                // Ruby→Rust 的通知，目前忽略
                debug!("received notification from Ruby (ignored)");
            }
        }
    }

    /// 处理 hello 握手
    async fn handle_hello(&self, params: &Value) -> Result<Value, String> {
        let token = proto::get_str(params, "auth_token").unwrap_or("");
        if token != self.auth_token {
            return Err("auth_failed".to_string());
        }

        Ok(json!({
            "capabilities": ["coalesce"],
            "ver": proto::PROTOCOL_VER
        }))
    }

    /// 发送响应给客户端
    async fn send_response(&self, id: i64, result: &Value, client: &Arc<Mutex<ClientInfo>>) {
        let data = proto::frame(&proto::encode_response(id, result));
        let _ = client.lock().await.writer_tx.send(data);
    }

    /// 发送错误给客户端
    async fn send_error(&self, id: i64, code: i64, message: &str, client: &Arc<Mutex<ClientInfo>>) {
        let data = proto::frame(&proto::encode_error(id, code, message));
        let _ = client.lock().await.writer_tx.send(data);
    }

    /// 推送通知给所有已认证客户端
    pub async fn push_event(&self, method: &str, params: Value) {
        let data = proto::frame(&proto::encode_push(method, &params));
        let clients = self.clients.read().await;
        for client in clients.iter() {
            let c = client.lock().await;
            if c.authed {
                let _ = c.writer_tx.send(data.clone());
            }
        }
    }

    /// 推送批量通知（channel.data.batch）
    pub async fn push_batch(&self, params: Value) {
        self.push_event("channel.data.batch", params).await;
    }

    /// 同步反向 RPC（Rust→Ruby）：发送带 id 的请求，阻塞等响应。
    /// 用于 hostkey.resolve。
    pub async fn synchronous_push(
        &self,
        method: &str,
        params: Value,
        timeout_ms: u64,
    ) -> Result<Value, String> {
        let id = self.next_reverse_id.fetch_add(1, Ordering::SeqCst);

        let (tx, rx) = oneshot::channel();
        self.reverse_pending
            .lock()
            .await
            .insert(id, ReversePending { tx });

        // 构造反向 RPC 请求消息（有 id 和 method）
        let msg = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        });
        let data = proto::frame(&msg.to_string());

        // 发送给所有已认证客户端
        let sent = {
            let clients = self.clients.read().await;
            let mut sent = false;
            for client in clients.iter() {
                let c = client.lock().await;
                if c.authed {
                    let _ = c.writer_tx.send(data.clone());
                    sent = true;
                }
            }
            sent
        };

        if !sent {
            self.reverse_pending.lock().await.remove(&id);
            return Err("no_clients".to_string());
        }

        // 等待响应或超时
        match tokio::time::timeout(Duration::from_millis(timeout_ms), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => {
                self.reverse_pending.lock().await.remove(&id);
                Err("channel closed".to_string())
            }
            Err(_) => {
                self.reverse_pending.lock().await.remove(&id);
                Err("timeout".to_string())
            }
        }
    }

    /// 获取已连接客户端数
    pub async fn client_count(&self) -> usize {
        self.clients.read().await.len()
    }
}
