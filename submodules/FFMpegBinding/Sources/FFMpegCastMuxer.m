#import <FFMpegBinding/FFMpegCastMuxer.h>

#include "libavutil/audio_fifo.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswresample/swresample.h"

static const int kCastAudioSampleRate = 48000;

@implementation FFMpegCastMuxer {
    AVCodecContext *_encoder;
    AVCodecContext *_decoder;
    SwrContext *_resampler;
    AVAudioFifo *_fifo;
    AVFrame *_decodedFrame;
    int64_t _nextAudioPts;
    int _lastIndex;
    bool _hasLastIndex;
}

- (void)dealloc {
    if (_encoder) {
        avcodec_free_context(&_encoder);
    }
    if (_decoder) {
        avcodec_free_context(&_decoder);
    }
    if (_resampler) {
        swr_free(&_resampler);
    }
    if (_fifo) {
        av_audio_fifo_free(_fifo);
    }
    if (_decodedFrame) {
        av_frame_free(&_decodedFrame);
    }
}

- (bool)prepareEncoder {
    if (_encoder) {
        return true;
    }
    const AVCodec *codec = avcodec_find_encoder_by_name("aac_at");
    if (!codec) {
        return false;
    }
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    if (!encoder) {
        return false;
    }
    av_channel_layout_default(&encoder->ch_layout, 2);
    encoder->sample_rate = kCastAudioSampleRate;
    encoder->sample_fmt = AV_SAMPLE_FMT_S16;
    encoder->bit_rate = 128000;
    encoder->time_base = (AVRational){ 1, kCastAudioSampleRate };
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(encoder, codec, NULL) < 0) {
        avcodec_free_context(&encoder);
        return false;
    }
    _fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_S16, 2, kCastAudioSampleRate);
    _decodedFrame = av_frame_alloc();
    if (!_fifo || !_decodedFrame) {
        avcodec_free_context(&encoder);
        return false;
    }
    _encoder = encoder;
    return true;
}

- (bool)prepareDecoderWithParameters:(const AVCodecParameters *)parameters {
    if (_decoder) {
        return true;
    }
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec) {
        return false;
    }
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    if (!decoder) {
        return false;
    }
    if (avcodec_parameters_to_context(decoder, parameters) < 0 || avcodec_open2(decoder, codec, NULL) < 0) {
        avcodec_free_context(&decoder);
        return false;
    }
    _decoder = decoder;
    return true;
}

- (bool)prepareResamplerForFrame:(const AVFrame *)frame {
    if (_resampler) {
        return true;
    }
    AVChannelLayout inputLayout = { 0 };
    if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
        av_channel_layout_default(&inputLayout, frame->ch_layout.nb_channels);
    } else if (av_channel_layout_copy(&inputLayout, &frame->ch_layout) < 0) {
        return false;
    }
    int result = swr_alloc_set_opts2(&_resampler, &_encoder->ch_layout, AV_SAMPLE_FMT_S16, kCastAudioSampleRate, &inputLayout, frame->format, frame->sample_rate, 0, NULL);
    av_channel_layout_uninit(&inputLayout);
    if (result < 0 || swr_init(_resampler) < 0) {
        swr_free(&_resampler);
        return false;
    }
    return true;
}

- (void)queueDecodedFrame:(const AVFrame *)frame {
    if (![self prepareResamplerForFrame:frame]) {
        return;
    }
    int capacity = swr_get_out_samples(_resampler, frame->nb_samples);
    if (capacity <= 0) {
        return;
    }
    uint8_t *samples = NULL;
    if (av_samples_alloc(&samples, NULL, 2, capacity, AV_SAMPLE_FMT_S16, 0) < 0) {
        return;
    }
    int converted = swr_convert(_resampler, &samples, capacity, (const uint8_t * const *)frame->extended_data, frame->nb_samples);
    if (converted > 0) {
        void *data = samples;
        av_audio_fifo_write(_fifo, &data, converted);
    }
    av_freep(&samples);
}

// Returns the number of samples the file added.
- (int)queueAudioFromPath:(NSString *)path {
    int before = av_audio_fifo_size(_fifo);
    AVFormatContext *input = NULL;
    // The container is probed: Telegram sends a stream's separate audio as MP4.
    if (avformat_open_input(&input, path.UTF8String, NULL, NULL) < 0) {
        return 0;
    }
    int streamIndex = -1;
    if (avformat_find_stream_info(input, NULL) >= 0) {
        for (unsigned int i = 0; i < input->nb_streams; i++) {
            if (input->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                streamIndex = (int)i;
                break;
            }
        }
    }
    if (streamIndex >= 0 && [self prepareDecoderWithParameters:input->streams[streamIndex]->codecpar]) {
        AVPacket *packet = av_packet_alloc();
        while (packet && av_read_frame(input, packet) >= 0) {
            if (packet->stream_index == streamIndex && avcodec_send_packet(_decoder, packet) >= 0) {
                while (avcodec_receive_frame(_decoder, _decodedFrame) >= 0) {
                    [self queueDecodedFrame:_decodedFrame];
                    av_frame_unref(_decodedFrame);
                }
            }
            av_packet_unref(packet);
        }
        av_packet_free(&packet);
    }
    avformat_close_input(&input);
    return av_audio_fifo_size(_fifo) - before;
}

