/*M///////////////////////////////////////////////////////////////////////////////////////
//
//  IMPORTANT: READ BEFORE DOWNLOADING, COPYING, INSTALLING OR USING.
//
//  By downloading, copying, installing or using the software you agree to this license.
//  If you do not agree to this license, do not download, install,
//  copy or use the software.
//
//
//                           License Agreement
//                For Open Source Computer Vision Library
//
// Copyright (C) 2010-2012, Multicoreware, Inc., all rights reserved.
// Copyright (C) 2010-2012, Advanced Micro Devices, Inc., all rights reserved.
// Third party copyrights are property of their respective owners.
//
// @Authors
//    Nathan, liujun@multicorewareinc.com
//    Peng Xiao, pengxiao@outlook.com
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
//   * Redistribution's of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//
//   * Redistribution's in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other oclMaterials provided with the distribution.
//
//   * The name of the copyright holders may not be used to endorse or promote products
//     derived from this software without specific prior written permission.
//
// This software is provided by the copyright holders and contributors "as is" and
// any express or implied warranties, including, but not limited to, the implied
// warranties of merchantability and fitness for a particular purpose are disclaimed.
// In no event shall the Intel Corporation or contributors be liable for any direct,
// indirect, incidental, special, exemplary, or consequential damages
// (including, but not limited to, procurement of substitute goods or services;
// loss of use, data, or profits; or business interruption) however caused
// and on any theory of liability, whether in contract, strict liability,
// or tort (including negligence or otherwise) arising in any way out of
// the use of this software, even if advised of the possibility of such damage.
//
//M*/

#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics:enable
#define MAX_FLOAT 3.40282e+038f

#ifndef BLOCK_SIZE
#define BLOCK_SIZE 16
#endif
#ifndef MAX_DESC_LEN
#define MAX_DESC_LEN 64
#endif

int bit1Count(float x)
{
    int c = 0;
    int ix = (int)x;
    for (int i = 0 ; i < 32 ; i++)
    {
        c += ix & 0x1;
        ix >>= 1;
    }
    return (float)c;
}

#ifndef DIST_TYPE
#define DIST_TYPE 0
#endif

#if   (DIST_TYPE == 0)
#define DIST(x, y) fabs((x) - (y))
#elif (DIST_TYPE == 1)
#define DIST(x, y) (((x) - (y)) * ((x) - (y)))
#elif (DIST_TYPE == 2)
#define DIST(x, y) bit1Count((uint)(x) ^ (uint)(y))
#endif


float reduce_block(__local float *s_query,
                   __local float *s_train,
                   int lidx,
                   int lidy
                  )
{
    float result = 0;
    #pragma unroll
    for (int j = 0 ; j < BLOCK_SIZE ; j++)
    {
        result += DIST(s_query[lidy * BLOCK_SIZE + j], s_train[j * BLOCK_SIZE + lidx]);
    }
    return result;
}

float reduce_multi_block(__local float *s_query,
                         __local float *s_train,
                         int block_index,
                         int lidx,
                         int lidy
                        )
{
    float result = 0;
    #pragma unroll
    for (int j = 0 ; j < BLOCK_SIZE ; j++)
    {
        result += DIST(s_query[lidy * MAX_DESC_LEN + block_index * BLOCK_SIZE + j], s_train[j * BLOCK_SIZE + lidx]);
    }
    return result;
}

