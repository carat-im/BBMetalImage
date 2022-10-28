#include <metal_stdlib>
using namespace metal;

#import "CRTShaderTypes.h"

kernel void
lutFilterKernel(texture2d<half, access::read> inputTexture [[texture(CRTTextureIndexInput)]],
                     texture2d<half, access::write> outputTexture [[texture(CRTTextureIndexOutput)]],
                     uint2 gid [[thread_position_in_grid]])
{
    // Don't read or write outside of the texture.
    if ((gid.x >= outputTexture.get_width()) || (gid.y >= outputTexture.get_height())) {
        return;
    }

    outputTexture.write(inputTexture.read(gid), gid);
}