- (void)queueSilenceSamples:(int)count {
    if (count <= 0) {
        return;
    }
    uint8_t *samples = NULL;
    if (av_samples_alloc(&samples, NULL, 2, count, AV_SAMPLE_FMT_S16, 0) < 0) {
        return;
    }
    av_samples_set_silence(&samples, 0, count, 2, AV_SAMPLE_FMT_S16);
    void *data = samples;
    av_audio_fifo_write(_fifo, &data, count);
    av_freep(&samples);
}

- (void)writeEncodedPacketsTo:(AVFormatContext *)output stream:(AVStream *)stream {
    AVPacket *packet = av_packet_alloc();
    while (packet && avcodec_receive_packet(_encoder, packet) >= 0) {
        av_packet_rescale_ts(packet, _encoder->time_base, stream->time_base);
        packet->stream_index = stream->index;
        av_interleaved_write_frame(output, packet);
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
}

- (void)encodeQueuedAudioTo:(AVFormatContext *)output stream:(AVStream *)stream {
    int frameSize = _encoder->frame_size > 0 ? _encoder->frame_size : 1024;
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        return;
    }
    while (av_audio_fifo_size(_fifo) >= frameSize) {
        frame->nb_samples = frameSize;
        frame->format = AV_SAMPLE_FMT_S16;
        frame->sample_rate = kCastAudioSampleRate;
        if (av_channel_layout_copy(&frame->ch_layout, &_encoder->ch_layout) < 0 || av_frame_get_buffer(frame, 0) < 0) {
            break;
        }
        av_audio_fifo_read(_fifo, (void **)frame->data, frameSize);
        frame->pts = _nextAudioPts;
        _nextAudioPts += frameSize;
        if (avcodec_send_frame(_encoder, frame) >= 0) {
            [self writeEncodedPacketsTo:output stream:stream];
        }
        av_frame_unref(frame);
    }
    av_frame_free(&frame);
}

- (bool)muxVideoPath:(NSString *)videoPath audioPath:(NSString *)audioPath to:(NSString *)outPath index:(int)index offsetSeconds:(double)offsetSeconds {
    if (![self prepareEncoder]) {
        return false;
    }
    AVFormatContext *input = NULL;
    AVFormatContext *output = NULL;
    AVPacket *packet = NULL;
    int videoStreamIndex = -1;
    bool success = false;

    if (avformat_open_input(&input, videoPath.UTF8String, av_find_input_format("mp4"), NULL) < 0) {
        goto end;
    }
    if (avformat_find_stream_info(input, NULL) < 0) {
        goto end;
    }
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        if (input->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            videoStreamIndex = (int)i;
            break;
        }
    }
    if (videoStreamIndex < 0) {
        goto end;
    }
    if (avformat_alloc_output_context2(&output, NULL, "mpegts", outPath.UTF8String) < 0 || !output) {
        goto end;
    }

    AVStream *videoInput = input->streams[videoStreamIndex];
    AVStream *videoOutput = avformat_new_stream(output, NULL);
    AVStream *audioOutput = avformat_new_stream(output, NULL);
    if (!videoOutput || !audioOutput) {
        goto end;
    }
    if (avcodec_parameters_copy(videoOutput->codecpar, videoInput->codecpar) < 0) {
        goto end;
    }
    videoOutput->time_base = videoInput->time_base;
    if (avcodec_parameters_from_context(audioOutput->codecpar, _encoder) < 0) {
        goto end;
    }
    audioOutput->time_base = _encoder->time_base;

    if (avio_open(&output->pb, outPath.UTF8String, AVIO_FLAG_WRITE) < 0) {
        goto end;
    }
    if (avformat_write_header(output, NULL) < 0) {
        goto end;
    }

    // A gap in the indices breaks the audio timeline, so it restarts from this segment's time.
    if (!_hasLastIndex || index != _lastIndex + 1) {
        _nextAudioPts = (int64_t)(offsetSeconds * kCastAudioSampleRate);
        av_audio_fifo_reset(_fifo);
    }
    _hasLastIndex = true;
    _lastIndex = index;

    packet = av_packet_alloc();
    if (!packet) {
        goto end;
    }
    int64_t videoOffset = av_rescale_q((int64_t)(offsetSeconds * 1000.0), (AVRational){ 1, 1000 }, videoOutput->time_base);
    while (av_read_frame(input, packet) >= 0) {
        if (packet->stream_index == videoStreamIndex) {
            av_packet_rescale_ts(packet, videoInput->time_base, videoOutput->time_base);
            packet->pts += videoOffset;
            packet->dts += videoOffset;
            packet->pos = -1;
            packet->stream_index = videoOutput->index;
            av_interleaved_write_frame(output, packet);
        }
        av_packet_unref(packet);
    }

    int added = audioPath ? [self queueAudioFromPath:audioPath] : 0;
    // Exactly one second per segment, or audio drifts from the video it was paired with.
    if (added < kCastAudioSampleRate) {
        [self queueSilenceSamples:kCastAudioSampleRate - added];
    } else if (added > kCastAudioSampleRate) {
        av_audio_fifo_drain(_fifo, added - kCastAudioSampleRate);
    }
    [self encodeQueuedAudioTo:output stream:audioOutput];

    av_write_trailer(output);
    success = true;

end:
    if (packet) {
        av_packet_free(&packet);
    }
    if (input) {
        avformat_close_input(&input);
    }
    if (output) {
        if (output->pb) {
            avio_closep(&output->pb);
        }
        avformat_free_context(output);
    }
    return success;
}

@end
