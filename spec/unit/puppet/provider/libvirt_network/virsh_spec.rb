# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/libvirt_network'
require 'puppet/provider/libvirt_network/virsh'

RSpec.describe Puppet::Type.type(:libvirt_network).provider(:virsh) do
  let(:provider) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@resource, { name: 'test-network' })
      instance.instance_variable_set(:@property_hash, { active: :true })
    end
  end
  let(:commands) { [] }

  before do
    allow(provider).to receive(:virsh) do |*args|
      commands << (args.length == 1 && args.first.is_a?(Array) ? args.first : args)
    end
  end

  def update_network(provider, old_xml, new_xml)
    allow(provider).to receive(:content).and_return(old_xml)
    provider.virsh_update(new_xml)
  end

  it 'passes the zero-based IP block index and persists active updates' do
    xml = Nokogiri::XML('<network><ip/><ip><dhcp><host mac="aa" ip="192.0.2.2"/></dhcp></ip></network>')
    host = xml.at_xpath('/network/ip[2]/dhcp/host')

    provider.online_update(host, '+')

    expect(commands.first).to include('add', 'ip-dhcp-host', '--parent-index', '1', '--config', '--live')
  end

  it 'updates an indexed host when an attribute is removed' do
    old_xml = '<network><ip><dhcp><host mac="aa" name="old" ip="192.0.2.2"/></dhcp></ip></network>'
    new_xml = '<network><ip><dhcp><host mac="aa" ip="192.0.2.2"/></dhcp></ip></network>'

    update_network(provider, old_xml, new_xml)

    expect(commands.length).to eq(1)
    expect(commands.first).to include('modify', 'ip-dhcp-host', '<host mac="aa" ip="192.0.2.2"/>')
  end

  it 'replaces a changed DNS entry with one delete and one add' do
    old_xml = '<network><dns><host ip="192.0.2.1"><hostname>old</hostname></host></dns></network>'
    new_xml = '<network><dns><host ip="192.0.2.2"><hostname>old</hostname></host></dns></network>'

    update_network(provider, old_xml, new_xml)

    expect(commands.length).to eq(2)
    expect(commands.map { |command| command[4] }).to eq(%w[delete add])
    expect(commands.all? { |command| command[5] == 'dns-host' }).to be(true)
  end

  it 'deletes all DNS TXT records before adding replacements' do
    old_xml = '<network><dns><txt name="first"><txt value="one"/></txt><txt name="second"><txt value="two"/></txt></dns></network>'
    new_xml = '<network><dns><txt name="second"><txt value="one"/></txt><txt name="first"><txt value="two"/></txt></dns></network>'

    update_network(provider, old_xml, new_xml)

    expect(commands.length).to eq(4)
    expect(commands.map { |command| command[4] }).to eq(%w[delete delete add add])
    expect(commands.all? { |command| command[5] == 'dns-txt' }).to be(true)
  end

  it 'replaces a DHCP host when its MAC and IP both change' do
    old_xml = '<network><ip><dhcp><host mac="aa" ip="192.0.2.2"/></dhcp></ip></network>'
    new_xml = '<network><ip><dhcp><host mac="bb" ip="192.0.2.3"/></dhcp></ip></network>'

    update_network(provider, old_xml, new_xml)

    expect(commands.length).to eq(2)
    expect(commands.map { |command| command[4] }).to eq(%w[delete add])
    expect(commands.map { |command| command[3] }).to eq([
      '<host mac="aa" ip="192.0.2.2"/>',
      '<host mac="bb" ip="192.0.2.3"/>',
    ])
    expect(commands.all? { |command| command[5] == 'ip-dhcp-host' }).to be(true)
  end

  it 'deletes all DHCP hosts before adding replacements when MACs are exchanged' do
    old_xml = '<network><ip><dhcp><host mac="aa" ip="192.0.2.2"/><host mac="bb" ip="192.0.2.3"/></dhcp></ip></network>'
    new_xml = '<network><ip><dhcp><host mac="bb" ip="192.0.2.2"/><host mac="aa" ip="192.0.2.3"/></dhcp></ip></network>'

    update_network(provider, old_xml, new_xml)

    expect(commands.length).to eq(4)
    expect(commands.map { |command| command[4] }).to eq(%w[delete delete add add])
    expect(commands.map { |command| command[3] }).to eq([
      '<host mac="aa" ip="192.0.2.2"/>',
      '<host mac="bb" ip="192.0.2.3"/>',
      '<host mac="bb" ip="192.0.2.2"/>',
      '<host mac="aa" ip="192.0.2.3"/>',
    ])
    expect(commands.all? { |command| command[5] == 'ip-dhcp-host' }).to be(true)
  end

  it 'coalesces DHCP range attribute changes into one replacement' do
    old_xml = '<network><ip><dhcp><range start="192.0.2.10" end="192.0.2.20"/></dhcp></ip></network>'
    new_xml = '<network><ip><dhcp><range start="192.0.2.30" end="192.0.2.40"/></dhcp></ip></network>'

    update_network(provider, old_xml, new_xml)

    expect(commands.length).to eq(2)
    expect(commands.map { |command| command[4] }).to eq(%w[delete add])
    expect(commands.all? { |command| command[5] == 'ip-dhcp-range' }).to be(true)
  end

  it 'updates only the persistent definition when the network is inactive' do
    provider.instance_variable_get(:@property_hash)[:active] = :false
    xml = Nokogiri::XML('<network><ip><dhcp><host mac="aa" ip="192.0.2.2"/></dhcp></ip></network>')

    provider.online_update(xml.at_xpath('/network/ip/dhcp/host'), '+')

    expect(commands.first).to include('--config')
    expect(commands.first).not_to include('--live')
  end
