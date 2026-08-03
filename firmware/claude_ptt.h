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
//
// Target resolution: this device moves between networks (home, work --
// see the `wifi: networks:` fallback list in custom-voice-pe.yaml), and
// each has its own local machine running dictation_service.py at its own
// (possibly DHCP-assigned) IP. Rather than hardcoding a host per network,
// each press queries mDNS for a "_claudeptt._udp" service -- whichever
// local dictation_service.py is advertising on the CURRENT network answers,
// so the same firmware works unmodified wherever it's carried. Falls back
// to a fixed host substitution (see custom-voice-pe.yaml) if the query
// times out or nothing answers, so a network without mDNS/Bonjour support
// still works if that fallback happens to be reachable there.
//
// mdns_query_ptr() is Espressif's own managed `mdns` component (already
// linked in because ESPHome's own `mdns:` self-advertisement pulls it in),
// not lwIP's separate mDNS responder -- confirmed by checking which one
// actually ends up in managed_components/ for this build. Its query
// functions are plain blocking calls with a timeout, not the callback-based
// API lwIP's app would have required.

#include "esphome/components/microphone/microphone_source.h"
#include "esphome/components/socket/socket.h"
#include "esphome/core/log.h"

#include "mdns.h"
#include "esp_netif.h"

#include <memory>
#include <string>

namespace claude_ptt {

static const char *const TAG = "claude_ptt";
static const char *const kServiceType = "_claudeptt";
static const char *const kServiceProto = "_udp";
// Bounded so a press never hangs waiting on a network with no mDNS
// responder -- 300ms is generous for an mDNS round-trip on a healthy LAN
// (typically <50ms) while staying well under the length of even a quick
// deliberate hold.
static const uint32_t kMdnsQueryTimeoutMs = 300;

// Best-effort: returns false (leaving host_out/port_out untouched) on any
// failure -- no results, malformed response, no IPv4 address in the
// answer. Callers must have an established fallback for that case.
inline bool resolve_via_mdns(std::string &host_out, uint16_t &port_out) {
  mdns_result_t *results = nullptr;
  esp_err_t err = mdns_query_ptr(kServiceType, kServiceProto, kMdnsQueryTimeoutMs, /*max_results=*/1, &results);
  if (err != ESP_OK || results == nullptr) {
    return false;
  }
  bool found = false;
  for (mdns_ip_addr_t *a = results->addr; a != nullptr; a = a->next) {
    if (a->addr.type == ESP_IPADDR_TYPE_V4) {
      char buf[16];
      esp_ip4addr_ntoa(&a->addr.u_addr.ip4, buf, sizeof(buf));
      host_out = buf;
      port_out = results->port;
      found = true;
      break;
    }
  }
  mdns_query_results_free(results);
  return found;
}

class UdpPushToTalk {
 public:
  explicit UdpPushToTalk(esphome::microphone::Microphone *mic)
      : source_(mic, /*bits_per_sample=*/16, /*gain_factor=*/1, /*passive=*/false) {
    this->source_.add_channel(0);
    this->source_.add_data_callback([this](const std::vector<uint8_t> &data) { this->on_audio_(data); });
  }

  // fallback_host/fallback_port are used verbatim if the mDNS query finds
  // nothing -- see the file-level comment for why resolution happens fresh
  // on every press rather than once at construction.
  void start(const std::string &fallback_host, uint16_t fallback_port) {
    if (this->running_) {
      return;
    }
    std::string host = fallback_host;
    uint16_t port = fallback_port;
    if (resolve_via_mdns(host, port)) {
      ESP_LOGD(TAG, "PTT target via mDNS: %s:%u", host.c_str(), port);
    } else {
      ESP_LOGD(TAG, "PTT target via fallback (mDNS found nothing): %s:%u", host.c_str(), port);
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
    this->dest_len_ =
        esphome::socket::set_sockaddr((struct sockaddr *) &this->dest_addr_, sizeof(this->dest_addr_), host, port);
    if (this->dest_len_ == 0) {
      ESP_LOGE(TAG, "Could not resolve PTT target %s:%u", host.c_str(), port);
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

  esphome::microphone::MicrophoneSource source_;
  std::unique_ptr<esphome::socket::Socket> socket_;
  struct sockaddr_storage dest_addr_ {};
  socklen_t dest_len_{0};
  bool running_{false};
};

// Lazily-constructed singleton: the mic pointer is only used on the first
// call (constructor args are ignored on later calls, same as any
// function-local static), so every call site just passes the same mic and
// gets back the one shared instance.
inline UdpPushToTalk &get_instance(esphome::microphone::Microphone *mic) {
  static UdpPushToTalk instance(mic);
  return instance;
}

}  // namespace claude_ptt
