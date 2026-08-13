# frozen_string_literal: true

require_relative "session"
require_relative "tree"
require_relative "history"

module NetworkInfraUtility
  module SSH
    module Session
      # 会话管理器：维护全部活跃会话的生命周期。
      # 对应需求 FR-SESS-001 ~ FR-SESS-006。
      class Manager
        include Enumerable

        attr_reader :tree, :history

        def initialize(client)
          @client = client
          @sessions = {}        # conn_id => Session
          @tree = Tree.new
          @history = History.new
          setup_conn_closed_handler
        end

        # 从已有连接 ID 创建会话对象
        def create(conn_id, spec, fingerprint = nil)
          session = Session.new(@client, conn_id, spec, fingerprint)
          @sessions[conn_id] = session
          @history.record(session)
          session
        end

        def get(conn_id)
          @sessions[conn_id]
        end

        def disconnect(conn_id)
          @sessions[conn_id]&.disconnect
          @sessions.delete(conn_id)
        end

        def disconnect_all
          @sessions.each_value(&:disconnect)
          @sessions.clear
        end

        def each(&block)
          @sessions.each_value(&block)
        end

        def count
          @sessions.size
        end

        # 搜索会话（FR-SESS-004）
        # @param query [String] 搜索关键词
        # @param fields [Array<Symbol>] 搜索字段，默认 :name, :host, :ip, :tags
        def search(query, fields = %i[name host ip tags])
          query_lower = query.downcase
          select do |s|
            fields.any? do |f|
              val = s.send(f)
              if val.is_a?(Array)
                val.any? { |v| v.to_s.downcase.include?(query_lower) }
              else
                val.to_s.downcase.include?(query_lower)
              end
            end
          end
        end

        # 广播输入到多个会话（FR-TERM-008）
        # @param conn_ids [Array<String>] 目标连接 ID
        # @param text [String] 要发送的文本
        def broadcast(conn_ids, text)
          conn_ids.each { |id| @sessions[id]&.terminal&.send(text) }
        end

        private

        # 监听 conn.closed 推送，清理会话
        def setup_conn_closed_handler
          @client.ipc.subscribe("conn.closed") do |params|
            conn_id = params[:conn_id]
            session = @sessions.delete(conn_id)
            session&.on_closed(params[:reason])
          end
        end
      end
    end
  end
end
