# frozen_string_literal: true

require 'spec_helper'
require 'puppet/type/libvirt_network'
require 'puppet/provider/libvirt_network/virsh'

RSpec.describe Puppet::Type.type(:libvirt_network).provider(:virsh) do
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
