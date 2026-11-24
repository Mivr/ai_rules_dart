Pod::Spec.new do |s|
  s.name             = 'pod_bigint_plugin'
  s.version          = '0.0.1'
  s.summary          = 'CocoaPods fixture plugin for BigInt.'
  s.homepage         = 'https://example.com'
  s.authors          = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'BigInt'
  s.platform         = :ios, '12.0'
end
