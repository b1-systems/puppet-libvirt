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
