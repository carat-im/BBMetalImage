//
// Created by kevin-ee on 2021/12/10.
//

import CoreMedia
import CoreVideo
import Metal
import MetalKit

public class CRTLutFilterRenderer: NSObject, CRTFilterRenderer {
  var name: String = "CRTLutFilterRenderer"

  @objc public var isPrepared = false

  private var outputPixelBufferPool: CVPixelBufferPool?

  private var previewPixelBufferPool: CVPixelBufferPool?

  private let metalDevice = MTLCreateSystemDefaultDevice()!

  private var lutFilterComputePipeline: MTLComputePipelineState?

  private var textureCache: CoreVideo.CVMetalTextureCache?

  private lazy var commandQueue: MTLCommandQueue? = {
    self.metalDevice.makeCommandQueue()
  }()

  // 화면에 보이는 프리뷰 기준의 viewport e.g. 360x640
  private var previewStickerBoardViewport: (width: Double, height: Double) = (0, 0)

  private var stickerViews: [CRTStickerView] = []

  private var stickerRenderPipeline: MTLRenderPipelineState?
  private let stickerRenderPassDescriptor = MTLRenderPassDescriptor()

  private let stickerTextureCoordinates = [
    CRTFilterRendererType.PreviewBack: [
      vector_float2(1, 1),
      vector_float2(0, 1),
      vector_float2(0, 0),
      vector_float2(1, 1),
      vector_float2(0, 0),
      vector_float2(1, 0),
    ],
    CRTFilterRendererType.PreviewFront: [
      vector_float2(1, 1),
      vector_float2(0, 1),
      vector_float2(0, 0),
      vector_float2(1, 1),
      vector_float2(0, 0),
      vector_float2(1, 0),
    ],
    CRTFilterRendererType.PhotoBack: [
      vector_float2(0, 1),
      vector_float2(0, 0),
      vector_float2(1, 0),
      vector_float2(0, 1),
      vector_float2(1, 0),
      vector_float2(1, 1),
    ],
    CRTFilterRendererType.PhotoFront: [
      vector_float2(1, 1),
      vector_float2(1, 0),
      vector_float2(0, 0),
      vector_float2(1, 1),
      vector_float2(0, 0),
      vector_float2(0, 1),
    ],
    CRTFilterRendererType.Image: [
      vector_float2(1, 1),
      vector_float2(0, 1),
      vector_float2(0, 0),
      vector_float2(1, 1),
      vector_float2(0, 0),
      vector_float2(1, 0),
    ],
  ]

  private var type: CRTFilterRendererType = .PreviewBack

  @objc
  public var drawSticker: Bool = true

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

      // https://github.com/s1ddok/Alloy/blob/master/Sources/Alloy/Core/Extensions/Metal/MTLRenderPipelineColorAttachmentDescriptor%2BExtensions.swift
      renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
      renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
      renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
      renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
      renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
      renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

      stickerRenderPipeline = try metalDevice.makeRenderPipelineState(descriptor: renderPipelineDescriptor)

