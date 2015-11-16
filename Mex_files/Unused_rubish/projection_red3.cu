/*
 * Code that uses texture memory to compute a 3D projection of CBCT 
 *
 * IMPORTANT!!! CAUTION!! This code is designed for a Tesla 40k GPU.
 * It is a safe assumption to say that this code wont work in other GPUs as expected
 * or at all. Some of the involved reasons: float/double arithmetic.
 *
 * Ander Biguri
 */

#include <algorithm>
#include <cuda_runtime_api.h>
#include <cuda.h>
#include "projection.hpp"
#include "mex.h"
#include <math.h>

#define cudaCheckErrors(msg) \
    do { \
        cudaError_t __err = cudaGetLastError(); \
        if (__err != cudaSuccess) { \
            mexPrintf("%s \n",msg);\
            mexErrMsgIdAndTxt("CBCT:CUDA:projection",cudaGetErrorString(__err));\
		        } \
	    } while (0)
            

// Declare the texture reference.
texture<float, cudaTextureType3D , cudaReadModeElementType> tex; 

#define MAXTHREADS 1024
/*GEOMETRY DEFINITION
 *               
 *                Detector plane, behind
 *            |-----------------------------| 
 *            |                             | 
 *            |                             | 
 *            |                             | 
 *            |                             | 
 *            |      +--------+             |
              |     /        /|             |
     A Z      |    /        / |*D           |
     |        |   +--------+  |             |
     |        |   |        |  |             |
     |        |   |     *O |  +             |
     *--->y   |   |        | /              |
    /         |   |        |/               |
   V X        |   +--------+                |
 *            |-----------------------------|
 *   
 *           *S
 *
 *
 *
 *
 *
 **/




__device__ void warpReduce(volatile double *sdata, unsigned int tid) {
	sdata[tid] += sdata[tid + 32];
	sdata[tid] += sdata[tid + 16];
	sdata[tid] += sdata[tid + 8];
	sdata[tid] += sdata[tid + 4];
	sdata[tid] += sdata[tid + 2];
	sdata[tid] += sdata[tid + 1];
}

__global__ void computeVectors(const Geometry geo, double* vectors,
							   const Point3D source, const Point3D deltaU,
							   const Point3D deltaV, const Point3D uvOrigin)
{
	unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
	
	if ( idx >= geo.nDetecU * geo.nDetecV )
		return;
	
	int pixelV = geo.nDetecV - (idx % geo.nDetecV) - 1;
	int pixelU = idx / geo.nDetecV;
	   
	// Get pixel coords in XYZ
	double Px, Py, Pz;
    double Sx = source.x, Sy = source.y, Sz = source.z;
	Px = (uvOrigin.x + pixelU * deltaU.x + pixelV * deltaV.x);
	Py = (uvOrigin.y + pixelU * deltaU.y + pixelV * deltaV.y);
	Pz = (uvOrigin.z + pixelU * deltaU.z + pixelV * deltaV.z);
	   
	double length = sqrt((Sx - Px) * (Sx - Px) + 
	  					 (Sy - Py) * (Sy - Py) +
	   					 (Sz - Pz) * (Sz - Pz));
	 double vectX ,vectY, vectZ;
	length = ceil(length/geo.accuracy);//Divide the directional vector by an integer
	vectX = (Px - Sx)/(length);
	vectY = (Py - Sy)/(length);
	vectZ = (Pz - Sz)/(length);
	   
	//here comes the deal
	double deltalength = sqrt((vectX * geo.dVoxelX) * (vectX * geo.dVoxelX) +
	           		   (vectY * geo.dVoxelY) * (vectY * geo.dVoxelY) +
	           		   (vectZ * geo.dVoxelZ) * (vectZ * geo.dVoxelZ));
	    
	    
	idx *= 5; // shift to memory address
	vectors[idx + 0] = vectX;
	vectors[idx + 1] = vectY;
	vectors[idx + 2] = vectZ;
	vectors[idx + 3] = length;
	vectors[idx + 4] = deltalength;
}
__global__ void kernelPixelDetector(const Point3D source, const double* vectors,
									double* detector,Geometry geo,double maxdist)
{
    size_t idx =  blockIdx.x;
    size_t vidx;
    unsigned int tidx = threadIdx.x;
    
    double length, deltalength;
    double vectX ,vectY, vectZ;
    double Sx = source.x, Sy = source.y, Sz = source.z;
    
    __shared__ double smem[4];
    __shared__ double sum[MAXTHREADS];

   
  	
  	if ( tidx < 4 ) {
  		vidx = idx * 5;
	    smem[tidx] = vectors[vidx + tidx];
  	}
  	
   	if ( tidx == 0 )
  		deltalength = vectors[vidx + 4];
    __syncthreads();

	double x,y,z;
	int i;
	
	vectX = smem[0]; vectY = smem[1]; vectZ = smem[2];
	length = smem[3];
	
	sum[tidx] = 0;

    for ( i = tidx+maxdist; i < length; i += MAXTHREADS ){
        x = vectX * i + Sx;
        y = vectY * i + Sy;
        z = vectZ * i + Sz;

        sum[tidx] += (double)tex3D(tex, x+0.5, y+0.5, z+0.5);
    }


    __syncthreads();
    
    if ( tidx < 512 )
    	sum[tidx] += sum[tidx + 512];
    __syncthreads();
    
    if ( tidx < 256 )
    	sum[tidx] += sum[tidx + 256];
    __syncthreads();
    
    if ( tidx < 128 )
    	sum[tidx] += sum[tidx + 128];
    __syncthreads();
    
    if ( tidx < 64 )
    	sum[tidx] += sum[tidx + 64];
    __syncthreads();
   
   if ( tidx < 32 ) warpReduce(sum, tidx);
   
   if ( tidx == 0 ) 
   		detector[idx] += sum[0] * deltalength;
}    
    





