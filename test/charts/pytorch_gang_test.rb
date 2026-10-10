# Run from any directory: ruby test/charts/pytorch_gang_test.rb
require 'minitest/autorun'
require 'open3'
require 'yaml'

class PytorchGangChartTest < Minitest::Test
  CHART = File.expand_path('../../arena-artifacts', __dir__)

  def render(*values)
    args = ['helm', 'template', 'arena', CHART, '--namespace', 'arena-system']
    values.each { |value| args.concat(['--set', value]) }
    out, err, result = Open3.capture3(*args)
    [out, err, result]
  end

  def resources(*values)
    out, err, result = render(*values)
    assert result.success?, err
    docs = YAML.load_stream(out).compact
    deployment = docs.find { |d| d['kind'] == 'Deployment' && d['metadata']['name'] == 'pytorch-operator' }
    role = docs.find { |d| d['kind'] == 'ClusterRole' && d['metadata']['name'] == 'pytorch-operator' }
    [deployment['spec']['template']['spec']['containers'][0], role['rules']]
  end

  def test_default_keeps_original_image_command_and_permissions
    container, rules = resources
    assert_match %r{/acs/pytorch-operator:2845db5-aliyun$}, container['image']
    refute container['command'].any? { |arg| arg.include?('gang') || arg.include?('podgroup-backend') }
    refute rules.any? { |rule| rule['resources'].include?('podgroups') }
  end

  def test_both_backends_and_least_privilege
    %w[legacy volcano].each do |backend|
      container, rules = resources('pytorch.gangScheduling.enabled=true',
        "pytorch.gangScheduling.podGroupBackend=#{backend}",
        'pytorch.imageOverride=example.test/team/operator:patched')
      assert_equal 'example.test/team/operator:patched', container['image']
      assert_includes container['command'], '--enable-gang-scheduling=true'
      assert_includes container['command'], "--podgroup-backend=#{backend}"
      assert_includes container['command'], '--gang-scheduler-name=volcano'
      rule = rules.find { |r| r['resources'].include?('podgroups') }
      assert_equal %w[scheduling.incubator.k8s.io scheduling.volcano.sh], rule['apiGroups']
      assert_equal %w[get create update delete], rule['verbs']
      assert_equal ['podgroups'], rule['resources']
    end
  end

  def test_keep_permissions_for_pinned_jobs_when_disabled
    container, rules = resources('pytorch.gangScheduling.podGroupRBAC=true',
      'pytorch.imageOverride=example.test/team/operator:patched')
    refute_includes container['command'], '--enable-gang-scheduling=true'
    assert rules.any? { |r| r['resources'].include?('podgroups') }
  end

  def test_invalid_or_unpatched_configuration_fails
    [[], ['pytorch.imageOverride=example.test/operator:patched', 'pytorch.gangScheduling.podGroupBackend=auto'],
     ['pytorch.imageOverride=example.test/operator:patched', 'pytorch.gangScheduling.schedulerName=']].each do |values|
      _, _, result = render('pytorch.gangScheduling.enabled=true', *values)
      refute result.success?
    end
  end
end
