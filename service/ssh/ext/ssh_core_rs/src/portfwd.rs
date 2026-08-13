//! 端口转发管理器 — 管理本地/远程端口转发规则。
//! 对应 Erlang 端的 ssh_port_fwd.erl。
//!
//! 核心设计：
//!   - 本地转发：tokio TcpListener 监听本地端口 → SSH channel_open_direct_tcpip → 远程
//!   - 远程转发：handle.tcpip_forward() 请求 SSH 服务器在远端监听 → 推送转发数据
//!   - 每条规则有唯一 rule_id，可动态添加/删除/列举
//!   - 本地转发的 listener task 在规则删除时通过 AbortHandle 取消

use std::collections::HashMap;
use std::sync::Arc;

use russh::client;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::RwLock;
use tokio::task::AbortHandle;
use tracing::{debug, info, warn};

use crate::codec;
use crate::conn::ConnManager;
use crate::handler::SshHandler;
use crate::proto;

/// 端口转发类型
#[derive(Debug, Clone, Copy, PartialEq)]
enum FwdType {
    Local,
    Remote,
}

impl FwdType {
    fn as_str(&self) -> &'static str {
        match self {
            FwdType::Local => "local",
            FwdType::Remote => "remote",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "local" => Some(FwdType::Local),
            "remote" => Some(FwdType::Remote),
            _ => None,
        }
    }
}

/// 转发规则
struct FwdRule {
    rule_id: String,
    conn_id: String,
    fwd_type: FwdType,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
    /// 本地转发：listener task 的 abort handle
    abort_handle: Option<AbortHandle>,
}

/// 端口转发管理器
pub struct PortFwdManager {
    /// rule_id → 转发规则
    rules: RwLock<HashMap<String, FwdRule>>,
    /// 连接管理器引用
    conn_mgr: Arc<ConnManager>,
}

impl PortFwdManager {
    pub fn new(conn_mgr: Arc<ConnManager>) -> Arc<Self> {
        Arc::new(Self {
            rules: RwLock::new(HashMap::new()),
            conn_mgr,
        })
    }

    /// RPC: portfwd.add — 添加端口转发规则
    pub async fn rpc_add(&self, params: Value) -> Result<Value, String> {
        let conn_id = proto::get_str(&params, "conn_id")
            .ok_or("missing conn_id")?
            .to_string();
        let type_str = proto::get_str(&params, "type").unwrap_or("local");
        let local_port = proto::get_num(&params, "local_port").unwrap_or(0.0) as u16;
        let remote_host = proto::get_str(&params, "remote_host")
            .unwrap_or("127.0.0.1")
            .to_string();
        let remote_port = proto::get_num(&params, "remote_port").unwrap_or(0.0) as u16;

        let fwd_type = FwdType::from_str(type_str)
            .ok_or_else(|| format!("invalid_fwd_type: {}", type_str))?;

        if local_port == 0 {
            return Err("missing_local_port".to_string());
        }

        let rule_id = codec::gen_rule_id(&conn_id);

        match fwd_type {
            FwdType::Local => {
                self.add_local_forward(&conn_id, &rule_id, local_port, &remote_host, remote_port)
                    .await?;
            }
            FwdType::Remote => {
                self.add_remote_forward(&conn_id, &rule_id, local_port, &remote_host, remote_port)
                    .await?;
            }
        }

        info!("portfwd.add: conn={} rule={} type={} local_port={} -> {}:{}",
              conn_id, rule_id, fwd_type.as_str(), local_port, remote_host, remote_port);

        Ok(json!({
            "rule_id": rule_id
        }))
    }

    /// RPC: portfwd.remove — 删除端口转发规则
    pub async fn rpc_remove(&self, params: Value) -> Result<Value, String> {
        let rule_id = proto::get_str(&params, "rule_id")
            .ok_or("missing rule_id")?
            .to_string();

        let mut rules = self.rules.write().await;
        let rule = rules.remove(&rule_id);
        match rule {
            Some(r) => {
                // 本地转发：abort listener task
                if let Some(handle) = r.abort_handle {
                    handle.abort();
                }

                // 远程转发：请求服务器取消转发
                if r.fwd_type == FwdType::Remote {
                    if let Some(handle) = self.conn_mgr.get_handle(&r.conn_id).await {
                        let _ = handle
                            .cancel_tcpip_forward(&r.remote_host, r.local_port.into())
                            .await;
                    }
                }

                info!("portfwd.remove: rule={}", rule_id);
                Ok(json!({"ok": true}))
            }
            None => Err("rule_not_found".to_string()),
        }
    }

    /// RPC: portfwd.list — 列出所有转发规则
    pub async fn rpc_list(&self, params: Value) -> Result<Value, String> {
        let conn_id = proto::get_str(&params, "conn_id");
        let rules = self.rules.read().await;
        let items: Vec<Value> = rules
            .iter()
            .filter(|(_, r)| conn_id.is_none() || Some(r.conn_id.as_str()) == conn_id)
            .map(|(id, r)| {
                json!({
                    "rule_id": id,
                    "conn_id": r.conn_id,
                    "type": r.fwd_type.as_str(),
                    "local_port": r.local_port,
                    "remote_host": r.remote_host,
                    "remote_port": r.remote_port,
                })
            })
            .collect();

        Ok(json!({"rules": Value::Array(items)}))
    }

