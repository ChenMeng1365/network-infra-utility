# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "schema"

module NetworkInfraUtility
  module SSH
    module Config
      # 会话/分组/片段的统一持久化。
      # 原子写：先写 .tmp 再 rename，防止崩溃导致配置损坏。
      class Store
        attr_reader :path, :doc

        def initialize(path)
          @path = path
          @doc = load
        end

        def sessions
          @doc[:sessions] || []
        end

        def groups
          @doc[:groups] || []
        end

        def find_session(id)
          sessions.find { |s| s[:id] == id }
        end

        def find_group(id)
          groups.find { |g| g[:id] == id }
        end

        def add_session(session)
          @doc[:sessions] ||= []
          @doc[:sessions] << session
          save
        end

        def update_session(id, updates)
          session = find_session(id)
          return unless session

          session.merge!(updates)
          save
        end

        def remove_session(id)
          @doc[:sessions]&.delete_if { |s| s[:id] == id }
          save
        end

        def add_group(group)
          @doc[:groups] ||= []
          @doc[:groups] << group
          save
        end

        def remove_group(id)
          @doc[:groups]&.delete_if { |g| g[:id] == id }
          save
        end

        def save
          tmp = "#{@path}.tmp"
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(tmp, YAML.dump(@doc))
          File.rename(tmp, @path)
        end

        def reload
          @doc = load
        end

        private

        def load
          if File.exist?(@path)
            raw = YAML.safe_load(File.read(@path), symbolize_names: true, permitted_classes: [Symbol]) || {}
            Schema.migrate(raw)
          else
            { version: Schema::SCHEMA_VERSION, groups: [], sessions: [] }
          end
        end
      end
    end
  end
end
