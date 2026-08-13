//! SSH Core RS — 主入口
//! 对应 Erlang 端的 ssh_core_app.erl + ssh_infra_sup.erl + ssh_ipc_gateway.erl:start_link/1。
//!
//! 启动流程：
//!   1. 生成 auth_token
//!   2. 删除旧的端点文件
//!   3. 创建 Gateway（TCP 监听 127.0.0.1:0，分配端口）
//!   4. 写入端点文件（tcp://127.0.0.1:port\n auth_token）
//!   5. 创建 ConnManager、Coalescer、ChannelManager、KeepaliveMgr
//!   6. 注册所有 RPC 路由
//!   7. 启动 coalesce tick 循环和 keepalive 循环
//!   8. 进入 gateway accept 循环（阻塞）

mod codec;
mod coalesce;
mod channel;
mod conn;
mod gateway;
mod handler;
mod keepalive;
mod portfwd;
mod proto;
mod sftp;

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{json, Value};
use tracing::{error, info};

use channel::ChannelManager;
use conn::ConnManager;
use gateway::Gateway;
use keepalive::KeepaliveMgr;
use coalesce::Coalescer;
use portfwd::PortFwdManager;
use sftp::SftpManager;
use std::time::Instant;

/// 端点文件路径：与 Erlang 端完全一致
/// Windows: %TEMP%\ssh_core_<USERNAME>.endpoint
/// Unix:    /tmp/ssh_core_<uid>.endpoint
fn endpoint_file_path() -> PathBuf {
    let tmp = std::env::temp_dir();
    let uid = if cfg!(windows) {
        std::env::var("USERNAME").unwrap_or_else(|_| "default".to_string())
    } else {
        std::env::var("UID").unwrap_or_else(|_| {
            // 尝试通过 id -u 获取 uid
            std::process::Command::new("id")
                .arg("-u")
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|s| s.trim().to_string())
                .unwrap_or_else(|| "0".to_string())
        })
    };
    tmp.join(format!("ssh_core_{}.endpoint", uid))
}

#[tokio::main]
async fn main() {
    // 初始化日志
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    info!("ssh_core_rs starting up...");

    // 0. 记录启动时间（用于 engine.stats 的 uptime_ms）
    let start_time = Instant::now();

    // 1. 生成 auth_token
    let auth_token = codec::gen_auth_token();

    // 2. 删除旧端点文件
    let endpoint_file = endpoint_file_path();
    if endpoint_file.exists() {
        let _ = std::fs::remove_file(&endpoint_file);
    }
    info!("endpoint file: {}", endpoint_file.display());

    // 3. 创建 Gateway
    let gateway = Gateway::new(auth_token);

    // 4. 创建各管理器
    let conn_mgr = ConnManager::new(Arc::clone(&gateway));
    let coalesce = Coalescer::new(Arc::clone(&gateway));
    let channel_mgr = ChannelManager::new(Arc::clone(&conn_mgr), Arc::clone(&coalesce));
    let keepalive_mgr = KeepaliveMgr::new(Arc::clone(&conn_mgr), Arc::clone(&gateway));
    let sftp_mgr = SftpManager::new(Arc::clone(&conn_mgr));
    let portfwd_mgr = PortFwdManager::new(Arc::clone(&conn_mgr));

    // 5. 注册所有 RPC 路由
    register_routes(
        &gateway,
        &conn_mgr,
        &channel_mgr,
        &keepalive_mgr,
        &sftp_mgr,
        &portfwd_mgr,
        start_time,
    )
    .await;

    // 6. 启动 coalesce tick 循环
    coalesce.start();

    // 7. 启动 keepalive 循环
    keepalive_mgr.start();

    // 8. 启动 Gateway（写入端点文件 + accept 循环）
    info!("starting IPC gateway...");
    if let Err(e) = gateway.start(endpoint_file).await {
        error!("gateway failed: {}", e);
        std::process::exit(1);
    }
}