    /// 添加本地端口转发
    async fn add_local_forward(
        &self,
        conn_id: &str,
        rule_id: &str,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<(), String> {
        // 绑定本地 TCP 监听
        let listener = TcpListener::bind(("127.0.0.1", local_port))
            .await
            .map_err(|e| format!("listen_failed: {}", e))?;

        let actual_port = listener
            .local_addr()
            .map(|a| a.port())
            .unwrap_or(local_port);

        let handle = self
            .conn_mgr
            .get_handle(conn_id)
            .await
            .ok_or("conn_not_found")?;

        let remote_host = remote_host.to_string();
        let conn_id_owned = conn_id.to_string();

        // 启动 listener task
        let task = tokio::spawn({
            let rh = remote_host.clone();
            async move {
                Self::local_forward_loop(listener, handle, rh, remote_port, conn_id_owned).await;
            }
        });

        let abort_handle = task.abort_handle();

        let rule = FwdRule {
            rule_id: rule_id.to_string(),
            conn_id: conn_id.to_string(),
            fwd_type: FwdType::Local,
            local_port: actual_port,
            remote_host: remote_host.to_string(),
            remote_port,
            abort_handle: Some(abort_handle),
        };
        self.rules.write().await.insert(rule_id.to_string(), rule);

        Ok(())
    }

    /// 添加远程端口转发
    async fn add_remote_forward(
        &self,
        conn_id: &str,
        rule_id: &str,
        remote_port: u16,
        local_host: &str,
        local_port: u16,
    ) -> Result<(), String> {
        let handle = self
            .conn_mgr
            .get_handle(conn_id)
            .await
            .ok_or("conn_not_found")?;

        // 请求 SSH 服务器在远端监听
        handle
            .tcpip_forward(local_host, local_port.into())
            .await
            .map_err(|e| format!("tcpip_forward_failed: {}", e))?;

        let rule = FwdRule {
            rule_id: rule_id.to_string(),
            conn_id: conn_id.to_string(),
            fwd_type: FwdType::Remote,
            local_port: remote_port,
            remote_host: local_host.to_string(),
            remote_port: local_port,
            abort_handle: None,
        };
        self.rules.write().await.insert(rule_id.to_string(), rule);

        Ok(())
    }

    /// 本地转发循环：接受 TCP 连接 → SSH direct_tcpip → 双向数据转发
    async fn local_forward_loop(
        listener: TcpListener,
        handle: Arc<client::Handle<SshHandler>>,
        remote_host: String,
        remote_port: u16,
        conn_id: String,
    ) {
        loop {
            match listener.accept().await {
                Ok((client_sock, client_addr)) => {
                    debug!("portfwd: accepted connection from {} on conn {}", client_addr, conn_id);

                    let handle = Arc::clone(&handle);
                    let rh = remote_host.clone();
                    let rp = remote_port;

                    // 每个连接独立 spawn 一个转发任务
                    tokio::spawn(async move {
                        Self::handle_forward_connection(
                            client_sock,
                            handle,
                            rh,
                            rp,
                        )
                        .await;
                    });
                }
                Err(e) => {
                    warn!("portfwd: accept failed on conn {}: {}", conn_id, e);
                    break;
                }
            }
        }
    }

    /// 处理单个本地转发连接
    async fn handle_forward_connection(
        mut client_sock: TcpStream,
        handle: Arc<client::Handle<SshHandler>>,
        remote_host: String,
        remote_port: u16,
    ) {
        // 通过 SSH 打开 direct_tcpip 通道
        let channel = match handle
            .channel_open_direct_tcpip(&remote_host, remote_port.into(), "127.0.0.1", 0)
            .await
        {
            Ok(ch) => ch,
            Err(e) => {
                warn!("portfwd: direct_tcpip failed to {}:{}: {}", remote_host, remote_port, e);
                return;
            }
        };

        // 获取通道的读写流
        let (mut ch_reader, mut ch_writer) = {
            let stream = channel.into_stream();
            tokio::io::split(stream)
        };

        // 拆分 TCP socket 为读写两半，避免双重借用
        let (mut sock_reader, mut sock_writer) = tokio::io::split(&mut client_sock);

        // 双向数据转发
        let client_to_remote = async {
            let mut buf = [0u8; 32768];
            loop {
                match sock_reader.read(&mut buf).await {
                    Ok(0) => break,    // EOF
                    Ok(n) => {
                        if ch_writer.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                        let _ = ch_writer.flush().await;
                    }
                    Err(_) => break,
                }
            }
        };

        let remote_to_client = async {
            let mut buf = [0u8; 32768];
            loop {
                match ch_reader.read(&mut buf).await {
                    Ok(0) => break,    // EOF
                    Ok(n) => {
                        if sock_writer.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                        let _ = sock_writer.flush().await;
                    }
                    Err(_) => break,
                }
            }
        };

        tokio::join!(client_to_remote, remote_to_client);

        let _ = client_sock.shutdown().await;
    }

    /// 清理指定连接的所有转发规则（连接断开时调用）
    pub async fn cleanup_conn(&self, conn_id: &str) {
        let mut rules = self.rules.write().await;
        let to_remove: Vec<String> = rules
            .iter()
            .filter(|(_, r)| r.conn_id == conn_id)
            .map(|(k, _)| k.clone())
            .collect();

        for id in &to_remove {
            if let Some(rule) = rules.remove(id) {
                if let Some(handle) = rule.abort_handle {
                    handle.abort();
                }
                warn!("portfwd rule {} cleaned up (conn {} disconnected)", id, conn_id);
            }
        }
    }
}
