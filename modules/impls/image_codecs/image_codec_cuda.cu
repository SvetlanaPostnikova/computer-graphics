#include "image_codec.h"
#include "nvjpeg.h"
#include <fstream>

cudaStream_t stream;
nvjpegHandle_t nv_handle;

nvjpegJpegState_t nvjpeg_decoder_state;

nvjpegEncoderState_t nv_enc_state;
nvjpegEncoderParams_t nv_enc_params;

/// @brief for debug
nvjpegStatus_t last_status = (nvjpegStatus_t)-1;
cudaError_t last_error = (cudaError_t)-1;
std::string last_error_desc = "";

void cuda_log(nvjpegStatus_t status)
{
    last_status = status;
}

void cuda_log(cudaError_t status)
{
    last_error = status;
    last_error_desc = cudaGetErrorString(status);
}

image_codec::image_codec()
{
    //THREAD SAFE
    //cuda stream that stores order of operations on GPU
    cuda_log(cudaStreamCreate(&stream));
    //library handle
    cuda_log(nvjpegCreateSimple(&nv_handle));

    //NOT THREAD SAFE
    //nvjpeg encoding
    cuda_log(nvjpegEncoderStateCreate(nv_handle, &nv_enc_state, stream));
    cuda_log(nvjpegEncoderParamsCreate(nv_handle, &nv_enc_params, stream));

    // set the highest quality
    cuda_log(nvjpegEncoderParamsSetQuality(nv_enc_params, 100, stream));

    //use the best type of JPEG encoding
    cuda_log(nvjpegEncoderParamsSetEncoding(nv_enc_params, nvjpegJpegEncoding_t::NVJPEG_ENCODING_LOSSLESS_HUFFMAN, stream));

    //nvjpeg decoding
    cuda_log(nvjpegJpegStateCreate(nv_handle, &nvjpeg_decoder_state));
}

void image_codec::encode(std::vector<unsigned char>* img_source, matrix* img_matrix, ImageColorScheme colorScheme, unsigned bit_depth)
{
    // code taken from example: https://docs.nvidia.com/cuda/nvjpeg/index.html#nvjpeg-encode-examples

    nvjpegImage_t nv_image;
    //Pitch represents bytes per row
    size_t pitch_0_size = img_matrix->width;

    if (colorScheme == ImageColorScheme::IMAGE_RGB)
    {
        // This has to be done, default params are not sufficient
        // source: https://stackoverflow.com/questions/65929613/nvjpeg-encode-packed-bgr
        cuda_log(nvjpegEncoderParamsSetSamplingFactors(nv_enc_params, NVJPEG_CSS_444, stream));

        pitch_0_size *= 3;
    }
    else
    {
        cuda_log(nvjpegEncoderParamsSetSamplingFactors(nv_enc_params, NVJPEG_CSS_GRAY, stream));
    }

    // Fill nv_image with image data, by copying data from matrix to GPU
    // docs about nv_image: https://docs.nvidia.com/cuda/nvjpeg/index.html#nvjpeg-encode-examples
    cuda_log(cudaMalloc((void **)&(nv_image.channel[0]), pitch_0_size * img_matrix->height));
    cuda_log(cudaMemcpy(nv_image.channel[0], img_matrix->array.data(), pitch_0_size * img_matrix->height, cudaMemcpyHostToDevice));
    
    nv_image.pitch[0] = pitch_0_size;

    // Compress image
    if (colorScheme == ImageColorScheme::IMAGE_RGB)
    {
        cuda_log(nvjpegEncodeImage(nv_handle, nv_enc_state, nv_enc_params,
            &nv_image, nvjpegInputFormat_t::NVJPEG_INPUT_RGBI, img_matrix->width, img_matrix->height, stream));   
    }
    else
    {
        cuda_log(nvjpegEncodeYUV(nv_handle, nv_enc_state, nv_enc_params,
            &nv_image, nvjpegChromaSubsampling_t::NVJPEG_CSS_GRAY, img_matrix->width, img_matrix->height, stream));
    }

    // get compressed stream size
    size_t length = 0;
    cuda_log(nvjpegEncodeRetrieveBitstream(nv_handle, nv_enc_state, NULL, &length, stream));
    // get stream itself
    cuda_log(cudaStreamSynchronize(stream));
    img_source->clear();
    img_source->resize(length);
    cuda_log(nvjpegEncodeRetrieveBitstream(nv_handle, nv_enc_state, img_source->data(), &length, 0));

    cuda_log(cudaStreamSynchronize(stream));

    //clean up
    cuda_log(cudaFree(nv_image.channel[0]));
}

