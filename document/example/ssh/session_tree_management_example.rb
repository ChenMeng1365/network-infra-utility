# frozen_string_literal: true

# example/ssh/session_tree_management_example.rb
#
# 功能场景：会话分组树形管理
# 覆盖需求：FR-SESS-002
#
# 验证：
#   1. 多层嵌套分组（≥ 5 层）
#   2. 拖拽移动分组
#   3. 折叠/展开
#   4. 路径查询

require "network"

RSpec.describe "会话分组树形管理" do
  let(:tree) { NetworkInfraUtility::SSH::Session::Tree.new }

  it "支持 ≥ 5 层嵌套分组" do
    level1 = tree.add_group("Network")
    level2 = tree.add_group("Core", parent_id: level1)
    level3 = tree.add_group("Routers", parent_id: level2)
    level4 = tree.add_group("Edge", parent_id: level3)
    level5 = tree.add_group("Border", parent_id: level4)

    expect(tree.group_path(level5)).to eq("Network / Core / Routers / Edge / Border")
  end

  it "拖拽移动分组到不同父节点" do
    prod = tree.add_group("Production")
    dev = tree.add_group("Development")
    web = tree.add_group("WebServers", parent_id: prod)

    # 将 WebServers 从 Production 移到 Development
    tree.move_group(web, dev)

    web_node = tree.find_group(web)
    expect(web_node.parent.id).to eq(dev)
    expect(tree.group_path(web)).to eq("Development / WebServers")
  end

  it "折叠/展开切换" do
    grp = tree.add_group("TestGroup")
    node = tree.find_group(grp)
    expect(node.collapsed).to be false

    tree.toggle_collapse(grp)
    expect(tree.find_group(grp).collapsed).to be true

    tree.toggle_collapse(grp)
    expect(tree.find_group(grp).collapsed).to be false
  end

  it "删除父分组时递归删除子分组" do
    parent = tree.add_group("Parent")
    child = tree.add_group("Child", parent_id: parent)
    grandchild = tree.add_group("GrandChild", parent_id: child)

    tree.remove_group(parent)

    expect(tree.find_group(parent)).to be nil
    expect(tree.find_group(child)).to be nil
    expect(tree.find_group(grandchild)).to be nil
  end

  it "each_group 深度优先遍历全部分组" do
    a = tree.add_group("A")
    tree.add_group("A1", parent_id: a)
    tree.add_group("A2", parent_id: a)
    b = tree.add_group("B")

    names = []
    tree.each_group { |node| names << node.name }
    expect(names).to include("A", "A1", "A2", "B")
  end

  it "重命名分组" do
    grp = tree.add_group("OldName")
    tree.rename_group(grp, "NewName")
    expect(tree.find_group(grp).name).to eq("NewName")
  end
end