/* 2dim launch, global size: dim0 is (query rows + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE, dim1 is BLOCK_SIZE
local size: dim0 is BLOCK_SIZE, dim1 is BLOCK_SIZE.
*/
__kernel void BruteForceMatch_UnrollMatch_D5(
    __global float *query,
    __global float *train,
    //__global float *mask,
    __global int *bestTrainIdx,
    __global float *bestDistance,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int step
)
{

    const int lidx = get_local_id(0);
    const int lidy = get_local_id(1);
    const int groupidx = get_group_id(0);

    __local float *s_query = sharebuffer;
    __local float *s_train = sharebuffer + BLOCK_SIZE * MAX_DESC_LEN;

    int queryIdx = groupidx * BLOCK_SIZE + lidy;
    // load the query into local memory.
    #pragma unroll
    for (int i = 0 ;  i <  MAX_DESC_LEN / BLOCK_SIZE; i ++)
    {
        int loadx = lidx + i * BLOCK_SIZE;
        s_query[lidy * MAX_DESC_LEN + loadx] = loadx < query_cols ? query[min(queryIdx, query_rows - 1)  * (step / sizeof(float)) + loadx] : 0;
    }

    float myBestDistance = MAX_FLOAT;
    int myBestTrainIdx = -1;

    // loopUnrolledCached to find the best trainIdx and best distance.
    volatile int imgIdx = 0;
    for (int t = 0, endt = (train_rows + BLOCK_SIZE - 1) / BLOCK_SIZE; t < endt; t++)
    {
        float result = 0;
        #pragma unroll
        for (int i = 0 ; i < MAX_DESC_LEN / BLOCK_SIZE ; i++)
        {
            //load a BLOCK_SIZE * BLOCK_SIZE block into local train.
            const int loadx = lidx + i * BLOCK_SIZE;
            s_train[lidx * BLOCK_SIZE + lidy] = loadx < train_cols ? train[min(t * BLOCK_SIZE + lidy, train_rows - 1) * (step / sizeof(float)) + loadx] : 0;

            //synchronize to make sure each elem for reduceIteration in share memory is written already.
            barrier(CLK_LOCAL_MEM_FENCE);

            result += reduce_multi_block(s_query, s_train, i, lidx, lidy);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        int trainIdx = t * BLOCK_SIZE + lidx;

        if (queryIdx < query_rows && trainIdx < train_rows && result < myBestDistance/* && mask(queryIdx, trainIdx)*/)
        {
            //bestImgIdx = imgIdx;
            myBestDistance = result;
            myBestTrainIdx = trainIdx;
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);
    __local float *s_distance = (__local float*)(sharebuffer);
    __local int* s_trainIdx = (__local int *)(sharebuffer + BLOCK_SIZE * BLOCK_SIZE);

    //find BestMatch
    s_distance += lidy * BLOCK_SIZE;
    s_trainIdx += lidy * BLOCK_SIZE;
    s_distance[lidx] = myBestDistance;
    s_trainIdx[lidx] = myBestTrainIdx;

    barrier(CLK_LOCAL_MEM_FENCE);

    //reduce -- now all reduce implement in each threads.
    #pragma unroll
    for (int k = 0 ; k < BLOCK_SIZE; k++)
    {
        if (myBestDistance > s_distance[k])
        {
            myBestDistance = s_distance[k];
            myBestTrainIdx = s_trainIdx[k];
        }
    }

    if (queryIdx < query_rows && lidx == 0)
    {
        bestTrainIdx[queryIdx] = myBestTrainIdx;
        bestDistance[queryIdx] = myBestDistance;
    }
}

__kernel void BruteForceMatch_Match_D5(
    __global float *query,
    __global float *train,
    //__global float *mask,
    __global int *bestTrainIdx,
    __global float *bestDistance,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int step
)
{
    const int lidx = get_local_id(0);
    const int lidy = get_local_id(1);
    const int groupidx = get_group_id(0);

    const int queryIdx = groupidx * BLOCK_SIZE + lidy;

    float myBestDistance = MAX_FLOAT;
    int myBestTrainIdx = -1;

    __local float *s_query = sharebuffer;
    __local float *s_train = sharebuffer + BLOCK_SIZE * BLOCK_SIZE;

    // loop
    for (int t = 0 ;  t < (train_rows + BLOCK_SIZE - 1) / BLOCK_SIZE ; t++)
    {
        //Dist dist;
        float result = 0;
        for (int i = 0 ; i < (query_cols + BLOCK_SIZE - 1) / BLOCK_SIZE ; i++)
        {
            const int loadx = lidx + i * BLOCK_SIZE;
            //load query and train into local memory
            s_query[lidy * BLOCK_SIZE + lidx] = 0;
            s_train[lidx * BLOCK_SIZE + lidy] = 0;

            if (loadx < query_cols)
            {
                s_query[lidy * BLOCK_SIZE + lidx] = query[min(queryIdx, query_rows - 1) * (step / sizeof(float)) + loadx];
                s_train[lidx * BLOCK_SIZE + lidy] = train[min(t * BLOCK_SIZE + lidy, train_rows - 1) * (step / sizeof(float)) + loadx];
            }

            barrier(CLK_LOCAL_MEM_FENCE);

            result += reduce_block(s_query, s_train, lidx, lidy);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        const int trainIdx = t * BLOCK_SIZE + lidx;

        if (queryIdx < query_rows && trainIdx < train_rows && result < myBestDistance /*&& mask(queryIdx, trainIdx)*/)
        {
            //myBestImgidx = imgIdx;
            myBestDistance = result;
            myBestTrainIdx = trainIdx;
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    __local float *s_distance = (__local float *)sharebuffer;
    __local int *s_trainIdx = (__local int *)(sharebuffer + BLOCK_SIZE * BLOCK_SIZE);

    //findBestMatch
    s_distance += lidy * BLOCK_SIZE;
    s_trainIdx += lidy * BLOCK_SIZE;
    s_distance[lidx] = myBestDistance;
    s_trainIdx[lidx] = myBestTrainIdx;

    barrier(CLK_LOCAL_MEM_FENCE);

    //reduce -- now all reduce implement in each threads.
    for (int k = 0 ; k < BLOCK_SIZE; k++)
    {
        if (myBestDistance > s_distance[k])
        {
            myBestDistance = s_distance[k];
            myBestTrainIdx = s_trainIdx[k];
        }
    }

    if (queryIdx < query_rows && lidx == 0)
    {
        bestTrainIdx[queryIdx] = myBestTrainIdx;
        bestDistance[queryIdx] = myBestDistance;
    }
}

//radius_unrollmatch
__kernel void BruteForceMatch_RadiusUnrollMatch_D5(
    __global float *query,
    __global float *train,
    float maxDistance,
    //__global float *mask,
    __global int *bestTrainIdx,
    __global float *bestDistance,
    __global int *nMatches,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int bestTrainIdx_cols,
    int step,
    int ostep
)
{
    const int lidx = get_local_id(0);
    const int lidy = get_local_id(1);
    const int groupidx = get_group_id(0);
    const int groupidy = get_group_id(1);

    const int queryIdx = groupidy * BLOCK_SIZE + lidy;
    const int trainIdx = groupidx * BLOCK_SIZE + lidx;

    __local float *s_query = sharebuffer;
    __local float *s_train = sharebuffer + BLOCK_SIZE * BLOCK_SIZE;

    float result = 0;
    for (int i = 0 ; i < MAX_DESC_LEN / BLOCK_SIZE ; ++i)
    {
        //load a BLOCK_SIZE * BLOCK_SIZE block into local train.
        const int loadx = lidx + i * BLOCK_SIZE;

        s_query[lidy * BLOCK_SIZE + lidx] = loadx < query_cols ? query[min(queryIdx, query_rows - 1)  * (step / sizeof(float)) + loadx] : 0;
        s_train[lidx * BLOCK_SIZE + lidy] = loadx < query_cols ? train[min(groupidx * BLOCK_SIZE + lidy, train_rows - 1)  * (step / sizeof(float)) + loadx] : 0;

        //synchronize to make sure each elem for reduceIteration in share memory is written already.
        barrier(CLK_LOCAL_MEM_FENCE);

        result += reduce_block(s_query, s_train, lidx, lidy);

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (queryIdx < query_rows && trainIdx < train_rows && result < maxDistance/* && mask(queryIdx, trainIdx)*/)
    {
        unsigned int ind = atom_inc(nMatches + queryIdx/*, (unsigned int) -1*/);

        if(ind < bestTrainIdx_cols)
        {
            //bestImgIdx = imgIdx;
            bestTrainIdx[queryIdx * (ostep / sizeof(int)) + ind] = trainIdx;
            bestDistance[queryIdx * (ostep / sizeof(float)) + ind] = result;
        }
    }
}

//radius_match
__kernel void BruteForceMatch_RadiusMatch_D5(
    __global float *query,
    __global float *train,
    float maxDistance,
    //__global float *mask,
    __global int *bestTrainIdx,
    __global float *bestDistance,
    __global int *nMatches,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int bestTrainIdx_cols,
    int step,
    int ostep
)
{
    const int lidx = get_local_id(0);
    const int lidy = get_local_id(1);
    const int groupidx = get_group_id(0);
    const int groupidy = get_group_id(1);

    const int queryIdx = groupidy * BLOCK_SIZE + lidy;
    const int trainIdx = groupidx * BLOCK_SIZE + lidx;

    __local float *s_query = sharebuffer;
    __local float *s_train = sharebuffer + BLOCK_SIZE * BLOCK_SIZE;

    float result = 0;
    for (int i = 0 ; i < (query_cols + BLOCK_SIZE - 1) / BLOCK_SIZE ; ++i)
    {
        //load a BLOCK_SIZE * BLOCK_SIZE block into local train.
        const int loadx = lidx + i * BLOCK_SIZE;

        s_query[lidy * BLOCK_SIZE + lidx] = loadx < query_cols ? query[min(queryIdx, query_rows - 1)  * (step / sizeof(float)) + loadx] : 0;
        s_train[lidx * BLOCK_SIZE + lidy] = loadx < query_cols ? train[min(groupidx * BLOCK_SIZE + lidy, train_rows - 1)  * (step / sizeof(float)) + loadx] : 0;

        //synchronize to make sure each elem for reduceIteration in share memory is written already.
        barrier(CLK_LOCAL_MEM_FENCE);

        result += reduce_block(s_query, s_train, lidx, lidy);

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (queryIdx < query_rows && trainIdx < train_rows && result < maxDistance/* && mask(queryIdx, trainIdx)*/)
    {
        unsigned int ind = atom_inc(nMatches + queryIdx);

        if(ind < bestTrainIdx_cols)
        {
            //bestImgIdx = imgIdx;
            bestTrainIdx[queryIdx * (ostep / sizeof(int)) + ind] = trainIdx;
            bestDistance[queryIdx * (ostep / sizeof(float)) + ind] = result;
        }
    }
}


__kernel void BruteForceMatch_knnUnrollMatch_D5(
    __global float *query,
    __global float *train,
    //__global float *mask,
    __global int2 *bestTrainIdx,
    __global float2 *bestDistance,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int step
)
{
    const int lidx = get_local_id(0);
    const int lidy = get_local_id(1);
    const int groupidx = get_group_id(0);

    const int queryIdx = groupidx * BLOCK_SIZE + lidy;
    local float *s_query = sharebuffer;
    local float *s_train = sharebuffer + BLOCK_SIZE * MAX_DESC_LEN;

    // load the query into local memory.
    for (int i = 0 ;  i <  MAX_DESC_LEN / BLOCK_SIZE; i ++)
    {
        int loadx = lidx + i * BLOCK_SIZE;
        s_query[lidy * MAX_DESC_LEN + loadx] = loadx < query_cols ? query[min(queryIdx, query_rows - 1)  * (step / sizeof(float)) + loadx] : 0;
    }

    float myBestDistance1 = MAX_FLOAT;
    float myBestDistance2 = MAX_FLOAT;
    int myBestTrainIdx1 = -1;
    int myBestTrainIdx2 = -1;

    //loopUnrolledCached
    volatile int imgIdx = 0;
    for (int t = 0 ; t < (train_rows + BLOCK_SIZE - 1) / BLOCK_SIZE ; t++)
    {
        float result = 0;
        for (int i = 0 ; i < MAX_DESC_LEN / BLOCK_SIZE ; i++)
        {
            const int loadX = lidx + i * BLOCK_SIZE;
            //load a BLOCK_SIZE * BLOCK_SIZE block into local train.
            const int loadx = lidx + i * BLOCK_SIZE;
            s_train[lidx * BLOCK_SIZE + lidy] = loadx < train_cols ? train[min(t * BLOCK_SIZE + lidy, train_rows - 1) * (step / sizeof(float)) + loadx] : 0;

            //synchronize to make sure each elem for reduceIteration in share memory is written already.
            barrier(CLK_LOCAL_MEM_FENCE);

            result += reduce_multi_block(s_query, s_train, i, lidx, lidy);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        const int trainIdx = t * BLOCK_SIZE + lidx;

        if (queryIdx < query_rows && trainIdx < train_rows)
        {
            if (result < myBestDistance1)
            {
                myBestDistance2 = myBestDistance1;
                myBestTrainIdx2 = myBestTrainIdx1;
                myBestDistance1 = result;
                myBestTrainIdx1 = trainIdx;
            }
            else if (result < myBestDistance2)
            {
                myBestDistance2 = result;
                myBestTrainIdx2 = trainIdx;
            }
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    local float *s_distance = (local float *)sharebuffer;
    local int *s_trainIdx = (local int *)(sharebuffer + BLOCK_SIZE * BLOCK_SIZE);

    // find BestMatch
    s_distance += lidy * BLOCK_SIZE;
    s_trainIdx += lidy * BLOCK_SIZE;

    s_distance[lidx] = myBestDistance1;
    s_trainIdx[lidx] = myBestTrainIdx1;

    float bestDistance1 = MAX_FLOAT;
    float bestDistance2 = MAX_FLOAT;
    int bestTrainIdx1 = -1;
    int bestTrainIdx2 = -1;
    barrier(CLK_LOCAL_MEM_FENCE);

    if (lidx == 0)
    {
        for (int i = 0 ; i < BLOCK_SIZE ; i++)
        {
            float val = s_distance[i];
            if (val < bestDistance1)
            {
                bestDistance2 = bestDistance1;
                bestTrainIdx2 = bestTrainIdx1;

                bestDistance1 = val;
                bestTrainIdx1 = s_trainIdx[i];
            }
            else if (val < bestDistance2)
            {
                bestDistance2 = val;
                bestTrainIdx2 = s_trainIdx[i];
            }
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    s_distance[lidx] = myBestDistance2;
    s_trainIdx[lidx] = myBestTrainIdx2;

    barrier(CLK_LOCAL_MEM_FENCE);

    if (lidx == 0)
    {
        for (int i = 0 ; i < BLOCK_SIZE ; i++)
        {
            float val = s_distance[i];

            if (val < bestDistance2)
            {
                bestDistance2 = val;
                bestTrainIdx2 = s_trainIdx[i];
            }
        }
    }

    myBestDistance1 = bestDistance1;
    myBestDistance2 = bestDistance2;

    myBestTrainIdx1 = bestTrainIdx1;
    myBestTrainIdx2 = bestTrainIdx2;

    if (queryIdx < query_rows && lidx == 0)
    {
        bestTrainIdx[queryIdx] = (int2)(myBestTrainIdx1, myBestTrainIdx2);
        bestDistance[queryIdx] = (float2)(myBestDistance1, myBestDistance2);
    }
}

__kernel void BruteForceMatch_knnMatch_D5(
    __global float *query,
    __global float *train,
    //__global float *mask,
    __global int2 *bestTrainIdx,
    __global float2 *bestDistance,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int step
)
{
    const int lidx = get_local_id(0);
    const int lidy = get_local_id(1);
    const int groupidx = get_group_id(0);

    const int queryIdx = groupidx * BLOCK_SIZE + lidy;
    local float *s_query = sharebuffer;
    local float *s_train = sharebuffer + BLOCK_SIZE * BLOCK_SIZE;

    float myBestDistance1 = MAX_FLOAT;
    float myBestDistance2 = MAX_FLOAT;
    int myBestTrainIdx1 = -1;
    int myBestTrainIdx2 = -1;

    //loop
    for (int  t = 0 ; t < (train_rows + BLOCK_SIZE - 1) / BLOCK_SIZE ; t++)
    {
        float result = 0.0f;
        for (int i = 0 ; i < (query_cols + BLOCK_SIZE -1) / BLOCK_SIZE ; i++)
        {
            const int loadx = lidx + i * BLOCK_SIZE;
            //load query and train into local memory
            s_query[lidy * BLOCK_SIZE + lidx] = 0;
            s_train[lidx * BLOCK_SIZE + lidy] = 0;

            if (loadx < query_cols)
            {
                s_query[lidy * BLOCK_SIZE + lidx] = query[min(queryIdx, query_rows - 1) * (step / sizeof(float)) + loadx];
                s_train[lidx * BLOCK_SIZE + lidy] = train[min(t * BLOCK_SIZE + lidy, train_rows - 1) * (step / sizeof(float)) + loadx];
            }

            barrier(CLK_LOCAL_MEM_FENCE);

            result += reduce_block(s_query, s_train, lidx, lidy);

            barrier(CLK_LOCAL_MEM_FENCE);
        }

        const int trainIdx = t * BLOCK_SIZE + lidx;

        if (queryIdx < query_rows && trainIdx < train_rows /*&& mask(queryIdx, trainIdx)*/)
        {
            if (result < myBestDistance1)
            {
                myBestDistance2 = myBestDistance1;
                myBestTrainIdx2 = myBestTrainIdx1;
                myBestDistance1 = result;
                myBestTrainIdx1 = trainIdx;
            }
            else if (result < myBestDistance2)
            {
                myBestDistance2 = result;
                myBestTrainIdx2 = trainIdx;
            }
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    __local float *s_distance = (__local float *)sharebuffer;
    __local int *s_trainIdx = (__local int *)(sharebuffer + BLOCK_SIZE * BLOCK_SIZE);

    //findBestMatch
    s_distance += lidy * BLOCK_SIZE;
    s_trainIdx += lidy * BLOCK_SIZE;

    s_distance[lidx] = myBestDistance1;
    s_trainIdx[lidx] = myBestTrainIdx1;

    float bestDistance1 = MAX_FLOAT;
    float bestDistance2 = MAX_FLOAT;
    int bestTrainIdx1 = -1;
    int bestTrainIdx2 = -1;
    barrier(CLK_LOCAL_MEM_FENCE);

    if (lidx == 0)
    {
        for (int i = 0 ; i < BLOCK_SIZE ; i++)
        {
            float val = s_distance[i];
            if (val < bestDistance1)
            {
                bestDistance2 = bestDistance1;
                bestTrainIdx2 = bestTrainIdx1;

                bestDistance1 = val;
                bestTrainIdx1 = s_trainIdx[i];
            }
            else if (val < bestDistance2)
            {
                bestDistance2 = val;
                bestTrainIdx2 = s_trainIdx[i];
            }
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    s_distance[lidx] = myBestDistance2;
    s_trainIdx[lidx] = myBestTrainIdx2;

    barrier(CLK_LOCAL_MEM_FENCE);

    if (lidx == 0)
    {
        for (int i = 0 ; i < BLOCK_SIZE ; i++)
        {
            float val = s_distance[i];

            if (val < bestDistance2)
            {
                bestDistance2 = val;
                bestTrainIdx2 = s_trainIdx[i];
            }
        }
    }

    myBestDistance1 = bestDistance1;
    myBestDistance2 = bestDistance2;

    myBestTrainIdx1 = bestTrainIdx1;
    myBestTrainIdx2 = bestTrainIdx2;

    if (queryIdx < query_rows && lidx == 0)
    {
        bestTrainIdx[queryIdx] = (int2)(myBestTrainIdx1, myBestTrainIdx2);
        bestDistance[queryIdx] = (float2)(myBestDistance1, myBestDistance2);
    }
}

kernel void BruteForceMatch_calcDistanceUnrolled_D5(
    __global float *query,
    __global float *train,
    //__global float *mask,
    __global float *allDist,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int step)
{
    /* Todo */
}

kernel void BruteForceMatch_calcDistance_D5(
    __global float *query,
    __global float *train,
    //__global float *mask,
    __global float *allDist,
    __local float *sharebuffer,
    int query_rows,
    int query_cols,
    int train_rows,
    int train_cols,
    int step)
{
    /* Todo */
}

kernel void BruteForceMatch_findBestMatch_D5(
    __global float *allDist,
    __global int *bestTrainIdx,
    __global float *bestDistance,
    int k
)
{
    /* Todo */
}