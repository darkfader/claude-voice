#pragma once

// Push-to-talk: while the center button is held (see overlay.yaml's
// claude_ptt_hold_check / claude_ptt_release scripts), stream raw 16kHz
// mono PCM over UDP straight to the desktop dictation service, bypassing
// HA's Assist/Wyoming pipeline entirely.
//
// Reuses esphome::microphone::MicrophoneSource for the 32bit-stereo ->
// 16bit-mono conversion instead of hand-rolling bit-shifting here -- this
// is the exact same conversion path voice_assistant/micro_wake_word already
// rely on for i2s_mics, so it's proven rather than a second, untested
// implementation of the same math. `passive=false` means the conversion
// (and our UDP send) only runs between start()/stop(), even though the
// underlying i2s_mics keeps running continuously for wake-word detection.
//
// The socket is opened in start() and closed in stop() rather than kept
// open for the device's lifetime: PTT is a bursty, operator-held gesture,
// not a long-lived connection, and dropping the fd between presses avoids
// holding an ESP32 socket slot (FD_SETSIZE is 10) for a stream that is idle
// the overwhelming majority of the time.

#include "esphome/components/microphone/microphone_source.h"
#include "esphome/components/socket/socket.h"
#include "esphome/core/log.h"

#include <memory>
#include <string>

namespace claude_ptt {

static const char *const TAG = "claude_ptt";

class UdpPushToTalk {
 public:
  UdpPushToTalk(esphome::microphone::Microphone *mic, std::string host, uint16_t port)
      : host_(std::move(host)), port_(port), source_(mic, /*bits_per_sample=*/16, /*gain_factor=*/1, /*passive=*/false) {
    this->source_.add_channel(0);
    this->source_.add_data_callback([this](const std::vector<uint8_t> &data) { this->on_audio_(data); });
  }

  void start() {
    if (this->running_) {
      return;
    }
    this->socket_ = esphome::socket::socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (!this->socket_) {
      ESP_LOGE(TAG, "Could not create UDP socket");
      return;
    }
    if (this->socket_->setblocking(false) != 0) {
      ESP_LOGE(TAG, "Could not set UDP socket non-blocking");
      this->socket_.reset();
      return;
    }
    this->dest_len_ = esphome::socket::set_sockaddr((struct sockaddr *) &this->dest_addr_, sizeof(this->dest_addr_),
                                                      this->host_, this->port_);
    if (this->dest_len_ == 0) {
      ESP_LOGE(TAG, "Could not resolve PTT target %s:%u", this->host_.c_str(), this->port_);
      this->socket_.reset();
      return;
    }
    this->running_ = true;
    this->source_.start();
  }

  void stop() {
    if (!this->running_) {
      return;
    }
    this->running_ = false;
    this->source_.stop();
    if (this->socket_) {
      // 1-byte end-of-utterance marker, distinguishable from real audio
      // (every PCM packet MicrophoneSource hands us is a batch of 16-bit
      // samples, always >=2 bytes). Without this the receiver has to guess
      // where an utterance ends purely from a gap between packets -- which
      // a normal mid-sentence pause (or a moment of WiFi jitter) trips just
      // as easily as an actual button release, cutting transcription off
      // while the user is still talking. An explicit marker on the real
      // release event removes the guessing entirely.
      static const uint8_t kEndMarker[1] = {0x00};
      this->socket_->sendto(kEndMarker, sizeof(kEndMarker), 0, (struct sockaddr *) &this->dest_addr_,
                             this->dest_len_);
    }
    this->socket_.reset();
  }

 protected:
  void on_audio_(const std::vector<uint8_t> &data) {
    if (!this->running_ || !this->socket_) {
      return;
    }
    ssize_t sent = this->socket_->sendto(data.data(), data.size(), 0, (struct sockaddr *) &this->dest_addr_,
                                          this->dest_len_);
    if (sent < 0) {
      ESP_LOGW(TAG, "PTT UDP send failed: errno %d", errno);
    }
  }

  std::string host_;
  uint16_t port_;
  esphome::microphone::MicrophoneSource source_;
  std::unique_ptr<esphome::socket::Socket> socket_;
  struct sockaddr_storage dest_addr_ {};
  socklen_t dest_len_{0};
  bool running_{false};
};

// Lazily-constructed singleton: the mic pointer/host/port are only used on
// the first call (constructor args are ignored on later calls, same as any
// function-local static), so every call site just passes the same
// substituted config and gets back the one shared instance.
inline UdpPushToTalk &get_instance(esphome::microphone::Microphone *mic, const std::string &host, uint16_t port) {
  static UdpPushToTalk instance(mic, host, port);
  return instance;
}

}  // namespace claude_ptt
