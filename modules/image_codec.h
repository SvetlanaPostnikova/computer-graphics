#include <string>
#include <vector>
#include "image_tools.h"

enum ImageColorScheme{
    IMAGE_GRAY,
    IMAGE_RGB
};

void encode(std::vector<unsigned char>* img_source, matrix* img_matrix, ImageColorScheme colorScheme, unsigned bit_depth);

void decode(std::vector<unsigned char>* img_source, matrix* img_matrix, ImageColorScheme colorScheme, unsigned bit_depth);

void load_image_file(std::vector<unsigned char>* png_buffer, std::string image_filepath);

/// @brief Saves image to file
/// @param png_buffer image data
/// @param image_filepath filepath, without extension
void save_image_file(std::vector<unsigned char>* png_buffer, std::string image_filepath);