int projection(float const * const img, Geometry geo, double** result,double const * const alphas,int nalpha){

   
    // BEFORE DOING ANYTHING: Use the proper CUDA enabled GPU: Tesla K40c
    
    // If you have another GPU and want to use this code, please change it, but make sure you know that is compatible.
    // also change MAXTREADS
    
    int deviceCount = 0;
    cudaGetDeviceCount(&deviceCount);
     if (deviceCount == 0)
    {
        mexErrMsgIdAndTxt("CBCT:CUDA:Ax:cudaGetDeviceCount","No CUDA enabled NVIDIA GPUs found");
    }
    bool found=false;
    for (int dev = 0; dev < deviceCount; ++dev)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        if (strcmp(deviceProp.name, "Tesla K40c") == 0){
            cudaSetDevice(dev);
            found=true;
            break;
        }
    }
    if (!found)
        mexErrMsgIdAndTxt("CBCT:CUDA:Ax:cudaDevice","No Tesla K40c found");
    // DONE, Tesla found

    // copy data to CUDA memory
    cudaArray *d_imagedata = 0;

    const cudaExtent extent = make_cudaExtent(geo.nVoxelX, geo.nVoxelY, geo.nVoxelZ);
    cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaMalloc3DArray(&d_imagedata, &channelDesc, extent);
	cudaCheckErrors("cudaMalloc3D error 3D tex");
    
    cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr((void*)img, extent.width*sizeof(float), extent.width, extent.height);
	copyParams.dstArray = d_imagedata;
	copyParams.extent = extent;
	copyParams.kind = cudaMemcpyHostToDevice;
	cudaMemcpy3D(&copyParams);
    
	cudaCheckErrors("cudaMemcpy3D fail");
    
    // Configure texture options
    tex.normalized = false;
	tex.filterMode = cudaFilterModeLinear;
	tex.addressMode[0] = cudaAddressModeBorder;
	tex.addressMode[1] = cudaAddressModeBorder;
	tex.addressMode[2] = cudaAddressModeBorder;
    
    cudaBindTextureToArray(tex, d_imagedata, channelDesc);    
       
	cudaCheckErrors("3D texture memory bind fail"); 
    

    //Done! Image put into texture memory.
    

    size_t num_bytes = geo.nDetecU*geo.nDetecV * sizeof(double);
    double* dProjection,*dvectors;
    cudaMalloc((void**)&dProjection, num_bytes);
    cudaMalloc((void**)&dvectors, num_bytes * 5);

    cudaCheckErrors("cudaMalloc fail");
    

    Point3D source, deltaU, deltaV, uvOrigin;
    dim3 block1(MAXTHREADS, 1, 1);
    dim3 grid1((geo.nDetecU*geo.nDetecV + MAXTHREADS-1), 1, 1);
    
    dim3 block2(MAXTHREADS, 1, 1);
    dim3 grid2(geo.nDetecU*geo.nDetecV, 1, 1);
    double maxdist;
    for (int i=0;i<nalpha;i++){
        
        geo.alpha=alphas[i];
        //Precompute per angle constant stuff for speed
        maxdist=maxDistanceCubeXY(geo,geo.alpha,i);

        computeDeltas(geo,geo.alpha,i, &uvOrigin, &deltaU, &deltaV, &source);
        computeVectors<<<grid1, block1>>>(geo, dvectors, source, deltaU, deltaV, uvOrigin);
        //Ray tracing!  
        kernelPixelDetector<<<grid2, block2>>>(source, dvectors, dProjection,geo,floor(maxdist));
        
        cudaCheckErrors("Kernel fail");
         // copy result to host
        cudaMemcpy(result[i], dProjection, num_bytes, cudaMemcpyDeviceToHost);
        cudaCheckErrors("cudaMemcpy fail");
        

    }

     cudaUnbindTexture(tex);
     cudaCheckErrors("Unbind  fail");
     
     cudaFree(dProjection);
     cudaFreeArray(d_imagedata);
     cudaCheckErrors("cudaFree d_imagedata fail");


     
     
     
 return 0;   
}




