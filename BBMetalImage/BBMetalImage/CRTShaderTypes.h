//
// Created by Hansol Lee on 2022/03/09.
//

#ifndef RUNNER_CRTSHADERTYPES_H
#define RUNNER_CRTSHADERTYPES_H

#include <simd/simd.h>

typedef enum CRTTextureIndex
{
    CRTTextureIndexInput  = 0,
    CRTTextureIndexOutput = 1,
} CRTTextureIndex;


typedef struct
{
    // The position for the vertex, in pixel space; a value of 100 indicates 100 pixels
    // from the origin/center.
    vector_float2 position;

    // The 2D texture coordinate for this vertex.
    vector_float2 textureCoordinate;
} CRTVertex;

typedef enum CRTVertexIndex
{
    CRTVertexIndexVertices     = 0,
    CRTVertexIndexViewportSize = 1,
} CRTVertexIndex;

#endif //RUNNER_CRTSHADERTYPES_H
