Pod::Spec.new do |s|

  s.name         = 'BBMetalImage'
  s.version      = '1.2.0'
  s.summary      = 'A Swift library for GPU-accelerated image/video processing based on Metal.'

  s.description  = <<-DESC
                   80+ built-in filters.
                   Filter chain supported.
                   Customized filter.
                   Camera capturing video and audio.
                   Depth camera supported.
                   Multiple camera supported.
                   Video source processing video file.
                   Image source providing image texture.
                   UI source recording view animation.
                   Metal view displaying Metal texture.
                   Video writer writting video.
                   High performance.
                   DESC

  s.homepage     = 'https://github.com/Silence-GitHub/BBMetalImage'

  s.license      = { :type => 'MIT', :file => 'LICENSE' }

  s.author       = { 'Kaibo Lu' => 'lukaibolkb@gmail.com' }

  s.platform     = :ios, '11.0'

  s.swift_version = '5.5'

  s.source       = { :git => 'https://github.com/Silence-GitHub/BBMetalImage.git', :tag => s.version }

  s.requires_arc = true

  s.source_files  = 'BBMetalImage/BBMetalImage/*.{h,m,swift,metal}'
  s.exclude_files = 'BBMetalImage/BBMetalImage/MultipleVideoSource.swift'

  s.private_header_files = 'BBMetalImage/BBMetalImage/BBMetalShaderTypes.h'

end
