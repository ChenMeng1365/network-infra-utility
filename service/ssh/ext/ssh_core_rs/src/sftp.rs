//! SFTP 管理器 — 管理所有 SFTP 会话的打开、列目录、上传、下载、创建目录、删除、stat。
//! 对应 Erlang 端的 ssh_sftp_session.erl。
//!
//! 核心设计：
//!   - 每个 SFTP 会话在 SSH 连接上打开一个 subsystem("sftp") 通道
//!   - 通道通过 into_stream() 转为 AsyncRead+AsyncWrite 流
//!   - 使用 russh-sftp crate 的 SftpSession 高层 API
//!   - 会话状态由 SftpManager 管理（HashMap<sftp_id, SftpEntry>）
//!   - SftpEntry 内部持有 Arc<SftpSession>，避免长时间持有 RwLock 读锁
//!   - 连接断开时自动清理该连接下的所有 SFTP 会话

use std::collections::HashMap;
use std::sync::Arc;

use russh_sftp::client::SftpSession;
use serde_json::{json, Value};
use tokio::sync::RwLock;
use tracing::{debug, info, warn};

use crate::codec;
use crate::conn::ConnManager;
use crate::proto;

/// SFTP 管理器
pub struct SftpManager {
    /// sftp_id → 会话状态
    sessions: RwLock<HashMap<String, SftpEntry>>,
    /// 连接管理器引用
    conn_mgr: Arc<ConnManager>,
}

/// 单个 SFTP 会话的状态
struct SftpEntry {
    conn_id: String,
    /// 使用 Arc 以便在释放 RwLock 读锁后仍可安全调用异步操作
    session: Arc<SftpSession>,
}

impl SftpManager {
    pub fn new(conn_mgr: Arc<ConnManager>) -> Arc<Self> {
        Arc::new(Self {
            sessions: RwLock::new(HashMap::new()),
            conn_mgr,
        })
    }

    /// 获取 SFTP session 的 Arc clone，释放 RwLock 读锁后仍可安全使用
    async fn get_session(&self, sftp_id: &str) -> Result<Arc<SftpSession>, String> {
        let sessions = self.sessions.read().await;
        let entry = sessions.get(sftp_id).ok_or("sftp_not_found")?;
        Ok(Arc::clone(&entry.session))
    }

    /// RPC: sftp.open — 在指定连接上打开 SFTP 会话
    pub async fn rpc_open(&self, params: Value) -> Result<Value, String> {
        let conn_id = proto::get_str(&params, "conn_id")
            .ok_or("missing conn_id")?
            .to_string();

        // 获取连接的 handle
        let handle = self
            .conn_mgr
            .get_handle(&conn_id)
            .await
            .ok_or("conn_not_found")?;

        // 打开 session 通道
        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("channel_open_failed: {}", e))?;

