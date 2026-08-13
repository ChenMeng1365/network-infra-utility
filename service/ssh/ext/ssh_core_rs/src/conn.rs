//! 连接管理器 — 管理全部 SSH 连接的生命周期。
//! 对应 Erlang 端的 ssh_conn_sup.erl + ssh_conn_worker.erl。
//!
//! 核心职责：
//!   - conn.connect：建立 SSH 连接，认证，返回 conn_id + fingerprint
//!   - conn.disconnect：断开指定连接
//!   - conn.list：列出所有活动连接
//!   - conn.reconnect：重连
//!   - 管理底层 russh Handle 和通道
//!   - 通过 gateway 推送 conn.ready / conn.failed / conn.closed 事件

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use russh::client;
use russh::client::KeyboardInteractiveAuthResponse;
use russh::keys::{PrivateKey, key::PrivateKeyWithHashAlg, HashAlg};
use serde_json::{json, Value};
use tokio::sync::{mpsc, RwLock};
use tokio::time::timeout;
use tracing::{debug, info, warn};

use crate::codec;
use crate::gateway::Gateway;
use crate::handler::{ConnEvent, ConnShared, SshHandler};
use crate::proto;

/// 连接超时（毫秒）
const CONNECT_TIMEOUT_MS: u64 = 60_000;

/// 单个 SSH 连接的状态
struct Connection {
    conn_id: String,
    spec: Value,
    shared: Arc<ConnShared>,
    handle: RwLock<Option<Arc<client::Handle<SshHandler>>>>,
    state: RwLock<ConnState>,
    /// 事件处理任务 handle
    event_task: RwLock<Option<tokio::task::JoinHandle<()>>>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ConnState {
    Idle,
    Connecting,
    Ready,
    Failed,
    Disconnected,
}

impl ConnState {
    fn as_str(&self) -> &'static str {
        match self {
            ConnState::Idle => "idle",
            ConnState::Connecting => "connecting",
            ConnState::Ready => "ready",
            ConnState::Failed => "failed",
            ConnState::Disconnected => "disconnected",
        }
    }
}

/// 连接管理器
pub struct ConnManager {
    connections: RwLock<HashMap<String, Arc<Connection>>>,
    gateway: Arc<Gateway>,
}

impl ConnManager {
    pub fn new(gateway: Arc<Gateway>) -> Arc<Self> {
        Arc::new(Self {
            connections: RwLock::new(HashMap::new()),
            gateway,
        })
    }

    /// RPC: conn.connect
    pub async fn rpc_connect(&self, params: Value) -> Result<Value, String> {
        let host = proto::get_str(&params, "host")
            .ok_or("missing host")?
            .to_string();
        let user = proto::get_str(&params, "user")
            .ok_or("missing user")?
            .to_string();
        let port = proto::get_num(&params, "port").unwrap_or(22.0) as u16;
        let connect_timeout = proto::get_num(&params, "connect_timeout_ms")
            .unwrap_or(CONNECT_TIMEOUT_MS as f64) as u64;
        let auth = params.get("auth").cloned().unwrap_or(json!({}));
        let key_dir = proto::get_str(&params, "key_dir").unwrap_or(".").to_string();

        let conn_id = codec::gen_conn_id();

        // 创建连接级事件通道
        let (conn_event_tx, conn_event_rx) = mpsc::unbounded_channel::<ConnEvent>();

        // 创建共享状态（handler 持有 Arc<ConnShared>）
        let shared = ConnShared::new(
            conn_id.clone(),
            host.clone(),
            port,
            Arc::clone(&self.gateway),
            conn_event_tx,
        );

        let conn = Arc::new(Connection {
            conn_id: conn_id.clone(),
            spec: params.clone(),
            shared: Arc::clone(&shared),
            handle: RwLock::new(None),
            state: RwLock::new(ConnState::Connecting),
            event_task: RwLock::new(None),
        });

        // 注册连接（在 connect 之前，以便 event_loop 能处理事件）
        self.connections
            .write()
            .await
            .insert(conn_id.clone(), Arc::clone(&conn));

        // 启动事件处理循环
        let gw = Arc::clone(&self.gateway);
        let cid = conn_id.clone();
        let conn_clone = Arc::clone(&conn);
        let event_task = tokio::spawn(async move {
            Self::event_loop(conn_clone, gw, cid, conn_event_rx).await;
        });
        *conn.event_task.write().await = Some(event_task);

        // 执行连接
        match self
            .establish_connection(
                &conn,
                &host,
                port,
                &user,
                &auth,
                &key_dir,
                connect_timeout,
            )
            .await
        {
            Ok(fingerprint) => {
                *conn.state.write().await = ConnState::Ready;

                // 推送 conn.ready 事件
                self.gateway
                    .push_event(
                        "conn.ready",
                        json!({
                            "conn_id": conn_id,
                            "fingerprint": fingerprint
                        }),
                    )
                    .await;

                Ok(json!({
                    "conn_id": conn_id,
                    "fingerprint": fingerprint
                }))
            }
            Err(e) => {
                *conn.state.write().await = ConnState::Failed;

                // 推送 conn.failed 事件
                self.gateway
                    .push_event(
                        "conn.failed",
                        json!({
                            "conn_id": conn_id,
                            "reason": e
                        }),
                    )
                    .await;

                // 移除连接
                self.connections.write().await.remove(&conn_id);
                Err(e)
            }
        }
    }

