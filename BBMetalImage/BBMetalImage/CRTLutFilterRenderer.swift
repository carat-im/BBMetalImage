//
// Created by kevin-ee on 2021/12/10.
//

import CoreMedia
import CoreVideo
import Metal
import MetalKit

public class CRTLutFilterRenderer: NSObject, CRTFilterRenderer {
  @objc public static let FILTER_DIR_SUPPORT = 0
  @objc public static let FILTER_DIR_CACHE = 1

  var name: String = "CRTLutFilterRenderer"

  @objc public var isPrepared = false

  private(set) var inputFormatDescription: CMFormatDescription?

  private(set) var outputFormatDescription: CMFormatDescription?

  private var outputPixelBufferPool: CVPixelBufferPool?

  private let metalDevice = MTLCreateSystemDefaultDevice()!

  private var computePipelineState: MTLComputePipelineState?

  private var textureCache: CVMetalTextureCache!

  private lazy var commandQueue: MTLCommandQueue? = {
    self.metalDevice.makeCommandQueue()
  }()

  private var lutTexture: MTLTexture?
  private var intensity: Float = 0
  private var grain: Float = 0
  private var vignette: Float = 0

  public required override init() {
    do {
      let library = try metalDevice.makeDefaultLibrary(bundle: Bundle(for: CRTLutFilterRenderer.self))
      let kernelFunction = library.makeFunction(name: "crtLutFilter")
      computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
    } catch {
      print("Could not create pipeline state: \(error)")
    }
  }

  @objc
  public func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
    reset()

    (outputPixelBufferPool, _, outputFormatDescription) = allocateOutputBufferPool(with: formatDescription,
      outputRetainedBufferCountHint: outputRetainedBufferCountHint)
    if outputPixelBufferPool == nil {
      return
    }
    inputFormatDescription = formatDescription

    var metalTextureCache: CVMetalTextureCache?
    if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
      assertionFailure("Unable to allocate texture cache")
    } else {
      textureCache = metalTextureCache
    }

    isPrepared = true
  }

  @objc
  public func reset() {
    outputPixelBufferPool = nil
    outputFormatDescription = nil
    inputFormatDescription = nil
    textureCache = nil
    isPrepared = false
  }

  @objc
  public func setColorFilter(lutFilePath: NSString, intensity: NSNumber, grain: NSNumber, vignette: NSNumber, filterDir: Int) {
    configureLutTexture(lutFilePath, filterDir)

    self.intensity = intensity.isKind(of: NSNull.self) ? 0 : intensity.floatValue
    self.grain = grain.isKind(of: NSNull.self) ? 0 : grain.floatValue
    self.vignette = vignette.isKind(of: NSNull.self) ? 0 : vignette.floatValue
  }

  @objc
  public func setColorFilterIntensity(_ intensity: Float) {
    self.intensity = intensity
  }

  private func configureLutTexture(_ lutFilePath: NSString, _ filterDir: Int) {
    if (lutFilePath.isKind(of: NSNull.self)) {
      lutTexture = nil
      return
    }

    let dirUrl: URL?
    if (filterDir == CRTLutFilterRenderer.FILTER_DIR_CACHE) {
      dirUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    } else {
      dirUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    guard let lutUrl = dirUrl?.appendingPathComponent(String(lutFilePath)) else {
      lutTexture = nil
      return
    }

    let data = try? Data(contentsOf: lutUrl)
    lutTexture = data?.metalTexture
  }

  @objc
  public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    if !isPrepared {
      assertionFailure("Invalid state: Not prepared.")
      return nil
    }

    var newPixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &newPixelBuffer)
    guard let outputPixelBuffer = newPixelBuffer else {
      print("Allocation failure: Could not get pixel buffer from pool. (\(self.description))")
      return nil
    }
    guard let inputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: pixelBuffer, textureFormat: .bgra8Unorm),
          let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer, textureFormat: .bgra8Unorm) else {
      return nil
    }

    // Set up command queue, buffer, and encoder.
    guard let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
      print("Failed to create a Metal command queue.")
      CVMetalTextureCacheFlush(textureCache!, 0)
      return nil
    }

    commandEncoder.label = "Rosy Metal"
    commandEncoder.setComputePipelineState(computePipelineState!)
    commandEncoder.setTexture(inputTexture, index: 0)
    commandEncoder.setTexture(outputTexture, index: 1)
    commandEncoder.setTexture(lutTexture, index: 2)
    commandEncoder.setBytes(&intensity, length: MemoryLayout<Float>.size, index: 0)
    commandEncoder.setBytes(&grain, length: MemoryLayout<Float>.size, index: 1)
    commandEncoder.setBytes(&vignette, length: MemoryLayout<Float>.size, index: 2)

    // Set up the thread groups.
    let width = computePipelineState!.threadExecutionWidth
    let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
      height: (inputTexture.height + height - 1) / height,
      depth: 1)
    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    commandEncoder.endEncoding()
    commandBuffer.commit()
    return outputPixelBuffer
  }

  func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer, textureFormat: MTLPixelFormat) -> MTLTexture? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    // Create a Metal texture from the image buffer.
    var cvTextureOut: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, textureFormat, width, height, 0, &cvTextureOut)

    guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
      CVMetalTextureCacheFlush(textureCache, 0)

      return nil
    }

    return texture
  }
}

private extension Data {
  var metalTexture: MTLTexture? {
    let loader = MTKTextureLoader(device: MTLCreateSystemDefaultDevice()!)
    if let texture = try? loader.newTexture(data: self, options: [MTKTextureLoader.Option.SRGB: false]) {
      return texture
    }
    // If image orientation is not up, texture loader may not load texture from image data.
    // Create a UIImage from image data to get metal texture
    return UIImage(data: self)?.metalTexture
  }
}

private extension UIImage {
  var metalTexture: MTLTexture? {
    // To ensure image orientation is correct, redraw image if image orientation is not up
    // https://stackoverflow.com/questions/42098390/swift-png-image-being-saved-with-incorrect-orientation
    if let cgimage = flattened?.cgImage {
      return cgimage.metalTexture
    }
    return nil
  }

  private var flattened: UIImage? {
    if imageOrientation == .up {
      return self
    }
    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    draw(in: CGRect(origin: .zero, size: size))
    let result = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return result
  }
}

private extension CGImage {
  var metalTexture: MTLTexture? {
    let device = MTLCreateSystemDefaultDevice()!
    let loader = MTKTextureLoader(device: device)
    if let texture = try? loader.newTexture(cgImage: self, options: [MTKTextureLoader.Option.SRGB: false]) {
      return texture
    }
    // Texture loader can not load image data to create texture
    // Draw image and create texture
    let descriptor = MTLTextureDescriptor()
    descriptor.pixelFormat = .rgba8Unorm
    descriptor.width = width
    descriptor.height = height
    descriptor.usage = .shaderRead
    let bytesPerRow: Int = width * 4
    let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
    if let currentTexture = device.makeTexture(descriptor: descriptor),
       let context = CGContext(data: nil,
         width: width,
         height: height,
         bitsPerComponent: 8,
         bytesPerRow: bytesPerRow,
         space: CGColorSpaceCreateDeviceRGB(),
         bitmapInfo: bitmapInfo) {

      context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))

      if let data = context.data {
        currentTexture.replace(region: MTLRegionMake3D(0, 0, 0, width, height, 1),
          mipmapLevel: 0,
          withBytes: data,
          bytesPerRow: bytesPerRow)

        return currentTexture
      }
    }
    return nil
  }
}
