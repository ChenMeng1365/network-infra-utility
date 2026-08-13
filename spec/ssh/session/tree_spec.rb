# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Session::Tree do
  let(:tree) { described_class.new }

  describe "#add_group" do
    it "在 root 下添加分组并返回 id" do
      id = tree.add_group("Prod")
      expect(id).to start_with("grp_")
      expect(tree.find_group(id).name).to eq("Prod")
    end

    it "指定父分组嵌套" do
      parent_id = tree.add_group("Prod")
      child_id = tree.add_group("WebServers", parent_id: parent_id)
      child = tree.find_group(child_id)
      expect(child.parent.id).to eq(parent_id)
    end

    it "父分组不存在时抛异常" do
      expect { tree.add_group("Test", parent_id: "nonexistent") }.to raise_error(
        RuntimeError, /Parent group not found/
      )
    end
  end

  describe "#remove_group" do
    it "递归删除子分组" do
      parent_id = tree.add_group("Prod")
      child_id = tree.add_group("Web", parent_id: parent_id)
      tree.remove_group(parent_id)
      expect(tree.find_group(parent_id)).to be nil
      expect(tree.find_group(child_id)).to be nil
    end
  end

  describe "#rename_group" do
    it "重命名分组" do
      id = tree.add_group("Old")
      tree.rename_group(id, "New")
      expect(tree.find_group(id).name).to eq("New")
    end
  end

  describe "#toggle_collapse" do
    it "切换折叠状态" do
      id = tree.add_group("Prod")
      expect(tree.find_group(id).collapsed).to be false
      tree.toggle_collapse(id)
      expect(tree.find_group(id).collapsed).to be true
      tree.toggle_collapse(id)
      expect(tree.find_group(id).collapsed).to be false
    end
  end

  describe "#move_group" do
    it "移动分组到新父节点" do
      g1 = tree.add_group("Group1")
      g2 = tree.add_group("Group2")
      tree.move_group(g1, g2)
      expect(tree.find_group(g1).parent.id).to eq(g2)
    end
  end

  describe "#each_group" do
    it "深度优先遍历所有分组" do
      tree.add_group("A")
      tree.add_group("B")
      names = []
      tree.each_group { |node| names << node.name }
      expect(names).to contain_exactly("A", "B")
    end
  end

  describe "#group_path" do
    it "返回分组的完整路径" do
      a_id = tree.add_group("A")
      b_id = tree.add_group("B", parent_id: a_id)
      expect(tree.group_path(b_id)).to eq("A / B")
    end

    it "root 节点返回空字符串" do
      expect(tree.group_path("root")).to eq("")
    end
  end
end
