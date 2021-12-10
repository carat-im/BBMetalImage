//
// Created by kevin-ee on 2021/12/10.
//

import Foundation
import MobileCoreServices

@objcMembers
public class CRTUtils: NSObject {
  public static func jpegData(withPixelBuffer pixelBuffer: CVPixelBuffer, attachments: CFDictionary?) -> Data? {
    let ciContext = CIContext()
    let renderedCIImage = CIImage(cvImageBuffer: pixelBuffer)
    guard let renderedCGImage = ciContext.createCGImage(renderedCIImage, from: renderedCIImage.extent) else {
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
