#include <iostream>
#include <cuda.h>
#include <cuda_runtime.h>
#include "utils.h"
#include "loadSaveImage.h"

//chroma-LogLuminance Space
static float *d_x__;
static float *d_y__;
static float *d_logY__;

//memory for the cdf
static unsigned int *d_cdf__;

static const int numBins = 1024;

size_t numRows__;
size_t numCols__;


/* Copied from Mike's IPython notebook *
   Modified just by having threads read the 
   normalization constant directly from device memory
   instead of copying it back                          */


__global__ void normalize_cdf(
	unsigned int* 	d_input_cdf,
	float*			d_output_cdf,
	int				n
	)
{
	const float normalization_constant = 1.f / d_input_cdf[n-1];

	int global_index_1d = ( blockIdx.x * blockDim.x) + threadIdx.x;
	
	if (global_index_1d < n) {
		unsigned int input_value = d_input_cdf[ global_index_1d ];
		float output_value = input_value * normalization_constant;
		d_output_cdf[ global_index_1d] = output_value;
	}
}


/* Copied from Mike's IPython notebook *
   Modified double constants -> float  *
   Perform tone mapping based upon new *
   luminance scaling                   */

/* - normalize cdf
 * - 
 */
__global__ void tonemap(
    float* d_x,
    float* d_y,
    float* d_log_Y,
    float* d_cdf_norm,
    float* d_r_new,
    float* d_g_new,
    float* d_b_new,
    float  min_log_Y,
    float  max_log_Y,
    float  log_Y_range,
    int    num_bins,
    int    num_pixels_y,
    int    num_pixels_x )
{
	int  ny             = num_pixels_y;
	int  nx             = num_pixels_x;
	int2 image_index_2d = make_int2( ( blockIdx.x * blockDim.x ) + threadIdx.x, ( blockIdx.y * blockDim.y ) + threadIdx.y );
	int  image_index_1d = ( nx * image_index_2d.y ) + image_index_2d.x;

	if ( image_index_2d.x < nx && image_index_2d.y < ny )
	{
		float x         = d_x[ image_index_1d ];
		float y         = d_y[ image_index_1d ];
		float log_Y     = d_log_Y[ image_index_1d ];
		int   bin_index = min( num_bins - 1, int( (num_bins * ( log_Y - min_log_Y ) ) / log_Y_range ) );
		float Y_new     = d_cdf_norm[ bin_index ];

		float X_new = x * ( Y_new / y );
		float Z_new = ( 1 - x - y ) * ( Y_new / y );

		float r_new = ( X_new *  3.2406f ) + ( Y_new * -1.5372f ) + ( Z_new * -0.4986f );
		float g_new = ( X_new * -0.9689f ) + ( Y_new *  1.8758f ) + ( Z_new *  0.0415f );
		float b_new = ( X_new *  0.0557f ) + ( Y_new * -0.2040f ) + ( Z_new *  1.0570f );

		d_r_new[ image_index_1d] = r_new;
		d_g_new[ image_index_1d] = g_new;
		d_b_new[ image_index_1d] = b_new;
	}
}




/* - read RGB image and
 * - transform AoS (array of structures) to SoA (structure of arrays)
 * - use GPU to convert RGB to xyY format
 * - allocate CPU and GPU memory
 */