/* This code precomputes The location of the source and the Delta U and delta V (in the warped space) 
 * to compute the locations of the x-rays. While it seems verbose and overly-optimized, 
 * it does saves about 30% of each of the kernel calls. Thats something!
 **/
void computeDeltas(Geometry geo, double alpha,int i, Point3D* uvorigin, Point3D* deltaU, Point3D* deltaV, Point3D* source){
    Point3D S;
    S.x=geo.DSO;
    S.y=0;
    S.z=0;
    
    //End point
    Point3D P,Pu0,Pv0;
    
    P.x  =-(geo.DSD-geo.DSO);   P.y  = geo.dDetecU*(0-(double)(geo.nDetecU/2)+0.5);       P.z  = geo.dDetecV*((double)(geo.nDetecV/2)-0.5-0);
    Pu0.x=-(geo.DSD-geo.DSO);   Pu0.y= geo.dDetecU*(1-(double)(geo.nDetecU/2)+0.5);       Pu0.z= geo.dDetecV*((double)(geo.nDetecV/2)-0.5-0);  
    Pv0.x=-(geo.DSD-geo.DSO);   Pv0.y= geo.dDetecU*(0-(double)(geo.nDetecU/2)+0.5);       Pv0.z= geo.dDetecV*((double)(geo.nDetecV/2)-0.5-1);
    // Geomtric trasnformations:
    
    //1: Offset detector
       
    //P.x
    P.y  =P.y  +geo.offDetecU[i];    P.z  =P.z  +geo.offDetecV[i];
    Pu0.y=Pu0.y+geo.offDetecU[i];    Pu0.z=Pu0.z+geo.offDetecV[i];
    Pv0.y=Pv0.y+geo.offDetecU[i];    Pv0.z=Pv0.z+geo.offDetecV[i];
    //S doesnt need to chagne
    
    
    //3: Rotate (around z)!
    Point3D Pfinal, Pfinalu0, Pfinalv0;  
    
    Pfinal.x  =P.x*cos(geo.alpha)-P.y*sin(geo.alpha);       Pfinal.y  =P.y*cos(geo.alpha)+P.x*sin(geo.alpha);       Pfinal.z  =P.z;
    Pfinalu0.x=Pu0.x*cos(geo.alpha)-Pu0.y*sin(geo.alpha);   Pfinalu0.y=Pu0.y*cos(geo.alpha)+Pu0.x*sin(geo.alpha);   Pfinalu0.z=Pu0.z;
    Pfinalv0.x=Pv0.x*cos(geo.alpha)-Pv0.y*sin(geo.alpha);   Pfinalv0.y=Pv0.y*cos(geo.alpha)+Pv0.x*sin(geo.alpha);   Pfinalv0.z=Pv0.z;
    
    Point3D S2; 
    S2.x=S.x*cos(geo.alpha)-S.y*sin(geo.alpha);
    S2.y=S.y*cos(geo.alpha)+S.x*sin(geo.alpha);
    S2.z=S.z;
    
    //2: Offset image (instead of offseting image, -offset everything else)
    
    Pfinal.x  =Pfinal.x-geo.offOrigX[i];     Pfinal.y  =Pfinal.y-geo.offOrigY[i];     Pfinal.z  =Pfinal.z-geo.offOrigZ[i];
    Pfinalu0.x=Pfinalu0.x-geo.offOrigX[i];   Pfinalu0.y=Pfinalu0.y-geo.offOrigY[i];   Pfinalu0.z=Pfinalu0.z-geo.offOrigZ[i];
    Pfinalv0.x=Pfinalv0.x-geo.offOrigX[i];   Pfinalv0.y=Pfinalv0.y-geo.offOrigY[i];   Pfinalv0.z=Pfinalv0.z-geo.offOrigZ[i];   
    S2.x=S2.x-geo.offOrigX[i];       S2.y=S2.y-geo.offOrigY[i];       S2.z=S2.z-geo.offOrigZ[i];
    
    // As we want the (0,0,0) to be in a corner of the image, we need to translate everything (after rotation);
    Pfinal.x  =Pfinal.x+geo.sVoxelX/2-geo.dVoxelX/2;      Pfinal.y  =Pfinal.y+geo.sVoxelY/2-geo.dVoxelY/2;          Pfinal.z  =Pfinal.z  +geo.sVoxelZ/2-geo.dVoxelZ/2;
    Pfinalu0.x=Pfinalu0.x+geo.sVoxelX/2-geo.dVoxelX/2;    Pfinalu0.y=Pfinalu0.y+geo.sVoxelY/2-geo.dVoxelY/2;        Pfinalu0.z=Pfinalu0.z+geo.sVoxelZ/2-geo.dVoxelZ/2;
    Pfinalv0.x=Pfinalv0.x+geo.sVoxelX/2-geo.dVoxelX/2;    Pfinalv0.y=Pfinalv0.y+geo.sVoxelY/2-geo.dVoxelY/2;        Pfinalv0.z=Pfinalv0.z+geo.sVoxelZ/2-geo.dVoxelZ/2;
    S2.x      =S2.x+geo.sVoxelX/2-geo.dVoxelX/2;          S2.y      =S2.y+geo.sVoxelY/2-geo.dVoxelY/2;              S2.z      =S2.z      +geo.sVoxelZ/2-geo.dVoxelZ/2;
    
    //4. Scale everything so dVoxel==1
    Pfinal.x  =Pfinal.x/geo.dVoxelX;      Pfinal.y  =Pfinal.y/geo.dVoxelY;        Pfinal.z  =Pfinal.z/geo.dVoxelZ;
    Pfinalu0.x=Pfinalu0.x/geo.dVoxelX;    Pfinalu0.y=Pfinalu0.y/geo.dVoxelY;      Pfinalu0.z=Pfinalu0.z/geo.dVoxelZ;
    Pfinalv0.x=Pfinalv0.x/geo.dVoxelX;    Pfinalv0.y=Pfinalv0.y/geo.dVoxelY;      Pfinalv0.z=Pfinalv0.z/geo.dVoxelZ;
    S2.x      =S2.x/geo.dVoxelX;          S2.y      =S2.y/geo.dVoxelY;            S2.z      =S2.z/geo.dVoxelZ;   
    
    // return
    
    *uvorigin=Pfinal;
    
    deltaU->x=Pfinalu0.x-Pfinal.x;
    deltaU->y=Pfinalu0.y-Pfinal.y;
    deltaU->z=Pfinalu0.z-Pfinal.z;
    
    deltaV->x=Pfinalv0.x-Pfinal.x;
    deltaV->y=Pfinalv0.y-Pfinal.y;
    deltaV->z=Pfinalv0.z-Pfinal.z;
    
    *source=S2;
}

