//
// Created by kevin-ee on 2021/12/10.
//

import Foundation
import MobileCoreServices

@objcMembers
public class CRTUtils: NSObject {
  public static func jpegData(withPixelBuffer pixelBuffer: CVPixelBuffer, attachments: CFDictionary?, aspectRatio: Double) -> Data? {
    let ciContext = CIContext()
    let renderedCIImage = CIImage(cvImageBuffer: pixelBuffer)

    var bounds = renderedCIImage.extent
    if aspectRatio != 0 {
      let imageWidth = bounds.height
      let imageHeight = bounds.width
      var realWidth = imageWidth
      let realHeight = realWidth / aspectRatio
      let changedHeightDelta = realHeight - imageHeight

      var verticalCutOff = 0.0, horizontalCutOff = 0.0, zoom = 1.0
      if (changedHeightDelta <= 0) {
        verticalCutOff = -changedHeightDelta / 2
      } else {
        zoom = realHeight / imageHeight
        realWidth = imageWidth / zoom
        let changedWidthDelta = imageWidth - realWidth
        horizontalCutOff = max(0, changedWidthDelta / 2)
      }

      bounds = bounds.insetBy(dx: verticalCutOff, dy: horizontalCutOff)
    }
    guard let renderedCGImage = ciContext.createCGImage(renderedCIImage, from: bounds) else {
      print("Failed to create CGImage")
      return nil
    }

    guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0) else {
      print("Create CFData error!")
      return nil
    }

    guard let cgImageDestination = CGImageDestinationCreateWithData(data, kUTTypeJPEG, 1, nil) else {
      print("Create CGImageDestination error!")
      return nil
    }

    CGImageDestinationAddImage(cgImageDestination, renderedCGImage, attachments)
    if CGImageDestinationFinalize(cgImageDestination) {
      return data as Data
    }
    print("Finalizing CGImageDestination error!")
    return nil
  }
}
