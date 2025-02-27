//
// Created by kevin-ee on 2021/12/10.
//

import Foundation
import CoreMedia

protocol CRTFilterRenderer {

  var name: String { get }

  var isPrepared: Bool { get }

  // Prepare resources.
  func prepare(with inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int,
               type: CRTFilterRendererType, w: Int, h: Int, previewWidth: Int, previewHeight: Int)

  // Release resources.
  func reset()

  // Render the pixel buffer.
  func render(pixelBuffer: CVPixelBuffer, forPreview: Bool) -> CVPixelBuffer?
}

