//! 通道管理器 — 管理所有 SSH 通道的打开、发送、关闭和窗口变更。
//! 对应 Erlang 端的 ssh_channel_stm.erl。
//!
//! 核心职责：
//!   - channel.open：打开 shell/exec/subsystem 通道，请求 PTY，返回 channel_id
//!   - channel.send：Base64 解码后向通道发送数据
//!   - channel.close：关闭通道
//!   - channel.window_change：变更 PTY 窗口大小
//!   - 通过 handler 的 ConnShared 注册数据接收器，推送 channel.data / channel.eof

use std::collections::HashMap;
use std::sync::Arc;

use russh::Channel;
use russh::client;
use serde_json::{json, Value};
use tokio::sync::{mpsc, RwLock};
use tracing::debug;

use crate::codec;
use crate::coalesce::Coalescer;
use crate::conn::ConnManager;
use crate::handler::{ChannelData, ConnShared};
use crate::proto;

/// 通道管理器
pub struct ChannelManager {
    /// IPC channel_id → 通道状态
    channels: RwLock<HashMap<String, ChannelEntry>>,
    /// 连接管理器引用
    conn_mgr: Arc<ConnManager>,
    /// coalesce 引用（用于数据推送）
    coalesce: Arc<Coalescer>,
}

/// 单个通道的状态
struct ChannelEntry {
    conn_id: String,
    russh_ch_id: russh::ChannelId,
    /// 通道对象（通过 Arc<Mutex> 保护，可 clone Arc）
    channel: Arc<tokio::sync::Mutex<Channel<client::Msg>>>,
    /// 数据接收任务 handle
    data_task: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl ChannelManager {
    pub fn new(conn_mgr: Arc<ConnManager>, coalesce: Arc<Coalescer>) -> Arc<Self> {
        Arc::new(Self {
            channels: RwLock::new(HashMap::new()),
            conn_mgr,
            coalesce,
        })
    }

    /// RPC: channel.open
    pub async fn rpc_open(&self, params: Value) -> Result<Value, String> {
        let conn_id = proto::get_str(&params, "conn_id")
            .ok_or("missing conn_id")?
            .to_string();
        let ch_type = proto::get_str(&params, "type").unwrap_or("shell");
        let cols = proto::get_num(&params, "cols").unwrap_or(80.0) as u32;
        let rows = proto::get_num(&params, "rows").unwrap_or(24.0) as u32;
        let term_type = proto::get_str(&params, "term").unwrap_or("xterm-256color");
        let command = proto::get_str(&params, "command");

        // 获取连接的 handle 和 shared
        let (handle, shared) = self
            .conn_mgr
            .get_handle_and_shared(&conn_id)
            .await
            .ok_or("conn_not_found")?;

        // 打开 session 通道
        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("channel_open_failed: {}", e))?;

        let russh_ch_id = channel.id();
        let ipc_ch_id = codec::gen_channel_id(&conn_id);

        // 根据类型初始化通道
        match ch_type {
            "shell" => {
                // 请求 PTY
                channel
                    .request_pty(true, term_type, cols, rows, 0, 0, &[])
                    .await
                    .map_err(|e| format!("pty_request_failed: {}", e))?;
                // 请求 shell
                channel
                    .request_shell(true)
                    .await
                    .map_err(|e| format!("shell_request_failed: {}", e))?;
            }
            "exec" => {
                let cmd = command.ok_or("missing command for exec")?;
                channel
                    .exec(true, cmd)
                    .await
                    .map_err(|e| format!("exec_failed: {}", e))?;
            }
            "subsystem" => {
                let subsystem = command.ok_or("missing subsystem name")?;
                channel
                    .request_subsystem(true, subsystem)
                    .await
                    .map_err(|e| format!("subsystem_failed: {}", e))?;
            }
            _ => return Err(format!("unsupported_channel_type: {}", ch_type)),
        }

        // 注册数据接收器到 ConnShared（handler 的 data 回调会通过此 tx 推送数据）
        let (data_tx, data_rx) = mpsc::unbounded_channel::<ChannelData>();
        shared.register_channel_tx(russh_ch_id, data_tx).await;

        // 启动数据接收循环（从 handler 转发的数据推送到 coalesce / IPC）
        let coalesce = Arc::clone(&self.coalesce);
        let ipc_ch_id_clone = ipc_ch_id.clone();
        let conn_id_clone = conn_id.clone();
        let shared_clone = Arc::clone(&shared);
        let russh_id_for_close = russh_ch_id;
        let data_task = tokio::spawn(async move {
            Self::data_receive_loop(
                data_rx,
                coalesce,
                ipc_ch_id_clone,
                conn_id_clone,
                shared_clone,
                russh_id_for_close,
            )
            .await;
        });

        // 保存通道状态
        let entry = ChannelEntry {
            conn_id: conn_id.clone(),
            russh_ch_id,
            channel: Arc::new(tokio::sync::Mutex::new(channel)),
            data_task: tokio::sync::Mutex::new(Some(data_task)),
        };
        self.channels
            .write()
            .await
            .insert(ipc_ch_id.clone(), entry);

        debug!(
            "channel.open: conn={} ipc_ch={} russh_ch={} type={}",
            conn_id, ipc_ch_id, russh_ch_id, ch_type
        );

        Ok(json!({
            "channel_id": ipc_ch_id
        }))
    }

