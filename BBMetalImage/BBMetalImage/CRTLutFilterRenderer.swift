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

  private var lutFilterComputePipeline: MTLComputePipelineState?

  private var textureCache: CoreVideo.CVMetalTextureCache!

  private lazy var commandQueue: MTLCommandQueue? = {
    self.metalDevice.makeCommandQueue()
  }()

  private var lutTexture: MTLTexture?
  private var intensity: Float = 0
  private var grain: Float = 0
  private var vignette: Float = 0

  // Flutter 단 기준의 viewport.
  // 이용할 때 outputTexture 사이즈와 함께 계산하여 실제 사이즈를 측정해야함.
  private var stickerBoardViewport: (width: Double, height: Double) = (0, 0)

  private var stickerViews: [CRTStickerView] = []

  private var stickerRenderPipeline: MTLRenderPipelineState?
  private let stickerRenderPassDescriptor = MTLRenderPassDescriptor()

  public required override init() {
    do {
      let library = try metalDevice.makeDefaultLibrary(bundle: Bundle(for: CRTLutFilterRenderer.self))
      let kernelFunction = library.makeFunction(name: "lutFilterKernel")
      lutFilterComputePipeline = try metalDevice.makeComputePipelineState(function: kernelFunction!)

      let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
      renderPipelineDescriptor.label = "StickerRenderPipeline"
      renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
      renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "samplingShader")
      renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      renderPipelineDescriptor.isAlphaToCoverageEnabled = true
      stickerRenderPipeline = try metalDevice.makeRenderPipelineState(descriptor: renderPipelineDescriptor)

      stickerRenderPassDescriptor.colorAttachments[0].loadAction = .load
      stickerRenderPassDescriptor.colorAttachments[0].storeAction = .store
    } catch {
      print("Could not create pipeline state: \(error)")
    }
  }

  @objc
  public func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
    reset()

    (outputPixelBufferPool, _, _) = allocateOutputBufferPool(with: formatDescription,
      outputRetainedBufferCountHint: outputRetainedBufferCountHint)
    if outputPixelBufferPool == nil {
      return
    }
    inputFormatDescription = formatDescription

    var metalTextureCache: CoreVideo.CVMetalTextureCache?
    if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
      assertionFailure("Unable to allocate texture cache")
    } else {
      textureCache = metalTextureCache
    }

    isPrepared = true
  }

  private func allocateOutputBufferPool(with inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) -> (
    outputBufferPool: CVPixelBufferPool?,
    outputColorSpace: CGColorSpace?,
    outputFormatDescription: CMFormatDescription?) {
    let inputMediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
    if inputMediaSubType != kCVPixelFormatType_32BGRA {
      assertionFailure("Invalid input pixel buffer type \(inputMediaSubType)")
      return (nil, nil, nil)
    }

    let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
    var pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: UInt(inputMediaSubType),
      kCVPixelBufferWidthKey as String: Int(inputDimensions.width),
      kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    // Get pixel buffer attributes and color space from the input format description.
    var cgColorSpace = CGColorSpaceCreateDeviceRGB()
    if let inputFormatDescriptionExtension = CMFormatDescriptionGetExtensions(inputFormatDescription) as Dictionary? {
      let colorPrimaries = inputFormatDescriptionExtension[kCVImageBufferColorPrimariesKey]

      if let colorPrimaries = colorPrimaries {
        var colorSpaceProperties: [String: AnyObject] = [kCVImageBufferColorPrimariesKey as String: colorPrimaries]

        if let yCbCrMatrix = inputFormatDescriptionExtension[kCVImageBufferYCbCrMatrixKey] {
          colorSpaceProperties[kCVImageBufferYCbCrMatrixKey as String] = yCbCrMatrix
        }

        if let transferFunction = inputFormatDescriptionExtension[kCVImageBufferTransferFunctionKey] {
          colorSpaceProperties[kCVImageBufferTransferFunctionKey as String] = transferFunction
        }

        pixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = colorSpaceProperties
      }

      if let cvColorspace = inputFormatDescriptionExtension[kCVImageBufferCGColorSpaceKey] {
        cgColorSpace = cvColorspace as! CGColorSpace
      } else if (colorPrimaries as? String) == (kCVImageBufferColorPrimaries_P3_D65 as String) {
        cgColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
      }
    }

    // Create a pixel buffer pool with the same pixel attributes as the input format description.
    let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
    var cvPixelBufferPool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, pixelBufferAttributes as NSDictionary?, &cvPixelBufferPool)
    guard let pixelBufferPool = cvPixelBufferPool else {
      assertionFailure("Allocation failure: Could not allocate pixel buffer pool.")
      return (nil, nil, nil)
    }

    preallocateBuffers(pool: pixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)

    // Get the output format description.
    var pixelBuffer: CVPixelBuffer?
    var outputFormatDescription: CMFormatDescription?
    let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: outputRetainedBufferCountHint] as NSDictionary
    CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pixelBufferPool, auxAttributes, &pixelBuffer)
    if let pixelBuffer = pixelBuffer {
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &outputFormatDescription)
    }
    pixelBuffer = nil

    return (pixelBufferPool, cgColorSpace, outputFormatDescription)
  }

  private func preallocateBuffers(pool: CVPixelBufferPool, allocationThreshold: Int) {
    var pixelBuffers = [CVPixelBuffer]()
    var error: CVReturn = kCVReturnSuccess
    let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold] as NSDictionary
    var pixelBuffer: CVPixelBuffer?
    while error == kCVReturnSuccess {
      error = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
      if let pixelBuffer = pixelBuffer {
        pixelBuffers.append(pixelBuffer)
      }
      pixelBuffer = nil
    }
    pixelBuffers.removeAll()
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

  private func configureLutTexture(_ lutFilePath: NSString?, _ filterDir: Int) {
    if lutFilePath?.isKind(of: NSNull.self) != false {
      lutTexture = nil
      return
    }

    let dirUrl: URL?
    if filterDir == CRTLutFilterRenderer.FILTER_DIR_CACHE {
      dirUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    } else {
      dirUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    guard let lutUrl = dirUrl?.appendingPathComponent(String(lutFilePath!)) else {
      lutTexture = nil
      return
    }

    let data = try? Data(contentsOf: lutUrl)
    lutTexture = data?.metalTexture
  }

  @objc
  public func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    render(inputTexture: makeTextureFromCVPixelBuffer(pixelBuffer: pixelBuffer, textureFormat: .bgra8Unorm));
  }

  @objc
  public func render(inputTexture input: MTLTexture?) -> CVPixelBuffer? {
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
    guard let inputTexture = input,
          let outputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: outputPixelBuffer, textureFormat: .bgra8Unorm) else {
      return nil
    }

    // Set up command queue, buffer, and encoder.
    guard let commandQueue = commandQueue,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
      print("Failed to create a Metal command queue.")
      CVMetalTextureCacheFlush(textureCache, 0)
      return nil
    }

    computeEncoder.label = "LutFilterEncoder"
    computeEncoder.setComputePipelineState(lutFilterComputePipeline!)
    computeEncoder.setTexture(inputTexture, index: Int(CRTTextureIndexInput.rawValue))
    computeEncoder.setTexture(outputTexture, index: Int(CRTTextureIndexOutput.rawValue))
    computeEncoder.setTexture(lutTexture, index: Int(CRTTextureIndexLut.rawValue))
    computeEncoder.setBytes(&intensity, length: MemoryLayout<Float>.size, index: Int(CRTBufferIndexIntensity.rawValue))
    computeEncoder.setBytes(&grain, length: MemoryLayout<Float>.size, index: Int(CRTBufferIndexGrain.rawValue))
    computeEncoder.setBytes(&vignette, length: MemoryLayout<Float>.size, index: Int(CRTBufferIndexVignette.rawValue))

    // Set up the thread groups.
    let width = lutFilterComputePipeline!.threadExecutionWidth
    let height = lutFilterComputePipeline!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
      height: (inputTexture.height + height - 1) / height,
      depth: 1)
    computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    computeEncoder.endEncoding()

    if !stickerViews.isEmpty {
      stickerRenderPassDescriptor.colorAttachments[0].texture = outputTexture

      let isWidthHeightOpposite = outputTexture.width > outputTexture.height
      let textureWidth: Double = isWidthHeightOpposite ? Double(outputTexture.height) : Double(outputTexture.width)
      let textureHeight: Double = isWidthHeightOpposite ? Double(outputTexture.width) : Double(outputTexture.height)
      var multiplier: Double = textureWidth / stickerBoardViewport.width

      var realStickerBoardWidth = stickerBoardViewport.width * multiplier
      var realStickerBoardHeight = stickerBoardViewport.height * multiplier
      if realStickerBoardHeight > textureHeight {
        multiplier = textureHeight / stickerBoardViewport.height
        realStickerBoardWidth = stickerBoardViewport.width * multiplier
        realStickerBoardHeight = stickerBoardViewport.height * multiplier
      }

      var realStickerBoardViewport = isWidthHeightOpposite
        ? vector_uint2(x: UInt32(realStickerBoardHeight), y: UInt32(realStickerBoardWidth))
        : vector_uint2(x: UInt32(realStickerBoardWidth), y: UInt32(realStickerBoardHeight))
      let mtlViewport = isWidthHeightOpposite ? MTLViewport(
        originX: (textureHeight - realStickerBoardHeight) / 2,
        originY: (textureWidth - realStickerBoardWidth) / 2,
        width: realStickerBoardHeight,
        height: realStickerBoardWidth,
        znear: -1,
        zfar: 1
      ) : MTLViewport(
        originX: (textureWidth - realStickerBoardWidth) / 2,
        originY: (textureHeight - realStickerBoardHeight) / 2,
        width: realStickerBoardWidth,
        height: realStickerBoardHeight,
        znear: -1,
        zfar: 1
      )

      let mf = Float(multiplier)
      for stickerView in stickerViews {
        let quadVertices = stickerView.verticesOnBoard.map {
          CRTVertex(position: vector_float2($0.position.x * mf, $0.position.y * mf), textureCoordinate: $0.textureCoordinate)
        }

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: stickerRenderPassDescriptor)!
        renderEncoder.label = "StickerRenderEncoder"
        renderEncoder.setViewport(mtlViewport)
        renderEncoder.setRenderPipelineState(stickerRenderPipeline!)
        renderEncoder.setVertexBytes(quadVertices, length: MemoryLayout<vector_float2>.size * quadVertices.count * 2, index: Int(CRTVertexIndexVertices.rawValue))
        renderEncoder.setVertexBytes(&realStickerBoardViewport, length: MemoryLayout.size(ofValue: realStickerBoardViewport), index: Int(CRTVertexIndexViewportSize.rawValue))
        renderEncoder.setFragmentTexture(stickerView.imageTexture, index: Int(CRTTextureIndexInput.rawValue))
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
      }
    }

    commandBuffer.commit()
    return outputPixelBuffer
  }

  private func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer, textureFormat: MTLPixelFormat) -> MTLTexture? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    // Create a Metal texture from the image buffer.
    var cvTextureOut: CoreVideo.CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, textureFormat, width, height, 0, &cvTextureOut)

    guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
      CVMetalTextureCacheFlush(textureCache, 0)

      return nil
    }

    return texture
  }

  @objc
  public func setStickerBoardViewport(width: Double, height: Double) {
    stickerBoardViewport = (width, height)
  }

  @objc
  public func addStickerView(id: Int, imagePath: String, centerX: Double, centerY: Double, size: Double) {
    let i = stickerViews.firstIndex(where: { $0.id == id })

    if i == nil {
      let dirUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      guard let imageUrl = URL(string: imagePath, relativeTo: dirUrl),
            let imageData = try? Data(contentsOf: imageUrl),
            let imageTexture = imageData.metalTexture else {
        return
      }

      let centerX = stickerBoardViewport.width / 2 * centerX;
      let centerY = stickerBoardViewport.height / 2 * centerY;
      let halfSize = size / 2;
      let verticesOnBoard = [
        CRTVertex(position: vector_float2(Float(centerX + halfSize), Float(centerY - halfSize)), textureCoordinate: vector_float2(1, 1)),
        CRTVertex(position: vector_float2(Float(centerX - halfSize), Float(centerY - halfSize)), textureCoordinate: vector_float2(0, 1)),
        CRTVertex(position: vector_float2(Float(centerX - halfSize), Float(centerY + halfSize)), textureCoordinate: vector_float2(0, 0)),
        CRTVertex(position: vector_float2(Float(centerX + halfSize), Float(centerY - halfSize)), textureCoordinate: vector_float2(1, 1)),
        CRTVertex(position: vector_float2(Float(centerX - halfSize), Float(centerY + halfSize)), textureCoordinate: vector_float2(0, 0)),
        CRTVertex(position: vector_float2(Float(centerX + halfSize), Float(centerY + halfSize)), textureCoordinate: vector_float2(1, 0)),
      ]

      stickerViews.append(CRTStickerView(id: id, imageTexture: imageTexture, verticesOnBoard: verticesOnBoard))
    } else {
      let centerX = stickerBoardViewport.width / 2 * centerX;
      let centerY = stickerBoardViewport.height / 2 * centerY;
      let halfSize = size / 2;
      let verticesOnBoard = [
        CRTVertex(position: vector_float2(Float(centerX + halfSize), Float(centerY - halfSize)), textureCoordinate: vector_float2(1, 1)),
        CRTVertex(position: vector_float2(Float(centerX - halfSize), Float(centerY - halfSize)), textureCoordinate: vector_float2(0, 1)),
        CRTVertex(position: vector_float2(Float(centerX - halfSize), Float(centerY + halfSize)), textureCoordinate: vector_float2(0, 0)),
        CRTVertex(position: vector_float2(Float(centerX + halfSize), Float(centerY - halfSize)), textureCoordinate: vector_float2(1, 1)),
        CRTVertex(position: vector_float2(Float(centerX - halfSize), Float(centerY + halfSize)), textureCoordinate: vector_float2(0, 0)),
        CRTVertex(position: vector_float2(Float(centerX + halfSize), Float(centerY + halfSize)), textureCoordinate: vector_float2(1, 0)),
      ]

      if i == stickerViews.count - 1 {
        stickerViews[i!].verticesOnBoard = verticesOnBoard
      } else {
        var removed = stickerViews.remove(at: i!)
        removed.verticesOnBoard = verticesOnBoard
        stickerViews.append(removed)
      }
    }
  }
}