void preProcessGPU(float** d_luminance, unsigned int** d_cdf,
				std::size_t *numRows, std::size_t *numCols,
				unsigned int *numberOfBins,
				const std::string &filename)
{
	// make sure the context intitalizes ok
	checkCudaErrors(cudaFree(0));

  float *imgPtr; //we will become responsible for this pointer
  loadImageHDR(filename, &imgPtr, &numRows__, &numCols__);
  *numRows = numRows__;
  *numCols = numCols__;

  // Before using GPU, transform array of structures (AoS) to sturcture of arrays (SoA)
  //first thing to do is split incoming BGR float data into separate channels
  size_t numPixels = numRows__ * numCols__;
  float *red   = new float[numPixels];
  float *green = new float[numPixels];
  float *blue  = new float[numPixels];

  //Remeber image is loaded BGR
  for (size_t i = 0; i < numPixels; ++i) {
    blue[i]  = imgPtr[3 * i + 0];
    green[i] = imgPtr[3 * i + 1];
    red[i]   = imgPtr[3 * i + 2];
  }

  delete[] imgPtr; //being good citizens are releasing resources
                   //allocated in loadImageHDR

  float *d_red, *d_green, *d_blue;  //RGB space

  size_t channelSize = sizeof(float) * numPixels;

  checkCudaErrors(cudaMalloc(&d_red,    channelSize));
  checkCudaErrors(cudaMalloc(&d_green,  channelSize));
  checkCudaErrors(cudaMalloc(&d_blue,   channelSize));
  checkCudaErrors(cudaMalloc(&d_x__,    channelSize));
  checkCudaErrors(cudaMalloc(&d_y__,    channelSize));
  checkCudaErrors(cudaMalloc(&d_logY__, channelSize));

  checkCudaErrors(cudaMemcpy(d_red,   red,   channelSize, cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(d_green, green, channelSize, cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(d_blue,  blue,  channelSize, cudaMemcpyHostToDevice));

	// convert from RGB space to chrominance/luminance space xyY
	const dim3 blockSize(32, 16, 1);
	const dim3 gridSize( (numCols__ - 1) / blockSize.x + 1,
						 (numRows__ - 1) / blockSize.y + 1, 1);
	rgb_to_xyY<<<gridSize, blockSize>>>(d_red, d_green, d_blue,
										d_x__, d_y__, d_logY__,
										.0001f, numRows__, numCols__);

	cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

	*d_luminance = d_logY__;
	
	// allocate memory for the cdf of the histogram
	*numberOfBins = numBins;
	checkCudaErrors(cudaMalloc(&d_cdf__, sizeof(unsigned int) * numBins));
	checkCudaErrors(cudaMemset(d_cdf__, 0, sizeof(unsigned int) * numBins));
	*d_cdf = d_cdf__;

  checkCudaErrors(cudaFree(d_red));
  checkCudaErrors(cudaFree(d_green));
  checkCudaErrors(cudaFree(d_blue));

	delete[] red;
	delete[] green;
	delete[] blue;
}


void postProcessGPU(const std::string& output_file, 
                 size_t numRows, size_t numCols,
                 float min_log_Y, float max_log_Y) {
  const int numPixels = numRows__ * numCols__;

  const int numThreads = 192;

  float *d_cdf_normalized;

  checkCudaErrors(cudaMalloc(&d_cdf_normalized, sizeof(float) * numBins));

	// first normalize the cdf to a maximum value of 1
	// this is how we compress the range of the luminance channel
	normalize_cdf<<< (numBins - 1) / numThreads + 1,
					numThreads>>> (d_cdf__,
					d_cdf_normalized,
					numBins);

  cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

  //allocate memory for the output RGB channels
  float *h_red, *h_green, *h_blue;
  float *d_red, *d_green, *d_blue;

  h_red   = new float[numPixels];
  h_green = new float[numPixels];
  h_blue  = new float[numPixels];

  checkCudaErrors(cudaMalloc(&d_red,   sizeof(float) * numPixels));
  checkCudaErrors(cudaMalloc(&d_green, sizeof(float) * numPixels));
  checkCudaErrors(cudaMalloc(&d_blue,  sizeof(float) * numPixels));

  float log_Y_range = max_log_Y - min_log_Y;

	const dim3 blockSize(32, 16, 1);
	const dim3 gridSize( (numCols - 1) / blockSize.x + 1,
						 (numRows - 1) / blockSize.y + 1);
	// next perform the actual tone-mapping
	// map each luminance value to its new value
	// and then transform back to RGB space
	tonemap<<<gridSize, blockSize>>>(d_x__, d_y__, d_logY__,
									d_cdf_normalized,
									d_red, d_green, d_blue,
									min_log_Y, max_log_Y,
									log_Y_range, numBins,
									numRows, numCols);
  cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

  checkCudaErrors(cudaMemcpy(h_red,   d_red,   sizeof(float) * numPixels, cudaMemcpyDeviceToHost));
  checkCudaErrors(cudaMemcpy(h_green, d_green, sizeof(float) * numPixels, cudaMemcpyDeviceToHost));
  checkCudaErrors(cudaMemcpy(h_blue,  d_blue,  sizeof(float) * numPixels, cudaMemcpyDeviceToHost));

  //recombine the image channels
  float *imageHDR = new float[numPixels * 3];

  for (int i = 0; i < numPixels; ++i) {
    imageHDR[3 * i + 0] = h_blue[i];
    imageHDR[3 * i + 1] = h_green[i];
    imageHDR[3 * i + 2] = h_red[i];
  }

  saveImageHDR(imageHDR, numRows, numCols, output_file);

  delete[] imageHDR;
  delete[] h_red;
  delete[] h_green;
  delete[] h_blue;

  //cleanup
  checkCudaErrors(cudaFree(d_cdf_normalized));
}

void cleanupGlobalMemory(void)
{
  checkCudaErrors(cudaFree(d_x__));
  checkCudaErrors(cudaFree(d_y__));
  checkCudaErrors(cudaFree(d_logY__));
  checkCudaErrors(cudaFree(d_cdf__));
}