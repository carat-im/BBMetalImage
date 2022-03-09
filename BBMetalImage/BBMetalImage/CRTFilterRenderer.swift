//
// Created by kevin-ee on 2021/12/10.
//

import Foundation
import CoreMedia

protocol CRTFilterRenderer {

  var name: String { get }

  var isPrepared: Bool { get }

  // Prepare resources.
  func prepare(with inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int)

  // Release resources.
  func reset()

  // The format description of the output pixel buffers.
  var outputFormatDescription: CMFormatDescription? { get }

  // The format description of the input pixel buffers.
  var inputFormatDescription: CMFormatDescription? { get }

  // Render the pixel buffer.
  func render(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
}

