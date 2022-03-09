//
// Created by Hansol Lee on 2022/03/09.
//

#ifndef RUNNER_CRTSHADERTYPES_H
#define RUNNER_CRTSHADERTYPES_H


typedef enum CRTTextureIndex
{
    CRTTextureIndexInput  = 0,
    CRTTextureIndexOutput = 1,
    CRTTextureIndexLut = 2,
} CRTTextureIndex;

typedef enum CRTBufferIndex
{
    CRTBufferIndexIntensity = 0,
    CRTBufferIndexGrain = 1,
    CRTBufferIndexVignette = 2,
} CRTBufferIndex;


#endif //RUNNER_CRTSHADERTYPES_H