bool is_interleaved(nvjpegOutputFormat_t)
{
    return true;
}

void image_codec::decode(std::vector<unsigned char>* img_source, matrix* img_matrix, ImageColorScheme colorScheme, unsigned bit_depth)
{
    // Decode, Encoder format
    nvjpegOutputFormat_t oformat = NVJPEG_OUTPUT_RGBI;

    // Image buffers. 
    unsigned char * pBuffer = NULL; 
    
    unsigned char * dpImage = (unsigned char *)img_source->data();
    size_t nSize = img_source->size();
    
    // Retrieve the componenet and size info.
    int nComponent = 0;
    nvjpegChromaSubsampling_t subsampling;
    int widths[NVJPEG_MAX_COMPONENT];
    int heights[NVJPEG_MAX_COMPONENT];

    cuda_log(nvjpegGetImageInfo(nv_handle, dpImage, nSize, &nComponent, &subsampling, widths, heights));

    // image resize
    size_t pitchDesc;

    // device image buffers.
    nvjpegImage_t imgDesc;

    if (is_interleaved(oformat))
    {
        pitchDesc = nComponent * widths[0];
    }
    else
    {
        pitchDesc = 3 * widths[0];
    }

    cuda_log(cudaMalloc(&pBuffer, pitchDesc * heights[0]));

    imgDesc.channel[0] = pBuffer;
    imgDesc.channel[1] = pBuffer + widths[0] * heights[0];
    imgDesc.channel[2] = pBuffer + widths[0] * heights[0] * 2;
    imgDesc.pitch[0] = (unsigned int)(is_interleaved(oformat) ? widths[0] * nComponent : widths[0]);
    imgDesc.pitch[1] = (unsigned int)widths[0];
    imgDesc.pitch[2] = (unsigned int)widths[0];

    if (is_interleaved(oformat))
    {
        imgDesc.channel[3] = pBuffer + widths[0] * heights[0] * 3;
        imgDesc.pitch[3] = (unsigned int)widths[0];
    }

    // decode by stages
    cuda_log(nvjpegDecode(nv_handle, nvjpeg_decoder_state, dpImage, nSize, oformat, &imgDesc, NULL));

    img_matrix->array.resize(pitchDesc * heights[0]);
    unsigned char* result = new unsigned char[pitchDesc * heights[0]];

    cuda_log(cudaMemcpy(img_matrix->array.data(), pBuffer, pitchDesc * heights[0], cudaMemcpyKind::cudaMemcpyDeviceToHost));

    img_matrix->height = heights[0];
    img_matrix->width = widths[0];
}

void image_codec::load_image_file(std::vector<unsigned char>* img_buff, std::string image_filepath)
{
    std::ifstream oInputStream(image_filepath, std::ios::in | std::ios::binary | std::ios::ate);
    if(!(oInputStream.is_open()))
    {
        return;
    }

    // Get the size.
    std::streamsize nSize = oInputStream.tellg();
    oInputStream.seekg(0, std::ios::beg);
    
    img_buff->resize(nSize);
    oInputStream.read((char*)img_buff->data(), nSize);

    oInputStream.close();
}
        
void image_codec::save_image_file(std::vector<unsigned char>* img_buff, std::string image_filepath)
{
    std::ofstream output_file(image_filepath+".jpeg", std::ios::out | std::ios::binary);
    output_file.write((char *)img_buff->data(), img_buff->size());
    output_file.close();
}

image_codec::~image_codec()
{
    if (nv_enc_params != nullptr)
    {
        cuda_log(nvjpegEncoderParamsDestroy(nv_enc_params));
        nv_enc_params = nullptr;
    }
    
    if (nv_enc_state != nullptr)
    {
        cuda_log(nvjpegEncoderStateDestroy(nv_enc_state));
        nv_enc_state = nullptr;
    }

    if (nv_handle != nullptr)
    {
        cuda_log(nvjpegDestroy(nv_handle));
        nv_handle = nullptr;
    }

    if (stream != nullptr)
    {
        cuda_log(cudaStreamDestroy(stream));
        stream = nullptr;
    }
}
