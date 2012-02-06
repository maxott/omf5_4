#!/usr/bin/env ruby

require 'rubygems'
require 'nokogiri'
require 'ruby-debug'

require 'net/http'
require 'yaml'
require 'ostruct'
require 'optparse'

require 'omf-oml/table'

require 'omf-web/tabbed_server'
require 'omf-web/tab/code/code_service'
require 'omf-web/tab/common/abstract_service'

require 'omf-web/widget/abstract_data_widget'

RESULT2_PATH = "/result2/query"
RESULT2_NAMESPACE = "http://schema.mytestbed.net/am/result/2/"
CURRENT_DIR = File.dirname(__FILE__)
DEFAULT_TABS = %w(code log graph)

# Create a custom tab type, this should not be neccessary if AbsctractService is generic enough
#
class BasicPage < OMF::Web::Tab::AbstractService
  def initialize(tab_id, opts)
    super
    debug "New Basic Service: #{opts.keys.inspect}"
    @widgets = (opts[:widgets] || []).map {|w| w[:widget_class].new(w) }
    @tab_id = opts[:tab_id]
  end

  def show(req, opts)
    opts[:card_id] = req.params['tid'].to_i rescue 0
    widget = @widgets[opts[:card_id]]

    opts[:widget] = widget
    opts[:card_title] = widget.name

    OMF::Web::Theme.require 'multi_card_page'

    page = OMF::Web::Theme::MultiCardPage.new(widget, @tab_id, @widgets, opts)

    [page.to_html, 'text/html']
  end
end

# Monkeypatch String
#
class String
  def auto_parse
    Integer(self) rescue Float(self) rescue self
  end
end

# Monkeypatch AbstractDataWidget
#
# This is due to some inconsistence of multi-card theme
#
module OMF::Web::Widget
  class AbstractDataWidget
    def [](key)
      opts[key]
    end
  end
end

# Define visualisation widgets
#
def widget_definition(name, data_source, viz_type, mapping)
  viz_opts = { :schema => data_source.schema }

  case viz_type
  when 'table'
  when 'line_chart'
    viz_opts[:mapping] = {
      :x_axis => { :property => mapping['x'] },
      :y_axis => { :property => mapping['y'] },
      :group_by => { :property => mapping['group_by'] },
      :stroke_width => 2
    }
  end

  {
    :name => name,
    :data_sources => { :default => data_source },
    :js_url => "graph/#{viz_type}.js",
    :js_class => "OML.#{viz_type}",
    :widget_class => OMF::Web::Widget::AbstractDataWidget,
    :dynamic => false,
    :viz_type => viz_type,
    :wopts => viz_opts
  }
end

# Add source code tab
# Add all ruby files in the current directory
#
def code_tab(pattern)
  Dir.glob(pattern).each do |filename|
    OMF::Web::Widget::Code.addCode(
      filename,
      :file => "#{CURRENT_DIR}/#{filename}"
    )
  end
end

# Add custom tab
#
def custom_tab(tab_id, widgets)
  OMF::Web::Tab.register_tab(
    :id => tab_id,
    :name => tab_id.to_s.capitalize,
    :class => BasicPage,
    :opts => { :tab_id => tab_id, :widgets => widgets }
  )
end

# Request result2 service and get data rows
#
def result2_data_rows(experiment_id, uri, table, columns)
  data_rows = []

  req = Net::HTTP::Post.new(uri.path)

  query = Nokogiri::XML::Builder.new do |xml|
    xml.request(:id => 'foo') {
      xml.result { xml.format 'xml' }
      xml.query {
        xml.repository(:name => experiment_id)
        xml.table(:tname => table)
        xml.project {
          columns.each do |m|
            xml.arg { xml.col(:name => m.to_s, :table => table) }
          end
        }
      }
    }
  end.to_xml

  req.body = query
  result = Net::HTTP.start(uri.host, uri.port) do |http|
    res = http.request(req)
    res.body
  end

  Nokogiri::XML(result).xpath('//omf:r', 'omf'=> RESULT2_NAMESPACE).each do |r|
    row = r.xpath('omf:c', 'omf'=> RESULT2_NAMESPACE).map {|v| v.content.auto_parse }
    data_rows << row
  end

  data_rows
end

# Parse options
#

@options = OpenStruct.new

OptionParser.new do |opts|
  opts.banner = "Usage: web.rb [options] [experiment_id]"
  opts.separator ""
  opts.separator "Options:"

  opts.on("-c", "--config PATH", "Configuration file") do |path|
    @options.config = path
  end
end.parse!

raise "Missing configuration file" if @options.config.nil?
raise "Missing experiment id" if ARGV[0].nil?

@experiment_id = ARGV[0]
@config = YAML::load_file(@options.config)

@tabs = @config['tabs']
@result2_uri = URI(@config['result2_server'] + RESULT2_PATH)
@results = []

custom_tabs = @tabs.keys - DEFAULT_TABS

data_tables = {}.tap do |hash|
  custom_tabs.each do |tab_key|
    @tabs[tab_key].each do |widget|
      hash[widget['data']] ||= []
      hash[widget['data']] << (widget['mapping'] && widget['mapping'].values)
      hash[widget['data']]
    end
  end
end

data_tables.values.each { |v| v = v.compact!}
data_tables.values.each { |v| v = v.flatten!}
data_tables.values.each { |v| v = v.uniq!}

@data_sources = {}.tap do |hash|
  data_tables.keys.each do |t|
    schema = data_tables[t].map {|v| [v.to_sym, :text]}
    data_source = OMF::OML::OmlTable.new(@experiment_id, schema)

    result2_data_rows(@experiment_id, @result2_uri, t, data_tables[t]).each do |row|
      data_source.add_row(row)
    end
    hash[t] ||= data_source
  end
end

custom_tabs.each do |tab_id|
  widgets = @tabs[tab_id].map do |w|
    widget_definition(w['name'], @data_sources[w['data']], w['type'], w['mapping'])
  end
  custom_tab(tab_id.to_sym, widgets)
end

code_tab(@tabs['code']['pattern'])

OMF::Web.start({
  :port => @config['port'] || 4040,
  :page_title => @config['title'] || @experiment_id,
  :use_tabs => @config['tabs'].keys.map{|v| v.to_sym},
  :theme => 'bright'
})
