# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Config
      # 配置校验与版本迁移。
      class SchemaError < StandardError; end

      module Schema
        SCHEMA_VERSION = 1

        # 会话字段定义
        SESSION_FIELDS = {
          id: String, name: String, group: String, host: String, port: Integer,
          user: String, tags: Array, auth: Hash, terminal: Hash,
          keepalive: Hash, proxy: Hash, jumps: Array, port_forwards: Array,
          macro: Hash, log: Hash, auto_reconnect: Hash,
          algorithms: Hash, connect_timeout_ms: Integer
        }.freeze

        # 分组字段定义
        GROUP_FIELDS = {
          id: String, name: String, parent: String, collapsed: [TrueClass, FalseClass]
        }.freeze

        # @param doc [Hash] 加载的 YAML 文档
        # @return [:ok] 校验通过
        # @raise [SchemaError] 校验失败
        def self.validate(doc)
          raise SchemaError, "version mismatch" unless doc[:version] == SCHEMA_VERSION

          (doc[:sessions] || []).each_with_index do |s, i|
            validate_session(s, i)
          end
          (doc[:groups] || []).each_with_index do |g, i|
            validate_group(g, i)
          end
          :ok
        end

        # 迁移旧版本到当前版本
        def self.migrate(doc)
          # V1.0 仅 v1，预留迁移接口
          doc
        end

        class << self
          private

          def validate_session(session, index)
            SESSION_FIELDS.each do |field, type|
              val = session[field]
              next if val.nil?

              unless valid_type?(val, type)
                raise SchemaError, "Session[#{index}] field '#{field}' type mismatch: expected #{type}, got #{val.class}"
              end
            end

            raise SchemaError, "Session[#{index}] missing required host" unless session[:host]
            raise SchemaError, "Session[#{index}] missing required user" unless session[:user]
          end

          def validate_group(group, index)
            GROUP_FIELDS.each do |field, type|
              val = group[field]
              next if val.nil?

              unless valid_type?(val, type)
                raise SchemaError, "Group[#{index}] field '#{field}' type mismatch"
              end
            end
          end

          def valid_type?(val, type)
            case type
            when Array
              # 数组类型：每个元素都是一个可接受类型（联合类型）
              type.any? { |t| valid_type?(val, t) }
            when Class
              val.is_a?(type)
            else
              val.is_a?(type)
            end
          end
        end
      end
    end
  end
end