    /// 建立底层 SSH 连接并认证
    async fn establish_connection(
        &self,
        conn: &Arc<Connection>,
        host: &str,
        port: u16,
        user: &str,
        auth: &Value,
        key_dir: &str,
        connect_timeout_ms: u64,
    ) -> Result<String, String> {
        let auth_type = proto::get_str(auth, "type").unwrap_or("publickey");

        // russh 配置
        // inactivity_timeout 控制连接建立后的空闲断开，语义独立于 connect_timeout
        // 默认 None（不因空闲断开），由 keepalive 机制独立管理心跳
        let inactivity_secs = proto::get_num(&conn.spec, "inactivity_timeout_s")
            .map(|v| Duration::from_secs(v as u64));
        let config = Arc::new(client::Config {
            inactivity_timeout: inactivity_secs,
            ..Default::default()
        });

        // 创建 handler（持有 ConnShared Arc）
        let handler = SshHandler::new(Arc::clone(&conn.shared));

        // 发起 TCP + SSH 握手
        // russh 0.61: client::connect() 直接返回 Handle<SshHandler>，没有独立的 Session 层
        let addr = (host.to_string(), port);
        let connect_fut = client::connect(config, addr, handler);
        let connect_result = timeout(
            Duration::from_millis(connect_timeout_ms),
            connect_fut,
        )
        .await
        .map_err(|_| "connect_timeout".to_string())?;

        let mut handle = connect_result.map_err(|e| format!("connect_failed: {}", e))?;

        // 认证
        Self::authenticate(&mut handle, user, auth_type, auth, key_dir).await?;

        // 保存 handle（用 Arc 包装，以便 channel / keepalive 共享访问）
        *conn.handle.write().await = Some(Arc::new(handle));

        // 获取服务器指纹（check_server_key 回调中已写入 ConnShared）
        let fingerprint = conn.shared.get_server_fingerprint().await
            .unwrap_or_else(|| "SHA256:unknown".to_string());

        info!("conn {} established, fingerprint: {}", conn.conn_id, fingerprint);
        Ok(fingerprint)
    }