        // 请求 sftp subsystem
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| format!("subsystem_failed: {}", e))?;

        // 将通道转为 AsyncRead+AsyncWrite 流
        let stream = channel.into_stream();

        // 创建 SftpSession
        let sftp_session = SftpSession::new(stream)
            .await
            .map_err(|e| format!("sftp_init_failed: {}", e))?;

        let sftp_id = codec::gen_sftp_id(&conn_id);

        let entry = SftpEntry {
            conn_id: conn_id.clone(),
            session: Arc::new(sftp_session),
        };
        self.sessions
            .write()
            .await
            .insert(sftp_id.clone(), entry);

        info!("sftp.open: conn={} sftp_id={}", conn_id, sftp_id);

        Ok(json!({
            "sftp_id": sftp_id
        }))
    }

    /// RPC: sftp.list_dir — 列出远程目录内容
    pub async fn rpc_list_dir(&self, params: Value) -> Result<Value, String> {
        let sftp_id = proto::get_str(&params, "sftp_id")
            .ok_or("missing sftp_id")?
            .to_string();
        let path = proto::get_str(&params, "path")
            .ok_or("missing path")?;

        let sftp = self.get_session(&sftp_id).await?;
        let read_dir = sftp
            .read_dir(path.to_string())
            .await
            .map_err(|e| format!("list_dir_failed: {}", e))?;

        let mut entries = vec![];
        for entry in read_dir {
            // DirEntry::file_name() 返回 String
            let name = entry.file_name();
            // DirEntry::file_type() 返回 FileType 枚举（Dir/File/Symlink/Other）
            let ftype = entry.file_type();
            // DirEntry::metadata() 返回 FileAttributes
            let metadata = entry.metadata();

            let item = json!({
                "name": name,
                "size": metadata.len(),           // FileAttributes::len() → u64
                "is_dir": ftype.is_dir(),
                "is_file": ftype.is_file(),
                "is_symlink": ftype.is_symlink(),
                "modified": metadata.mtime.unwrap_or(0),
            });
            entries.push(item);
        }

        debug!("sftp.list_dir: sftp={} path={} entries={}", sftp_id, path, entries.len());
        Ok(json!({
            "entries": Value::Array(entries)
        }))
    }

    /// RPC: sftp.download — 从远程下载文件到本地
    pub async fn rpc_download(&self, params: Value) -> Result<Value, String> {
        let sftp_id = proto::get_str(&params, "sftp_id")
            .ok_or("missing sftp_id")?
            .to_string();
        let remote = proto::get_str(&params, "remote")
            .ok_or("missing remote")?;
        let local = proto::get_str(&params, "local")
            .ok_or("missing local")?;

        let sftp = self.get_session(&sftp_id).await?;
        let data = sftp
            .read(remote.to_string())
            .await
            .map_err(|e| format!("read_failed: {}", e))?;

        let transferred = data.len() as u64;

        // 写入本地文件
        tokio::fs::write(local, &data)
            .await
            .map_err(|e| format!("local_write_failed: {}", e))?;

        info!("sftp.download: sftp={} remote={} local={} bytes={}",
              sftp_id, remote, local, transferred);

        Ok(json!({
            "transferred": transferred,
            "total": transferred
        }))
    }

    /// RPC: sftp.upload — 从本地上传文件到远程
    pub async fn rpc_upload(&self, params: Value) -> Result<Value, String> {
        let sftp_id = proto::get_str(&params, "sftp_id")
            .ok_or("missing sftp_id")?
            .to_string();
        let local = proto::get_str(&params, "local")
            .ok_or("missing local")?;
        let remote = proto::get_str(&params, "remote")
            .ok_or("missing remote")?;

        // 读取本地文件
        let data = tokio::fs::read(local)
            .await
            .map_err(|e| format!("local_read_failed: {}", e))?;

        let transferred = data.len() as u64;

        let sftp = self.get_session(&sftp_id).await?;
        sftp.write(remote.to_string(), &data)
            .await
            .map_err(|e| format!("write_failed: {}", e))?;

        info!("sftp.upload: sftp={} local={} remote={} bytes={}",
              sftp_id, local, remote, transferred);

        Ok(json!({
            "transferred": transferred,
            "total": transferred
        }))
    }

    /// RPC: sftp.mkdir — 创建远程目录
    pub async fn rpc_mkdir(&self, params: Value) -> Result<Value, String> {
        let sftp_id = proto::get_str(&params, "sftp_id")
            .ok_or("missing sftp_id")?
            .to_string();
        let path = proto::get_str(&params, "path")
            .ok_or("missing path")?;

        let sftp = self.get_session(&sftp_id).await?;
        sftp.create_dir(path.to_string())
            .await
            .map_err(|e| format!("mkdir_failed: {}", e))?;

        debug!("sftp.mkdir: sftp={} path={}", sftp_id, path);
        Ok(json!({"ok": true}))
    }

    /// RPC: sftp.remove — 删除远程文件或目录
    pub async fn rpc_remove(&self, params: Value) -> Result<Value, String> {
        let sftp_id = proto::get_str(&params, "sftp_id")
            .ok_or("missing sftp_id")?
            .to_string();
        let path = proto::get_str(&params, "path")
            .ok_or("missing path")?;

        let sftp = self.get_session(&sftp_id).await?;

        // 先尝试当文件删除，失败再当目录删除
        let result = sftp.remove_file(path.to_string()).await;
        if result.is_err() {
            sftp.remove_dir(path.to_string())
                .await
                .map_err(|e| format!("remove_failed: {}", e))?;
        }

        debug!("sftp.remove: sftp={} path={}", sftp_id, path);
        Ok(json!({"ok": true}))
    }

    /// RPC: sftp.stat — 获取远程文件/目录的元数据
    pub async fn rpc_stat(&self, params: Value) -> Result<Value, String> {
        let sftp_id = proto::get_str(&params, "sftp_id")
            .ok_or("missing sftp_id")?
            .to_string();
        let path = proto::get_str(&params, "path")
            .ok_or("missing path")?;

        let sftp = self.get_session(&sftp_id).await?;
        let metadata = sftp
            .metadata(path.to_string())
            .await
            .map_err(|e| format!("stat_failed: {}", e))?;

        // FileAttributes: 公开字段结构体 + 便捷方法
        //   len()      → u64（从 size 字段展开）
        //   is_dir()   → bool（检查 permissions 中的 FileMode::DIR）
        //   is_regular() → bool（FileMode::REG，注意不是 is_file()）
        //   is_symlink() → bool（FileMode::LNK）
        //   mtime      → Option<u32>（Unix 时间戳秒）
        //   permissions → Option<u32>（原始 POSIX 权限位）
        Ok(json!({
            "size": metadata.len(),
            "is_dir": metadata.is_dir(),
            "is_file": metadata.is_regular(),
            "is_symlink": metadata.is_symlink(),
            "modified": metadata.mtime.unwrap_or(0),
            "permissions": format!("{:o}", metadata.permissions.unwrap_or(0)),
        }))
    }

    /// 关闭并移除指定连接的所有 SFTP 会话（连接断开时调用）
    pub async fn cleanup_conn(&self, conn_id: &str) {
        let mut sessions = self.sessions.write().await;
        let to_remove: Vec<String> = sessions
            .iter()
            .filter(|(_, e)| e.conn_id == conn_id)
            .map(|(k, _)| k.clone())
            .collect();

        for id in &to_remove {
            if let Some(entry) = sessions.remove(id) {
                let _ = entry.session.close().await;
                warn!("sftp session {} cleaned up (conn {} disconnected)", id, conn_id);
            }
        }
    }
}
