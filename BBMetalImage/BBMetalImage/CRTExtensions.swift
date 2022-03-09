//
// Created by Hansol Lee on 2022/03/10.
//

import Foundation
import MetalKit

extension Data {
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

public extension UIImage {
  @objc
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

  @objc
  func withMaxDimension(_ dimension: CGFloat) -> UIImage {
    let widthRatio = size.width / dimension
    let heightRatio = size.height / dimension
    if widthRatio > 1 || heightRatio > 1 {
      let biggerRatio = max(widthRatio, heightRatio)
      let percentage = 1 / biggerRatio
      let canvas = CGSize(width: size.width * percentage, height: size.height * percentage)
      let format = imageRendererFormat
      return UIGraphicsImageRenderer(size: canvas, format: format).image {
        _ in
        draw(in: CGRect(origin: .zero, size: canvas))
      }
    } else {
      // No need to scale.
      return self
    }
  }
}

extension CGImage {
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