/// 注册所有 JSON-RPC 路由
async fn register_routes(
    gateway: &Arc<Gateway>,
    conn_mgr: &Arc<ConnManager>,
    channel_mgr: &Arc<ChannelManager>,
    keepalive_mgr: &Arc<KeepaliveMgr>,
    sftp_mgr: &Arc<SftpManager>,
    portfwd_mgr: &Arc<PortFwdManager>,
    start_time: Instant,
) {
    // --- 连接管理 ---
    let cm = Arc::clone(conn_mgr);
    gateway
        .register_route("conn.connect", move |params| {
            let cm = Arc::clone(&cm);
            async move { cm.rpc_connect(params).await }
        })
        .await;

    let cm = Arc::clone(conn_mgr);
    gateway
        .register_route("conn.disconnect", move |params| {
            let cm = Arc::clone(&cm);
            async move { cm.rpc_disconnect(params).await }
        })
        .await;

    let cm = Arc::clone(conn_mgr);
    gateway
        .register_route("conn.list", move |params| {
            let cm = Arc::clone(&cm);
            async move { cm.rpc_list(params).await }
        })
        .await;

    let cm = Arc::clone(conn_mgr);
    gateway
        .register_route("conn.reconnect", move |params| {
            let cm = Arc::clone(&cm);
            async move { cm.rpc_reconnect(params).await }
        })
        .await;

    // --- 通道管理 ---
    let chm = Arc::clone(channel_mgr);
    gateway
        .register_route("channel.open", move |params| {
            let chm = Arc::clone(&chm);
            async move { chm.rpc_open(params).await }
        })
        .await;

    let chm = Arc::clone(channel_mgr);
    gateway
        .register_route("channel.send", move |params| {
            let chm = Arc::clone(&chm);
            async move { chm.rpc_send(params).await }
        })
        .await;

    let chm = Arc::clone(channel_mgr);
    gateway
        .register_route("channel.close", move |params| {
            let chm = Arc::clone(&chm);
            async move { chm.rpc_close(params).await }
        })
        .await;

    let chm = Arc::clone(channel_mgr);
    gateway
        .register_route("channel.window_change", move |params| {
            let chm = Arc::clone(&chm);
            async move { chm.rpc_window_change(params).await }
        })
        .await;

    // --- 保活管理 ---
    let km = Arc::clone(keepalive_mgr);
    gateway
        .register_route("keepalive.set_interval", move |params| {
            let km = Arc::clone(&km);
            async move { km.rpc_set_interval(params).await }
        })
        .await;

    let km = Arc::clone(keepalive_mgr);
    gateway
        .register_route("keepalive.get_interval", move |params| {
            let km = Arc::clone(&km);
            async move { km.rpc_get_interval(params).await }
        })
        .await;

    let km = Arc::clone(keepalive_mgr);
    gateway
        .register_route("keepalive.get_status", move |params| {
            let km = Arc::clone(&km);
            async move { km.rpc_get_status(params).await }
        })
        .await;

    // --- 引擎管理 ---
    gateway
        .register_route("engine.ping", move |_params| {
            async move { Ok(json!({"ok": true, "timestamp": codec::unix_ms()})) }
        })
        .await;

    let cm2 = Arc::clone(conn_mgr);
    gateway
        .register_route("engine.stats", move |_params| {
            let cm2 = Arc::clone(&cm2);
            let st = start_time;
            async move {
                let conn_count = cm2.all_conn_ids().await.len();
                let uptime_ms = st.elapsed().as_millis() as u64;
                Ok(json!({
                    "connections": conn_count,
                    "uptime_ms": uptime_ms
                }))
            }
        })
        .await;

    gateway
        .register_route("engine.shutdown", move |_params| {
            async move {
                info!("engine.shutdown received, exiting...");
                tokio::spawn(async {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    std::process::exit(0);
                });
                Ok(json!({"ok": true}))
            }
        })
        .await;

    // --- bye ---
    gateway
        .register_route("bye", move |_params| {
            async move { Ok(json!({"ok": true})) }
        })
        .await;

    // --- SFTP ---
    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.open", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_open(params).await }
        })
        .await;

    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.list_dir", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_list_dir(params).await }
        })
        .await;

    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.download", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_download(params).await }
        })
        .await;

    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.upload", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_upload(params).await }
        })
        .await;

    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.mkdir", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_mkdir(params).await }
        })
        .await;

    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.remove", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_remove(params).await }
        })
        .await;

    let sm = Arc::clone(sftp_mgr);
    gateway
        .register_route("sftp.stat", move |params| {
            let sm = Arc::clone(&sm);
            async move { sm.rpc_stat(params).await }
        })
        .await;

    // --- 端口转发 ---
    let pm = Arc::clone(portfwd_mgr);
    gateway
        .register_route("portfwd.add", move |params| {
            let pm = Arc::clone(&pm);
            async move { pm.rpc_add(params).await }
        })
        .await;

    let pm = Arc::clone(portfwd_mgr);
    gateway
        .register_route("portfwd.remove", move |params| {
            let pm = Arc::clone(&pm);
            async move { pm.rpc_remove(params).await }
        })
        .await;

    let pm = Arc::clone(portfwd_mgr);
    gateway
        .register_route("portfwd.list", move |params| {
            let pm = Arc::clone(&pm);
            async move { pm.rpc_list(params).await }
        })
        .await;

    info!("all RPC routes registered");
}
