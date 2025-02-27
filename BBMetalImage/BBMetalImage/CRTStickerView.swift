//
// Created by Hansol Lee on 2022/03/17.
//

import Foundation

struct CRTStickerView {
  let id: Int
  let imageTexture: MTLTexture
  var centerInPreview: (x: Double, y: Double) // (-1, -1) ~ (1, 1) 기준 좌표
  var size: Double
  var radians: Double
}