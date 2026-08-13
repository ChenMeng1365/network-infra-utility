# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Session
      # 最近连接列表与历史记录（FR-SESS-005）。
      # 在内存中维护，可持久化到配置。
      class History
        MAX_ITEMS = 20

        attr_reader :items, :pinned

        def initialize
          @items = []       # [Session] 按使用时间倒序
          @pinned = {}      # conn_id => true
        end

        # 记录一次连接
        def record(session)
          @items.delete(session)
          @items.unshift(session)
          trim
        end

        # 置顶
        def pin(conn_id)
          @pinned[conn_id] = true
        end

        # 取消置顶
        def unpin(conn_id)
          @pinned.delete(conn_id)
        end

        # 获取最近列表（置顶在前）
        def recent
          pinned_sessions = @items.select { |s| @pinned[s.conn_id] }
          unpinned = @items.reject { |s| @pinned[s.conn_id] }
          pinned_sessions + unpinned
        end

        # 清除
        def clear
          @items.clear
          @pinned.clear
        end

        private

        def trim
          @items = @items.first(MAX_ITEMS)
        end
      end
    end
  end
end