    /// RPC: channel.send
    pub async fn rpc_send(&self, params: Value) -> Result<Value, String> {
        let ch_id = proto::get_str(&params, "id")
            .ok_or("missing id")?
            .to_string();
        let b64_data = proto::get_str(&params, "data")
            .ok_or("missing data")?;

        let data = codec::decode_b64(b64_data).map_err(|e| format!("base64_decode_failed: {}", e))?;

        let channel_arc = {
            let channels = self.channels.read().await;
            channels
                .get(&ch_id)
                .map(|e| Arc::clone(&e.channel))
                .ok_or("channel_not_found")?
        };

        // 通过 russh Channel 发送数据
        let ch = channel_arc.lock().await;
        ch.data(data.as_slice())
            .await
            .map_err(|e| format!("send_failed: {}", e))?;

        debug!("channel.send: ch={} bytes={}", ch_id, data.len());
        Ok(json!({"ok": true}))
    }

    /// RPC: channel.close
    pub async fn rpc_close(&self, params: Value) -> Result<Value, String> {
        let ch_id = proto::get_str(&params, "id")
            .ok_or("missing id")?
            .to_string();

        let entry = self.channels.write().await.remove(&ch_id);
        match entry {
            Some(e) => {
                // 关闭 russh 通道
                {
                    let ch = e.channel.lock().await;
                    let _ = ch.close().await;
                }

                // 注销数据接收器
                // 获取 shared 来注销——需要通过 conn_mgr
                if let Some((_handle, shared)) = self.conn_mgr.get_handle_and_shared(&e.conn_id).await {
                    shared.unregister_channel_tx(e.russh_ch_id).await;
                }

                // 取消数据接收任务
                if let Some(task) = e.data_task.lock().await.take() {
                    task.abort();
                }

                debug!("channel.close: ch={}", ch_id);
                Ok(json!({"ok": true}))
            }
            None => Err("channel_not_found".to_string()),
        }
    }

    /// RPC: channel.window_change
    pub async fn rpc_window_change(&self, params: Value) -> Result<Value, String> {
        let ch_id = proto::get_str(&params, "id")
            .ok_or("missing id")?
            .to_string();
        let cols = proto::get_num(&params, "cols").unwrap_or(80.0) as u32;
        let rows = proto::get_num(&params, "rows").unwrap_or(24.0) as u32;

        let channel_arc = {
            let channels = self.channels.read().await;
            channels
                .get(&ch_id)
                .map(|e| Arc::clone(&e.channel))
                .ok_or("channel_not_found")?
        };

        let ch = channel_arc.lock().await;
        ch.window_change(cols as u32, rows as u32, 0, 0)
            .await
            .map_err(|e| format!("window_change_failed: {}", e))?;

        debug!("channel.window_change: ch={} cols={} rows={}", ch_id, cols, rows);
        Ok(json!({"ok": true}))
    }

    /// 数据接收循环：从 handler 转发的 ChannelData 推送到 coalesce / IPC
    async fn data_receive_loop(
        mut data_rx: mpsc::UnboundedReceiver<ChannelData>,
        coalesce: Arc<Coalescer>,
        ipc_ch_id: String,
        conn_id: String,
        shared: Arc<ConnShared>,
        russh_ch_id: russh::ChannelId,
    ) {
        while let Some(data) = data_rx.recv().await {
            match data {
                ChannelData::Stdout { data } => {
                    // 推送到 coalesce（批量合并推送）
                    coalesce.enqueue(&ipc_ch_id, data).await;
                }
                ChannelData::Extended { data, ext } => {
                    // 扩展数据（stderr）——直接推送，不走 coalesce
                    let b64 = codec::encode_b64(&data);
                    shared
                        .gateway
                        .push_event(
                            "channel.extended_data",
                            json!({
                                "id": ipc_ch_id,
                                "data": b64,
                                "ext": ext
                            }),
                        )
                        .await;
                }
                ChannelData::Eof { reason } => {
                    // 推送 channel.eof
                    shared
                        .gateway
                        .push_event(
                            "channel.eof",
                            json!({
                                "id": ipc_ch_id,
                                "reason": reason
                            }),
                        )
                        .await;
                    // 收到 EOF 后，先 flush coalesce 中该通道的剩余数据
                    coalesce.flush_channel(&ipc_ch_id).await;
                    break;
                }
            }
        }

        // 注销数据接收器
        shared.unregister_channel_tx(russh_ch_id).await;
        debug!("conn {} channel {} data receive loop ended", conn_id, ipc_ch_id);
    }
}