end

RSpec.describe Puppet::Type.type(:libvirt_network).provider(:virsh), 'offline updates' do
  let(:old_content) { '<network><name>test</name><bridge name="old"/></network>' }
  let(:new_content) { '<network><name>test</name><bridge name="new"/></network>' }
  let(:resource) do
    Puppet::Type.type(:libvirt_network).new(
      name: 'test',
      content: new_content,
      active: desired_active,
      autostart: desired_autostart,
    )
  end
  let(:desired_active) { :true }
  let(:desired_autostart) { :true }
  let(:initial_active) { :true }
  let(:initial_autostart) { :true }
  let(:provider) do
    described_class.new(
      name: 'test',
      ensure: :present,
      active: initial_active,
      autostart: initial_autostart,
      uuid: '12345678-1234-1234-1234-123456789abc',
    ).tap { |instance| instance.resource = resource }
  end

  before do
    allow(provider).to receive(:virsh).with('--quiet', '--readonly', 'net-dumpxml', 'test').and_return(old_content)
    provider.content = new_content
  end

  def expect_definition
    expect(provider).to receive(:virsh).with('--quiet', 'net-define', kind_of(String)).ordered do |_, _, path|
      xml = REXML::Document.new(File.read(path))
      expect(xml.elements['network/bridge'].attributes['name']).to eq('new')
      expect(xml.elements['network/uuid'].text).to eq('12345678-1234-1234-1234-123456789abc')
    end
  end

  it 'restarts the recreated network and restores autostart' do
    expect(provider).to receive(:virsh).with('--quiet', 'net-destroy', 'test').ordered
    expect(provider).to receive(:virsh).with('--quiet', 'net-undefine', 'test').ordered
    expect_definition
    expect(provider).to receive(:virsh).with('--quiet', 'net-start', '--network', 'test').ordered
    expect(provider).to receive(:virsh).with('--quiet', 'net-autostart', '--network', 'test').ordered

    provider.flush
    expect(provider.active).to eq(:true)
    expect(provider.autostart).to eq(:true)
  end

  context 'when the network is inactive and should stay inactive' do
    let(:initial_active) { :false }
    let(:desired_active) { :false }

    it 'redefines without starting it and restores autostart' do
      expect(provider).to receive(:virsh).with('--quiet', 'net-undefine', 'test').ordered
      expect_definition
      expect(provider).to receive(:virsh).with('--quiet', 'net-autostart', '--network', 'test').ordered

      provider.flush
      expect(provider.active).to eq(:false)
    end
  end

  context 'when autostart is disabled' do
    let(:initial_autostart) { :false }
    let(:desired_autostart) { :false }

    it 'starts the network without enabling autostart' do
      expect(provider).to receive(:virsh).with('--quiet', 'net-destroy', 'test').ordered
      expect(provider).to receive(:virsh).with('--quiet', 'net-undefine', 'test').ordered
      expect_definition
      expect(provider).to receive(:virsh).with('--quiet', 'net-start', '--network', 'test').ordered

      provider.flush
      expect(provider.autostart).to eq(:false)
    end
  end

  it 'propagates a failure to stop the network without undefining it' do
    expect(provider).to receive(:virsh).with('--quiet', 'net-destroy', 'test')
      .and_raise(Puppet::ExecutionFailure, 'stop failed')
    expect(provider).not_to receive(:virsh).with('--quiet', 'net-undefine', 'test')

    expect { provider.flush }.to raise_error(Puppet::ExecutionFailure, 'stop failed')
  end
end
