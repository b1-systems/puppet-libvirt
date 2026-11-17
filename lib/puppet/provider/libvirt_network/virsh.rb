# frozen_string_literal: true

#
# This file contains a provider for the resource type `libvirt_network`,
#
require 'tempfile'
require 'nokogiri/diff'
require_relative '../../../puppet_x/libvirt/rexml_sorted_attributes.rb'
require_relative '../../../puppet_x/libvirt/sort_elements.rb'

Puppet::Type.type(:libvirt_network).provide(:virsh) do
  desc "@summary provider for the resource type `libvirt_network`,
        which manages a network on libvirt
        using the virsh command."

  commands virsh: 'virsh'

  def virsh_define(content)
    xml = REXML::Document.new(content)
    if @property_hash[:uuid]
      xml.root.add_element('uuid').add_text(@property_hash[:uuid])
    end
    tmpfile = Tempfile.new(@resource[:name])
    tmpfile.write(xml.to_s)
    tmpfile.rewind
    virsh('--quiet', 'net-define', tmpfile.path)
  ensure
    tmpfile.close
    tmpfile.unlink
  end

  def virsh_update(new)
    new_xml = Nokogiri::XML(new.gsub(/\s*\n\s*/, ''))
    old_xml = Nokogiri::XML(self.content.gsub(/\s*\n\s*/, ''))
    diff = old_xml.diff(new_xml, added: true, removed: true)
    results = diff.select { |change, node| !live_update?(target_node(node)) }
    if results.empty?
      # puts "Online update possible"
      update_entries = {}
      diff.each do |_change, node|
        next unless node.type == Nokogiri::XML::Node::ATTRIBUTE_NODE

        target = target_node(node)
        section = net_update_section(target)
        entry = update_entry_node(target, section)
        next unless entry

        old_entry = old_xml.at_xpath(entry.path)
        new_entry = new_xml.at_xpath(entry.path)
        next unless old_entry && new_entry

        update_entries[[section, old_entry.path]] = [old_entry, new_entry]
      end
      diff.each do |change, node|
        target = target_node(node)
        entry = update_entry_node(target, net_update_section(target)) if node.type == Nokogiri::XML::Node::ATTRIBUTE_NODE
        old_entry = old_xml.at_xpath(entry.path) if entry
        next if old_entry && update_entries.key?([net_update_section(target), old_entry.path])

        online_update(node, change)
      end
      update_entries.each do |(section, _path), (old_entry, new_entry)|
        online_update_entry(old_entry, new_entry, section)
      end
    else
      # puts "We need to update the network offline"
      if @property_hash[:uuid]
        new_xml.root.add_child("<uuid>#{@property_hash[:uuid]}</uuid>")
      end
      self.destroy
      #virsh_define(new_xml.to_s)
      self.create
      restart_libvirt_service
    end
  end


  def net_update_section(node)
    node.path.gsub(/\[\d+\]/, '').gsub(/^\/network\//, '').gsub('/', '-')
  end

  def inplace_update?(node)
    %w[ip-dhcp-host portgroup dns-host dns-txt dns-srv].include?(net_update_section(node))
  end

  def live_update?(node)
    %w[ip-dhcp-host ip-dhcp-range forward-interface portgroup dns-host dns-txt dns-srv].include?(net_update_section(node))
  end

  def update_entry_node(node, section)
    entry_name, parent_name = {
      'ip-dhcp-host' => %w[host dhcp],
      'ip-dhcp-range' => %w[range dhcp],
      'portgroup' => %w[portgroup network],
      'dns-host' => %w[host dns],
      'dns-txt' => %w[txt dns],
      'dns-srv' => %w[srv dns],
    }[section]
    return unless entry_name

    while node && node.type == Nokogiri::XML::Node::ELEMENT_NODE
      return node if node.name == entry_name && node.parent&.name == parent_name

      node = node.parent
    end
    nil
  end

  def online_update_entry(old_entry, new_entry, section)
    if %w[ip-dhcp-range dns-host dns-txt dns-srv].include?(section)
      online_update_xml(old_entry, 'delete', section)
      online_update_xml(new_entry, 'add', section)
    else
      online_update_xml(new_entry, 'modify', section)
    end
  end

  def online_update_xml(node, change_type, section)
    target = target_node(node)
    base_command = ['net-update', @resource[:name], '--xml', target.to_xml, change_type, section]
    virsh(base_command + net_update_options(target, section))
  end

  def net_update_options(target, section)
    options = []
    if section.start_with?('ip-dhcp-')
      ip_node = target.ancestors.find { |ancestor| ancestor.name == 'ip' && ancestor.parent&.name == 'network' }
      options += ['--parent-index', ip_node.xpath('preceding-sibling::ip').length.to_s] if ip_node
    end
    options << '--config'
    options << '--live' if active == :true
    options
  end

  def online_update(node, change_type)
    target = target_node(node)
    section_name = net_update_section(target)
    if inplace_update?(target)
      if node.type == Nokogiri::XML::Node::ELEMENT_NODE
        # A whole entry (e.g. a <host>) was added or removed, so it must be
        # added/deleted. A `modify` would fail because the entry does not
        # exist yet (on add) or is being removed.
        online_update_xml(target, change_type == '-' ? 'delete' : 'add', section_name)
      elsif change_type != '-'
        # An attribute of an existing entry changed; `modify` with the full
        # (new) entry XML updates it in place. The `-` (old) side is skipped
        # because the `+`/`modify` already sets the new state.
        online_update_xml(target, 'modify', section_name)
      end
    else
      online_update_xml(target, change_type == '-' ? 'delete' : 'add', section_name)
    end
  end

  def target_node(node)
    case node.type
    when Nokogiri::XML::Node::ATTRIBUTE_NODE
      node.parent
    when Nokogiri::XML::Node::ELEMENT_NODE
      node
    else
      raise Puppet::Error, "Couldn't parse #{node.inspect}"
    end
  end

  def restart_libvirt_service()
    require 'open3'
    stdout, stderr, status = Open3.capture3('systemctl', 'restart', 'libvirtd.service')
    unless status.success?
      raise Puppet::Error, "Failed to restart libvirt service: #{stdout}, #{stderr}"
    end
  end

  def initialize(value = {})
    super(value)
    @property_flush = {}
  end

  def self.instances
    virsh('--quiet', '--readonly', 'net-list', '--table', '--all', '--persistent').split("\n").map do |line|
      raise Puppet::Error, "Cannot parse invalid network line: #{line}" unless line =~ %r{^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$}
      new(
        ensure: :present,
        name: Regexp.last_match(1),
        active: (Regexp.last_match(2) == 'active') ? :true : :false,
        autostart: (Regexp.last_match(3) == 'yes') ? :true : :false,
        uuid: virsh('--quiet', '--readonly', 'net-uuid', '--network', Regexp.last_match(1)),
      )
    end
  end

  def self.prefetch(resources)
    networks = instances
    resources.each_key do |name|
      if (provider = networks.find { |network| network.name == name })
        resources[name].provider = provider
      end
    end
  end

  def run_control
    should_active = @resource.should(:active)
    self.active = should_active unless active == should_active

    should_autostart = @resource.should(:autostart)
    self.autostart = should_autostart unless autostart == should_autostart
  end

  def create
    virsh_define(resource[:content])
    @property_hash[:ensure] = :present

    self.run_control
  end

  def destroy
    begin
      virsh('--quiet', 'net-destroy', @resource[:name])
    rescue
      # do nothing
    end
    virsh('--quiet', 'net-undefine', @resource[:name])
    @property_hash[:ensure] = :absent
    # Reset stale state; run_control in create re-applies active/autostart.
    @property_hash[:active] = :false
    @property_hash[:autostart] = :false
  end

  def content=(_content)
    @property_flush[:content] = resource[:content]
  end

  def content
    return '' unless @property_hash[:ensure] == :present
    begin
      xml = REXML::Document.new(virsh('--quiet', '--readonly', 'net-dumpxml', @resource[:name]))
    rescue REXML::ParseException => msg
      raise Puppet::ParseError, "libvirt_network: cannot parse xml: #{msg}"
    end
    # remove the uuid
    xml.root.elements.delete('//uuid')
    # remove an existing mac address, we do not define it...
    xml.root.elements.delete('//mac')
    # remove the connections
    xml.root.attributes.delete('connections')
    xml.root.elements.each('//forward/interface[@connections]') do |el|
      el.attributes.delete('connections')
    end
    formatter = REXML::Formatters::Pretty.new(2)
    formatter.compact = true
    output = ''.dup
    formatter.write(recursive_sort(xml.root), output)
    output
  end

  def active
    @property_hash[:active] || :false
  end

  def active=(active)
    if active == :true
      virsh('--quiet', 'net-start', '--network', @resource[:name])
      @property_hash[:active] = :true
    else
      virsh('--quiet', 'net-destroy', '--network', @resource[:name])
      @property_hash[:active] = :false
    end
  end

  def autostart
    @property_hash[:autostart] || :false
  end

  def autostart=(autostart)
    if autostart == :true
      virsh('--quiet', 'net-autostart', '--network', @resource[:name])
      @property_hash[:autostart] = :true
    else
      virsh('--quiet', 'net-autostart', '--network', @resource[:name], '--disable')
      @property_hash[:autostart] = :false
    end
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def flush
    return if @property_flush.empty?
    content = @property_flush[:content] || @resource[:content]
    virsh_update(content)
    @property_flush.clear

    self.run_control
  end
end
