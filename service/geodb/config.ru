#coding:utf-8
# GeoDB Roda API — rackup 配置入口
#
# 启动方式:
#   rackup -o 0.0.0.0 -p 9292 service/geodb/config.ru
#   rackup -o 0.0.0.0 -p 9292 -E production service/geodb/config.ru
#
# 也可通过 gem 命令行服务启动 (推荐):
#   geo-api                         # 默认 ./geodb/ + 0.0.0.0:9292
#   geo-api -d /data/ipdb -p 8080   # 指定数据目录与端口
#
# 数据目录通过环境变量 GEODB_DATA_DIR 指定，默认 ./geodb/
require_relative 'api'

run GeoAPI.app