      stickerRenderPassDescriptor.colorAttachments[0].loadAction = .load
      stickerRenderPassDescriptor.colorAttachments[0].storeAction = .store
    } catch {
      print("Could not create pipeline state: \(error)")
    }
  }

  @objc
  public func prepare(with formatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int,
                      type: CRTFilterRendererType) {
    self.type = type
    reset()

    (outputPixelBufferPool, previewPixelBufferPool) = allocateOutputBufferPools(with: formatDescription,
      outputRetainedBufferCountHint: outputRetainedBufferCountHint)
    if outputPixelBufferPool == nil || previewPixelBufferPool == nil {
      return
    }

    var metalTextureCache: CoreVideo.CVMetalTextureCache?
    if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
      assertionFailure("Unable to allocate texture cache")
    } else {
      textureCache = metalTextureCache
    }

    isPrepared = true
  }

  private func allocateOutputBufferPools(with inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) -> (
    outputBufferPool: CVPixelBufferPool?,
    previewBufferPool: CVPixelBufferPool?) {
    let inputMediaSubType = CMFormatDescriptionGetMediaSubType(inputFormatDescription)
    if inputMediaSubType != kCVPixelFormatType_32BGRA {
      assertionFailure("Invalid input pixel buffer type \(inputMediaSubType)")
      return (nil, nil)
    }

    let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
    let width = Int(inputDimensions.width)
    let height = Int(inputDimensions.height)
    let previewWidth = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
    let previewHeight = Int(height * previewWidth / width)
    var pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: UInt(inputMediaSubType),
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    var previewPixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: UInt(inputMediaSubType),
      kCVPixelBufferWidthKey as String: previewWidth,
      kCVPixelBufferHeightKey as String: previewHeight,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    // Get pixel buffer attributes and color space from the input format description.
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
        previewPixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = colorSpaceProperties
      }
    }

    // Create a pixel buffer pool with the same pixel attributes as the input format description.
    let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
    var cvPixelBufferPool: CVPixelBufferPool?
    var previewCvPixelBufferPool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, pixelBufferAttributes as NSDictionary?, &cvPixelBufferPool)
    CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, previewPixelBufferAttributes as NSDictionary?, &previewCvPixelBufferPool)
    guard let pixelBufferPool = cvPixelBufferPool, let previewPixelBufferPool = previewCvPixelBufferPool else {
      assertionFailure("Allocation failure: Could not allocate pixel buffer pool.")
      return (nil, nil)
    }

    preallocateBuffers(pool: pixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)
    preallocateBuffers(pool: previewPixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)

    return (pixelBufferPool, previewPixelBufferPool)
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
    previewPixelBufferPool = nil
    if (textureCache != nil) {
      CVMetalTextureCacheFlush(textureCache!, 0)
    }
    textureCache = nil
    isPrepared = false
  }

  @objc
  public func render(pixelBuffer: CVPixelBuffer, forPreview: Bool) -> CVPixelBuffer? {
    render(inputTexture: makeTextureFromCVPixelBuffer(pixelBuffer: pixelBuffer, textureFormat: .bgra8Unorm), forPreview: forPreview);
  }

  @objc
  public func render(inputTexture input: MTLTexture?, forPreview: Bool) -> CVPixelBuffer? {
    if !isPrepared {
      return nil
    }

    var newPixelBuffer: CVPixelBuffer?
    if (forPreview) {
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, previewPixelBufferPool!, &newPixelBuffer)
    } else {
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &newPixelBuffer)
    }
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
      if (textureCache != nil) {
        CVMetalTextureCacheFlush(textureCache!, 0)
      }
      return nil
    }

    // LUT 필터 시작

    computeEncoder.label = "LutFilterEncoder"
    computeEncoder.setComputePipelineState(lutFilterComputePipeline!)
    computeEncoder.setTexture(inputTexture, index: Int(CRTTextureIndexInput.rawValue))
    computeEncoder.setTexture(outputTexture, index: Int(CRTTextureIndexOutput.rawValue))

    // Set up the thread groups.
    let width = lutFilterComputePipeline!.threadExecutionWidth
    let height = lutFilterComputePipeline!.maxTotalThreadsPerThreadgroup / width
    let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
    let threadgroupsPerGrid = MTLSize(width: (inputTexture.width + width - 1) / width,
      height: (inputTexture.height + height - 1) / height,
      depth: 1)
    computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

    computeEncoder.endEncoding()

    // LUT 필터 끝

    // 스티커 시작

    if !stickerViews.isEmpty && drawSticker {
      stickerRenderPassDescriptor.colorAttachments[0].texture = outputTexture

      let isWidthHeightOpposite = type != .Image && outputTexture.width > outputTexture.height

      // 화면에 보이는 프리뷰 기준의 width와 height.
      let previewTextureWidth: Double = isWidthHeightOpposite ? Double(outputTexture.height) : Double(outputTexture.width)
      let previewTextureHeight: Double = isWidthHeightOpposite ? Double(outputTexture.width) : Double(outputTexture.height)

      var multiplier: Double = previewTextureWidth / previewStickerBoardViewport.width

      var realPreviewStickerBoardWidth = previewStickerBoardViewport.width * multiplier
      var realPreviewStickerBoardHeight = previewStickerBoardViewport.height * multiplier

      // 프리뷰를 9:16으로 보고있을때의 케이스
      if realPreviewStickerBoardHeight > previewTextureHeight {
        multiplier = previewTextureHeight / previewStickerBoardViewport.height
        realPreviewStickerBoardWidth = previewStickerBoardViewport.width * multiplier
        realPreviewStickerBoardHeight = previewStickerBoardViewport.height * multiplier
      }

      let mtlViewport = isWidthHeightOpposite ? MTLViewport(
        originX: (previewTextureHeight - realPreviewStickerBoardHeight) / 2,
        originY: (previewTextureWidth - realPreviewStickerBoardWidth) / 2,
        width: realPreviewStickerBoardHeight,
        height: realPreviewStickerBoardWidth,
        znear: -1,
        zfar: 1
      ) : MTLViewport(
        originX: (previewTextureWidth - realPreviewStickerBoardWidth) / 2,
        originY: (previewTextureHeight - realPreviewStickerBoardHeight) / 2,
        width: realPreviewStickerBoardWidth,
        height: realPreviewStickerBoardHeight,
        znear: -1,
        zfar: 1
      )

      let mf = Float(multiplier)
      // 프리뷰에 보이는 것이 아닌, 카메라 데이터 기준의 스티커 보드 viewport.
      var cameraDataStickerBoardViewport = isWidthHeightOpposite
        ? vector_uint2(x: UInt32(realPreviewStickerBoardHeight), y: UInt32(realPreviewStickerBoardWidth))
        : vector_uint2(x: UInt32(realPreviewStickerBoardWidth), y: UInt32(realPreviewStickerBoardHeight))

      for stickerView in stickerViews {
        let previewCenterX = stickerView.centerInPreview.x
        let previewCenterY = stickerView.centerInPreview.y

        var cameraDataCenterXNorm = previewCenterX
        var cameraDataCenterYNorm = previewCenterY
        switch type {
        case .PhotoBack:
          // 후면 사진의 경우, cameraData가 preview에 보이기까지 2 과정을 거친다.
          // 1. 위아래 flip.
          // 2. 90도 clockwise 회전.
          // 따라서, 이 과정을 반대로 거친 위치에 스티커를 붙여야 한다.

          // 90도만큼 counter-clockwise로 회전
          let radians = Double.pi / 2
          cameraDataCenterXNorm = previewCenterX * cos(radians) - previewCenterY * sin(radians)
          cameraDataCenterYNorm = previewCenterX * sin(radians) + previewCenterY * cos(radians)

          // 위 아래 flip.
          if (isWidthHeightOpposite) {
            cameraDataCenterXNorm *= -1
          } else {
            cameraDataCenterYNorm *= -1
          }
        case .PhotoFront:
          let radians = -Double.pi / 2
          cameraDataCenterXNorm = previewCenterX * cos(radians) - previewCenterY * sin(radians)
          cameraDataCenterYNorm = previewCenterX * sin(radians) + previewCenterY * cos(radians)
        case .PreviewBack:
          if (isWidthHeightOpposite) {
            cameraDataCenterXNorm *= -1
          } else {
            cameraDataCenterYNorm *= -1
          }
        case .PreviewFront:
          if (isWidthHeightOpposite) {
            cameraDataCenterXNorm *= -1
          } else {
            cameraDataCenterYNorm *= -1
          }
        case .Image:
          cameraDataCenterYNorm *= -1
        default:
          break
        }

        let cameraDataCenterX: Float = Float(Double(cameraDataStickerBoardViewport.x) / 2 * cameraDataCenterXNorm)
        let cameraDataCenterY: Float = Float(Double(cameraDataStickerBoardViewport.y) / 2 * cameraDataCenterYNorm)
        let halfSize: Float = Float(stickerView.size / 2) * mf
        let stickerRadians: Float
        if type == .PhotoFront {
          stickerRadians = Float(stickerView.radians)
        } else {
          // counter-clockwise로 변환.
          stickerRadians = Float.pi * 2 - Float(stickerView.radians)
        }
        var quadPositions: [vector_float2] = []
        var x: Float = cosf(stickerRadians) * halfSize - sinf(stickerRadians) * -halfSize + cameraDataCenterX
        var y: Float = sinf(stickerRadians) * halfSize + cosf(stickerRadians) * -halfSize + cameraDataCenterY
        quadPositions.append(vector_float2(x, y))
        x = cosf(stickerRadians) * -halfSize - sinf(stickerRadians) * -halfSize + cameraDataCenterX
        y = sinf(stickerRadians) * -halfSize + cosf(stickerRadians) * -halfSize + cameraDataCenterY
        quadPositions.append(vector_float2(x, y))
        x = cosf(stickerRadians) * -halfSize - sinf(stickerRadians) * halfSize + cameraDataCenterX
        y = sinf(stickerRadians) * -halfSize + cosf(stickerRadians) * halfSize + cameraDataCenterY
        quadPositions.append(vector_float2(x, y))
        x = cosf(stickerRadians) * halfSize - sinf(stickerRadians) * -halfSize + cameraDataCenterX
        y = sinf(stickerRadians) * halfSize + cosf(stickerRadians) * -halfSize + cameraDataCenterY
        quadPositions.append(vector_float2(x, y))
        x = cosf(stickerRadians) * -halfSize - sinf(stickerRadians) * halfSize + cameraDataCenterX
        y = sinf(stickerRadians) * -halfSize + cosf(stickerRadians) * halfSize + cameraDataCenterY
        quadPositions.append(vector_float2(x, y))
        x = cosf(stickerRadians) * halfSize - sinf(stickerRadians) * halfSize + cameraDataCenterX
        y = sinf(stickerRadians) * halfSize + cosf(stickerRadians) * halfSize + cameraDataCenterY
        quadPositions.append(vector_float2(x, y))

        let textureCoordinates = stickerTextureCoordinates[type]!
        let quadVertices = [
          CRTVertex(position: quadPositions[0], textureCoordinate: textureCoordinates[0]),
          CRTVertex(position: quadPositions[1], textureCoordinate: textureCoordinates[1]),
          CRTVertex(position: quadPositions[2], textureCoordinate: textureCoordinates[2]),
          CRTVertex(position: quadPositions[3], textureCoordinate: textureCoordinates[3]),
          CRTVertex(position: quadPositions[4], textureCoordinate: textureCoordinates[4]),
          CRTVertex(position: quadPositions[5], textureCoordinate: textureCoordinates[5]),
        ]

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: stickerRenderPassDescriptor)!
        renderEncoder.label = "StickerRenderEncoder"
        renderEncoder.setViewport(mtlViewport)
        renderEncoder.setRenderPipelineState(stickerRenderPipeline!)
        renderEncoder.setVertexBytes(quadVertices, length: MemoryLayout<vector_float2>.size * quadVertices.count * 2, index: Int(CRTVertexIndexVertices.rawValue))
        renderEncoder.setVertexBytes(&cameraDataStickerBoardViewport, length: MemoryLayout.size(ofValue: cameraDataStickerBoardViewport), index: Int(CRTVertexIndexViewportSize.rawValue))
        renderEncoder.setFragmentTexture(stickerView.imageTexture, index: Int(CRTTextureIndexInput.rawValue))
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
      }
    }

    // 스티커 끝

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    return outputPixelBuffer
  }

  private func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer, textureFormat: MTLPixelFormat) -> MTLTexture? {
    if (textureCache == nil) {
      return nil
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    // Create a Metal texture from the image buffer.
    var cvTextureOut: CoreVideo.CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache!, pixelBuffer, nil, textureFormat, width, height, 0, &cvTextureOut)

    guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
      CVMetalTextureCacheFlush(textureCache!, 0)

      return nil
    }

    return texture
  }

  @objc
  public func setStickerBoardViewport(width: Double, height: Double) {
    previewStickerBoardViewport = (width, height)
  }

  @objc
  public func addStickerView(id: Int, imagePath: String, centerX: Double, centerY: Double, size: Double, radians: Double) {
    let i = stickerViews.firstIndex(where: { $0.id == id })

    if i == nil {
      let dirUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      guard let imageUrl = URL(string: imagePath, relativeTo: dirUrl),
            let imageData = try? Data(contentsOf: imageUrl),
            let imageTexture = imageData.metalTexture else {
        return
      }

      stickerViews.append(CRTStickerView(id: id, imageTexture: imageTexture, centerInPreview: (centerX, centerY), size: size, radians: radians))
    } else {
      if i == stickerViews.count - 1 {
        stickerViews[i!].centerInPreview = (centerX, centerY)
        stickerViews[i!].size = size
        stickerViews[i!].radians = radians
      } else {
        var removed = stickerViews.remove(at: i!)
        removed.centerInPreview = (centerX, centerY)
        removed.size = size
        removed.radians = radians
        stickerViews.append(removed)
      }
    }
  }

  @objc
  public func removeStickerView(id: Int) {
    guard let i = stickerViews.firstIndex(where: { $0.id == id }) else {
      return;
    }

    stickerViews.remove(at: i)
  }
}
