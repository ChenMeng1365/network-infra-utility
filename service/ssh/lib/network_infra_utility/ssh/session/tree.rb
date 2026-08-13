# frozen_string_literal: true

require "securerandom"

module NetworkInfraUtility
  module SSH
    module Session
      # 会话分组的树形管理（FR-SESS-002）。
      # 支持 ≥ 5 层嵌套、拖拽移动、折叠/展开、分组级批量操作。
      class Tree
        attr_reader :root

        Node = Struct.new(:id, :name, :parent, :children, :collapsed, keyword_init: true)

        def initialize
          @root = Node.new(id: "root", name: "Root", parent: nil, children: [], collapsed: false)
          @nodes = { "root" => @root }
        end

        # 添加分组
        def add_group(name, parent_id: "root")
          id = "grp_#{SecureRandom.hex(4)}"
          parent = @nodes[parent_id]
          raise "Parent group not found: #{parent_id}" unless parent

          node = Node.new(id: id, name: name, parent: parent, children: [], collapsed: false)
          parent.children << node
          @nodes[id] = node
          id
        end

        # 删除分组（子分组递归删除）
        def remove_group(group_id)
          node = @nodes.delete(group_id)
          return unless node

          node.parent&.children&.delete(node)
          node.children.each { |c| remove_group(c.id) }
        end

        # 重命名分组
        def rename_group(group_id, new_name)
          @nodes[group_id]&.name = new_name
        end

        # 折叠/展开
        def toggle_collapse(group_id)
          node = @nodes[group_id]
          return unless node

          node.collapsed = !node.collapsed
        end

        # 移动分组到新父节点
        def move_group(group_id, new_parent_id)
          node = @nodes[group_id]
          new_parent = @nodes[new_parent_id]
          return unless node && new_parent

          node.parent&.children&.delete(node)
          node.parent = new_parent
          new_parent.children << node
        end

        # 查找分组
        def find_group(group_id)
          @nodes[group_id]
        end

        # 遍历所有分组（深度优先）
        def each_group(&block)
          traverse(@root, &block)
        end

        # 获取分组的完整路径名
        def group_path(group_id)
          parts = []
          node = @nodes[group_id]
          while node && node.id != "root"
            parts.unshift(node.name)
            node = node.parent
          end
          parts.join(" / ")
        end

        private

        def traverse(node, &block)
          block.call(node) unless node.id == "root"
          node.children.each { |c| traverse(c, &block) }
        end
      end
    end
  end
end