    /// 认证并返回服务器指纹
    async fn authenticate(
        handle: &mut client::Handle<SshHandler>,
        user: &str,
        auth_type: &str,
        auth: &Value,
        key_dir: &str,
    ) -> Result<(), String> {
        let auth_result = match auth_type {
            "password" => {
                let password = proto::get_str(auth, "password")
                    .ok_or("missing password")?;
                handle
                    .authenticate_password(user, password)
                    .await
                    .map_err(|e| format!("auth_password_failed: {}", e))?
            }
            "publickey" => {
                let key_path = proto::get_str(auth, "key_path")
                    .or_else(|| proto::get_str(auth, "private_key"));
                let passphrase = proto::get_str(auth, "passphrase");

                let key_pair: PrivateKey = if let Some(kp) = key_path {
                    // load_secret_key 统一处理加密/未加密密钥
                    // passphrase 为 Some 时尝试解密，为 None 时假定未加密
                    russh::keys::load_secret_key(kp, passphrase)
                        .map_err(|e| format!("key_load_failed: {}", e))?
                } else {
                    // 尝试从 key_dir 加载默认密钥（依次尝试 ed25519/rsa/ecdsa）
                    let default_keys = [
                        format!("{}/id_ed25519", key_dir),
                        format!("{}/id_rsa", key_dir),
                        format!("{}/id_ecdsa", key_dir),
                    ];
                    let mut loaded: Option<PrivateKey> = None;
                    for path in &default_keys {
                        if let Ok(kp) = russh::keys::load_secret_key(path, None) {
                            loaded = Some(kp);
                            break;
                        }
                    }
                    loaded.ok_or_else(|| "no_key_found".to_string())?
                };

                // RSA 密钥需要显式指定哈希算法。
                // russh PrivateKeyWithHashAlg::new(key, None) 对 RSA 会退化到 SHA-1，
                // 现代 OpenSSH (8.2+) 会拒绝 SHA-1 签名。
                // 优先查询服务器支持的算法（rsa-sha2-512 > rsa-sha2-256），
                // 服务器不支持时降级到 None（legacy sha-rsa），以保证兼容性。
                let hash_alg = if key_pair.algorithm().is_rsa() {
                    match handle.best_supported_rsa_hash().await {
                        Ok(Some(Some(alg))) => {
                            debug!("RSA using server-supported hash: {:?}", alg);
                            Some(alg)
                        }
                        Ok(Some(None)) => {
                            // 服务器支持 RSA 但不支持 rsa-sha2-*，降级到 legacy
                            warn!("RSA: server does not support rsa-sha2-*, falling back to legacy sha-rsa");
                            None
                        }
                        Ok(None) => {
                            // 服务器未发送 EXT_INFO，默认用 Sha256（最广泛兼容的现代算法）
                            debug!("RSA: no ext-info from server, defaulting to sha2-256");
                            Some(HashAlg::Sha256)
                        }
                        Err(e) => {
                            warn!("RSA: best_supported_rsa_hash failed: {}, defaulting to sha2-256", e);
                            Some(HashAlg::Sha256)
                        }
                    }
                } else {
                    // 非 RSA 密钥，hash_alg 被忽略
                    None
                };

                let key_with_alg = PrivateKeyWithHashAlg::new(
                    Arc::new(key_pair),
                    hash_alg,
                );

                handle
                    .authenticate_publickey(user, key_with_alg)
                    .await
                    .map_err(|e| format!("auth_publickey_failed: {}", e))?
            }
            "keyboard_interactive" => {
                // 真正的键盘交互认证（RFC 4256）。
                // 支持两种响应来源：
                //   1) auth.responses 数组（按 prompt 顺序一一对应）
                //   2) auth.password（单 prompt 场景，用密码作为唯一响应）
                let responses_spec = auth.get("responses")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .map(|v| v.as_str().unwrap_or("").to_string())
                            .collect::<Vec<_>>()
                    });
                let password = proto::get_str(auth, "password").map(|s| s.to_string());

                // 发起 keyboard-interactive 认证
                let kbi_result = handle
                    .authenticate_keyboard_interactive_start(user, None::<String>)
                    .await
                    .map_err(|e| format!("auth_kbi_start_failed: {}", e))?;

                let auth_result = Self::handle_kbi_response(
                    handle,
                    kbi_result,
                    responses_spec.as_deref(),
                    password.as_deref(),
                ).await?;

                auth_result
            }
            _ => return Err(format!("unsupported_auth_type: {}", auth_type)),
        };

        // russh 0.61: authenticate 返回 AuthResult 而非 bool
        if !auth_result.success() {
            return Err("auth_rejected".to_string());
        }

        Ok(())
    }

    /// 处理 keyboard-interactive 认证的多轮交互。
    /// 服务器可能发送多个 InfoRequest，每个含若干 prompt。
    /// responses_spec 和 password 作为响应来源，每次都复用。
    async fn handle_kbi_response(
        handle: &mut client::Handle<SshHandler>,
        mut kbi: KeyboardInteractiveAuthResponse,
        responses_spec: Option<&[String]>,
        password: Option<&str>,
    ) -> Result<russh::client::AuthResult, String> {
        let mut rounds = 0u32;
        loop {
            rounds += 1;
            if rounds > 10 {
                return Err("auth_kbi_too_many_rounds".to_string());
            }

            match kbi {
                KeyboardInteractiveAuthResponse::Success => {
                    // 认证成功——返回一个 success 的 AuthResult
                    // russh 0.61 没有直接从 KeyboardInteractiveAuthResponse 到 AuthResult 的转换，
                    // 但 success 状态等同于 authenticate_* 返回的 AuthResult::Success
                    return Ok(russh::client::AuthResult::Success);
                }
                KeyboardInteractiveAuthResponse::Failure { .. } => {
                    return Err("auth_kbi_rejected".to_string());
                }
                KeyboardInteractiveAuthResponse::InfoRequest { prompts, .. } => {
                    // 构建响应：按 prompt 数量生成回复
                    let responses: Vec<String> = if let Some(spec) = responses_spec {
                        // 使用预设 responses 数组
                        prompts.iter().enumerate().map(|(i, _)| {
                            spec.get(i).cloned().unwrap_or_default()
                        }).collect()
                    } else if let Some(pwd) = password {
                        // 单密码场景：每个 prompt 都用密码回复
                        prompts.iter().map(|_| pwd.to_string()).collect()
                    } else {
                        return Err("auth_kbi_no_response_source".to_string());
                    };

                    // 发送响应，等待下一轮
                    kbi = handle
                        .authenticate_keyboard_interactive_respond(responses)
                        .await
                        .map_err(|e| format!("auth_kbi_respond_failed: {}", e))?;
                }
            }
        }
    }

    /// 事件处理循环（从 russh handler 接收连接级事件，推送到 IPC）
    async fn event_loop(
        conn: Arc<Connection>,
        gateway: Arc<Gateway>,
        conn_id: String,
        mut event_rx: mpsc::UnboundedReceiver<ConnEvent>,
    ) {
        while let Some(event) = event_rx.recv().await {
            match event {
                ConnEvent::Disconnected => {
                    *conn.state.write().await = ConnState::Disconnected;
                    gateway
                        .push_event(
                            "conn.closed",
                            json!({
                                "conn_id": conn_id,
                                "reason": "ssh_closed"
                            }),
                        )
                        .await;
                }
            }
        }
        debug!("conn {} event loop ended", conn_id);
    }

    /// RPC: conn.disconnect
    pub async fn rpc_disconnect(&self, params: Value) -> Result<Value, String> {
        let conn_id = proto::get_str(&params, "id")
            .ok_or("missing id")?
            .to_string();

        let conn = self.connections.write().await.remove(&conn_id);
        match conn {
            Some(c) => {
                *c.state.write().await = ConnState::Disconnected;

                // 关闭底层 SSH 连接
                let mut handle_guard = c.handle.write().await;
                if let Some(h) = handle_guard.take() {
                    let _ = h
                        .disconnect(
                            russh::Disconnect::ByApplication,
                            "client disconnect",
                            "en",
                        )
                        .await;
                }
                drop(handle_guard);

                // 取消事件处理任务
                if let Some(task) = c.event_task.write().await.take() {
                    task.abort();
                }
                Ok(json!({"ok": true}))
            }
            None => Err("conn_not_found".to_string()),
        }
    }

    /// RPC: conn.list
    pub async fn rpc_list(&self, _params: Value) -> Result<Value, String> {
        let conns = self.connections.read().await;
        let mut list = Vec::with_capacity(conns.len());
        for c in conns.values() {
            let state = *c.state.read().await;
            list.push(json!({
                "id": c.conn_id,
                "state": state.as_str(),
                "host": c.spec.get("host").cloned().unwrap_or(Value::Null),
                "port": c.spec.get("port").cloned().unwrap_or(json!(22)),
            }));
        }
        Ok(Value::Array(list))
    }

    /// RPC: conn.reconnect
    pub async fn rpc_reconnect(&self, params: Value) -> Result<Value, String> {
        let conn_id = proto::get_str(&params, "id")
            .ok_or("missing id")?
            .to_string();

        let conn = {
            let conns = self.connections.read().await;
            conns.get(&conn_id).cloned()
        };
        let conn = match conn {
            Some(c) => c,
            None => return Err("conn_not_found".to_string()),
        };

        *conn.state.write().await = ConnState::Connecting;

        // 从 spec 中提取连接参数
        let host = proto::get_str(&conn.spec, "host")
            .unwrap_or("")
            .to_string();
        let user = proto::get_str(&conn.spec, "user")
            .unwrap_or("")
            .to_string();
        let port = proto::get_num(&conn.spec, "port").unwrap_or(22.0) as u16;
        let auth = conn.spec.get("auth").cloned().unwrap_or(json!({}));
        let key_dir = proto::get_str(&conn.spec, "key_dir")
            .unwrap_or(".")
            .to_string();
        let timeout_ms = proto::get_num(&conn.spec, "connect_timeout_ms")
            .unwrap_or(CONNECT_TIMEOUT_MS as f64) as u64;

        match self
            .establish_connection(&conn, &host, port, &user, &auth, &key_dir, timeout_ms)
            .await
        {
            Ok(fingerprint) => {
                *conn.state.write().await = ConnState::Ready;
                self.gateway
                    .push_event(
                        "conn.ready",
                        json!({
                            "conn_id": conn_id,
                            "fingerprint": fingerprint
                        }),
                    )
                    .await;
                Ok(json!({"conn_id": conn_id, "fingerprint": fingerprint}))
            }
            Err(e) => {
                *conn.state.write().await = ConnState::Failed;
                self.gateway
                    .push_event(
                        "conn.failed",
                        json!({
                            "conn_id": conn_id,
                            "reason": e
                        }),
                    )
                    .await;
                Err(e)
            }
        }
    }

    /// 获取所有活动的连接 ID
    pub async fn all_conn_ids(&self) -> Vec<String> {
        self.connections
            .read()
            .await
            .keys()
            .cloned()
            .collect()
    }

    /// 获取指定连接的 handle 和 shared（用于通道操作）
    pub async fn get_handle_and_shared(
        &self,
        conn_id: &str,
    ) -> Option<(Arc<client::Handle<SshHandler>>, Arc<ConnShared>)> {
        let conns = self.connections.read().await;
        let conn = conns.get(conn_id)?;
        let handle = conn.handle.read().await.clone()?;
        Some((handle, Arc::clone(&conn.shared)))
    }

    /// 获取指定连接的 handle（用于 keepalive）
    pub async fn get_handle(&self, conn_id: &str) -> Option<Arc<client::Handle<SshHandler>>> {
        let conns = self.connections.read().await;
        let conn = conns.get(conn_id)?;
        let handle = conn.handle.read().await.clone()?;
        Some(handle)
    }

    /// 获取所有 Ready 状态的连接 ID（用于 keepalive 扫描）
    pub async fn ready_conn_ids(&self) -> Vec<String> {
        let conns = self.connections.read().await;
        let mut ids = Vec::new();
        for (id, conn) in conns.iter() {
            if *conn.state.read().await == ConnState::Ready {
                ids.push(id.clone());
            }
        }
        ids
    }

    /// 标记连接为失败（keepalive 超时后调用）
    pub async fn mark_conn_closed(&self, conn_id: &str, reason: &str) {
        // 先取读锁拿状态，避免死锁（push_event 可可会触发 IPC 回调）
        let found = {
            let conns = self.connections.read().await;
            if let Some(conn) = conns.get(conn_id) {
                *conn.state.write().await = ConnState::Failed;
                true
            } else {
                false
            }
        };
        if found {
            self.gateway
                .push_event(
                    "conn.closed",
                    json!({
                        "conn_id": conn_id,
                        "reason": reason
                    }),
                )
                .await;
        }
    }

    /// 获取连接的活动通知通道（用于 keepalive 活动感知）
    /// 通过 shared 的 channel_txs 间接判断——当有数据流过时触发
    pub async fn is_conn_ready(&self, conn_id: &str) -> bool {
        let conns = self.connections.read().await;
        if let Some(conn) = conns.get(conn_id) {
            *conn.state.read().await == ConnState::Ready
        } else {
            false
        }
    }
}