double maxDistanceCubeXY(Geometry geo, double alpha,int i){

    ///////////
    // Compute initial "t" so we access safely as less as out of bounds as possible.
    //////////
    
    
    double maxCubX,maxCubY;
    // Forgetting Z, compute mas distance: diagonal+offset
    maxCubX=(geo.sVoxelX/2+ abs(geo.offOrigX[i]))/geo.dVoxelX;
    maxCubY=(geo.sVoxelY/2+ abs(geo.offOrigY[i]))/geo.dVoxelY;

    return geo.DSO/geo.dVoxelX-sqrt(maxCubX*maxCubX+maxCubY*maxCubY);

}



/////////////////////
///////////////////// The code below is not used.
/////////////////////
/////////////////////
/////////////////////
/////////////////////
/////////////////////
/////////////////////
/////////////////////
/////////////////////
// double computeMaxLength(Geometry geo, double alpha){ // Ander: I like alpha as an argument tomake sure the programer puts it in. Explicit call. 
//     
//     //Start point
//     Point3D S;
//     S.x=geo.DSO;
//     S.y=0;
//     S.z=0;
//     
//     //End point
//     Point3D P;
//     P.x=-(geo.DSD-geo.DSO);
//     P.y= geo.dDetecU*(0-(double)(geo.nDetecU/2)+0.5);
//     P.z= geo.dDetecV*((double)(geo.nDetecV/2)+0.5-0);
//     
//     // Geomtric trasnformations:
//     
//     //1: Offset detector
//        
//     //P.x
//     P.y=P.y+geo.offDetecU;
//     P.z=P.z+geo.offDetecV;
//     //S doesnt need to chagne
//     
//     //2: Offset image (instead of offseting image, -offset everything else)
//     
//     P.x=P.x-geo.offOrigX;
//     P.y=P.y-geo.offOrigY;
//     P.z=P.z-geo.offOrigZ;
//     
//     S.x=S.x-geo.offOrigX;
//     S.y=S.y-geo.offOrigY;
//     S.z=S.z-geo.offOrigZ;
//     
//     //3: Rotate (around z)!
//     Point3D P2;   
//     P2.x=P.x*cos(alpha)-P.y*sin(alpha);
//     P2.y=P.y*cos(alpha)+P.x*sin(alpha);
//     P2.z=P.z;
//     Point3D S2; 
//     S2.x=S.x*cos(alpha)-S.y*sin(alpha);
//     S2.y=S.y*cos(alpha)+S.x*sin(alpha);
//     S2.z=S.z;
//     // As we want the (0,0,0) to be in a corner of the image, we need to translate everything (after rotation);
//     P2.x=P2.x+geo.sVoxelX/2;
//     P2.y=P2.y+geo.sVoxelY/2;
//     P2.z=P2.z+geo.sVoxelZ/2;
//     
//     S2.x=S2.x+geo.sVoxelX/2;
//     S2.y=S2.y+geo.sVoxelY/2;
//     S2.z=S2.z+geo.sVoxelZ/2;
//     
//     //4. Scale everything so dVoxel==1
//     P2.x=P2.x/geo.dVoxelX;
//     P2.y=P2.y/geo.dVoxelY;
//     P2.z=P2.z/geo.dVoxelZ;
//     S2.x=S2.x/geo.dVoxelX;
//     S2.y=S2.y/geo.dVoxelY;
//     S2.z=S2.z/geo.dVoxelZ;
//     
//     
//     return sqrt((P2.x-S2.x)*(P2.x-S2.x)   +    (P2.y-S2.y)*(P2.y-S2.y) +(P2.z-S2.z)*(P2.z-S2.z) );
// }
// // This function scales the geometrical data so all the image voxels are 1x1x1
// Geometry nomralizeGeometryImage(Geometry geo){
//     
//     Geometry nGeo; //Normalized geometry
//     //Copy input values
//     nGeo=geo;
//     
//     // This is why we are doing this stuff
//     nGeo.dVoxelX=1;
//     nGeo.dVoxelY=1;
//     nGeo.dVoxelZ=1;
//     // Change total size
//     nGeo.sVoxelX=geo.sVoxelX/geo.dVoxelX; //This shoudl be == geo.nVoxelX;
//     nGeo.sVoxelY=geo.sVoxelY/geo.dVoxelY; //This shoudl be == geo.nVoxelY;
//     nGeo.sVoxelZ=geo.sVoxelZ/geo.dVoxelZ; //This shoudl be == geo.nVoxelZ;
//     
//     // As in the beggining U is alinged with Y and V with Z, they also need to be modified.
//     
//     nGeo.dDetecU=geo.dDetecU/geo.dVoxelY;
//     nGeo.dDetecV=geo.dDetecV/geo.dVoxelZ;
// 
//     //Modify DSO and DSD w.r.t. X
//     
//     nGeo.DSO=geo.DSO/geo.dVoxelX;
//     nGeo.DSD=geo.DSD/geo.dVoxelX;
//     
//     // The new "units" have this real size
//     nGeo.unitX=geo.dVoxelX;
//     nGeo.unitY=geo.dVoxelY;
//     nGeo.unitZ=geo.dVoxelZ;
// 
//     //Compute maxlength
//     nGeo.maxLength=sqrt(nGeo.DSD*nGeo.DSD+sqrt(nGeo.sDetecU/2*nGeo.sDetecU/2+nGeo.sDetecV/2*nGeo.sDetecV/2));
// 
//     return nGeo;
//     
// }