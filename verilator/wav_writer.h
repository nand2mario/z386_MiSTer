#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>

class WAVWriter {
private:
	FILE* file = nullptr;
	uint32_t data_size = 0;
	uint32_t sample_rate = 0;
	uint16_t channels = 0;
	uint16_t bits_per_sample = 0;

	struct WAVHeader {
		char riff_id[4];
		uint32_t riff_size;
		char wave_id[4];
		char fmt_id[4];
		uint32_t fmt_size;
		uint16_t format;
		uint16_t channels;
		uint32_t sample_rate;
		uint32_t byte_rate;
		uint16_t block_align;
		uint16_t bits_per_sample;
		char data_id[4];
		uint32_t data_size;
	};

	void write_header() {
		if (!file) return;

		WAVHeader header{};
		memcpy(header.riff_id, "RIFF", 4);
		header.riff_size = 36 + data_size;
		memcpy(header.wave_id, "WAVE", 4);
		memcpy(header.fmt_id, "fmt ", 4);
		header.fmt_size = 16;
		header.format = 1;
		header.channels = channels;
		header.sample_rate = sample_rate;
		header.byte_rate = sample_rate * channels * bits_per_sample / 8;
		header.block_align = channels * bits_per_sample / 8;
		header.bits_per_sample = bits_per_sample;
		memcpy(header.data_id, "data", 4);
		header.data_size = data_size;
		fwrite(&header, sizeof(header), 1, file);
	}

public:
	WAVWriter(const char* filename, uint32_t rate, uint16_t channel_count, uint16_t bits)
		: sample_rate(rate), channels(channel_count), bits_per_sample(bits) {
		file = fopen(filename, "wb");
		if (!file) {
			printf("Error: could not open WAV file %s for writing\n", filename);
			return;
		}
		write_header();
	}

	~WAVWriter() {
		if (!file) return;
		fseek(file, 0, SEEK_SET);
		write_header();
		fclose(file);
		printf("WAV file closed: %u samples written (%.2f seconds)\n",
		       data_size / (channels * bits_per_sample / 8),
		       static_cast<double>(data_size) / (channels * bits_per_sample / 8) / sample_rate);
	}

	void write_sample(int16_t left, int16_t right) {
		if (!file) return;
		fwrite(&left, sizeof(left), 1, file);
		fwrite(&right, sizeof(right), 1, file);
		data_size += 4;
	}
};
