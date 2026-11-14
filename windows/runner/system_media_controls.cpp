#include "system_media_controls.h"
#include "taskbar_controls.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <deque>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Media;
using namespace winrt::Windows::Storage;
using namespace winrt::Windows::Storage::Streams;

constexpr int64_t kTicksPerMicrosecond = 10;
constexpr int64_t kMaxMicroseconds =
    (std::numeric_limits<int64_t>::max)() / kTicksPerMicrosecond;

const EncodableValue& Field(const EncodableMap& map, const char* name) {
  const auto found = map.find(EncodableValue(name));
  if (found == map.end()) throw std::invalid_argument("Missing SMTC field");
  return found->second;
}

template <typename T>
const T& Value(const EncodableValue& value) {
  const auto item = std::get_if<T>(&value);
  if (!item) throw std::invalid_argument("Invalid SMTC field type");
  return *item;
}

int64_t Integer(const EncodableValue& value) {
  if (const auto number = std::get_if<int32_t>(&value)) return *number;
  return Value<int64_t>(value);
}

const std::string& Text(const EncodableMap& map, const char* name) {
  return Value<std::string>(Field(map, name));
}

constexpr TimeSpan MediaTime(int64_t microseconds) {
  return TimeSpan(std::clamp(microseconds, int64_t{0}, kMaxMicroseconds) *
                  kTicksPerMicrosecond);
}
static_assert(MediaTime(-1).count() == 0);
static_assert(MediaTime(kMaxMicroseconds).count() ==
              kMaxMicroseconds * kTicksPerMicrosecond);

struct Event {
  std::string method;
  EncodableMap arguments;
  uint64_t generation = 0;
  RandomAccessStreamReference artwork{nullptr};
};

// The WinRT delegates and artwork coroutine own only this mailbox, never the
// Flutter channel or runner. Destruction closes it before releasing the HWND.
struct Mailbox {
  std::mutex mutex;
  HWND window = nullptr;
  bool open = true;
  uint64_t generation = 0;
  std::deque<Event> events;

  void Push(Event event) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!open || (event.method.empty() && event.generation != generation)) return;
    events.push_back(std::move(event));
    if (!::PostMessageW(window, SystemMediaControls::kMessage, 0, 0)) {
      events.pop_back();
    }
  }
};

winrt::fire_and_forget LoadArtwork(std::weak_ptr<Mailbox> weak,
                                  uint64_t generation, std::string kind,
                                  std::string value) {
  try {
    co_await winrt::resume_background();
    auto mailbox = weak.lock();
    if (!mailbox) co_return;
    {
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      if (!mailbox->open || mailbox->generation != generation) co_return;
    }
    RandomAccessStreamReference source{nullptr};
    if (kind == "file") {
      // Only local absolute files: a UNC path must not initiate network access.
      if (value.size() < 3 || value[1] != ':' ||
          (value[2] != '\\' && value[2] != '/')) co_return;
      auto file = co_await StorageFile::GetFileFromPathAsync(winrt::to_hstring(value));
      source = RandomAccessStreamReference::CreateFromFile(file);
    } else if (kind == "uri") {
      Uri uri(winrt::to_hstring(value));
      const auto scheme = uri.SchemeName();
      if ((scheme != L"https" && scheme != L"http") || uri.Host().empty() ||
          !uri.UserName().empty() || !uri.Password().empty()) co_return;
      source = RandomAccessStreamReference::CreateFromUri(uri);
    } else {
      co_return;
    }
    // Open off the platform thread; Windows may otherwise fetch/decode the URI
    // while the display updater is being changed on that thread.
    auto stream = co_await source.OpenReadAsync();
    Event event;
    event.generation = generation;
    event.artwork = RandomAccessStreamReference::CreateFromStream(stream);
    mailbox->Push(std::move(event));
  } catch (const winrt::hresult_error& error) {
    // Metadata remains usable without a failed/removed artwork file or URL.
    ::OutputDebugStringW((L"XMPlus SMTC artwork: " + error.message() + L"\n").c_str());
  } catch (const std::exception&) {
    ::OutputDebugStringW(L"XMPlus SMTC artwork: invalid artwork data\n");
  }
}
}  // namespace

struct SystemMediaControls::Impl {
  HWND window;
  TaskbarControls taskbar;
  flutter::MethodChannel<EncodableValue> channel;
  std::shared_ptr<Mailbox> mailbox;
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_token{};
  winrt::event_token position_token{};
  winrt::event_token rate_token{};
  bool button_registered = false;
  bool position_registered = false;
  bool rate_registered = false;
  bool runtime_initialized = false;
  bool seek_enabled = false;
  bool speed_enabled = false;
  int64_t duration = 0;
  std::string artwork_key;

  Impl(HWND hwnd, flutter::BinaryMessenger* messenger)
      : window(hwnd),
        taskbar(hwnd),
        channel(messenger, "xmplus/system_media",
                &flutter::StandardMethodCodec::GetInstance()) {
    channel.SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
          try {
            if (call.method_name() == "configure") {
              Dispose();
              Initialize();
            } else if (call.method_name() == "update") {
              if (!controls) throw std::logic_error("SMTC is not configured");
              if (!call.arguments()) throw std::invalid_argument("Missing SMTC update payload");
              Update(Value<EncodableMap>(*call.arguments()));
            } else if (call.method_name() == "stopService") {
              Stop();
            } else if (call.method_name() == "dispose") {
              Dispose();
            } else {
              result->NotImplemented();
              return;
            }
            result->Success();
          } catch (const winrt::hresult_error& error) {
            result->Error("smtc_error", winrt::to_string(error.message()));
          } catch (const std::exception& error) {
            result->Error("smtc_error", error.what());
          }
        });
  }

  ~Impl() {
    channel.SetMethodCallHandler(nullptr);
    Dispose();
  }

  void Initialize() {
    winrt::check_hresult(::RoInitialize(RO_INIT_SINGLETHREADED));
    runtime_initialized = true;
    try {
      auto interop = winrt::get_activation_factory<SystemMediaTransportControls,
                                                   ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(interop->GetForWindow(
          window, winrt::guid_of<SystemMediaTransportControls>(),
          winrt::put_abi(controls)));
      controls.IsEnabled(false);
      controls.DisplayUpdater().Type(MediaPlaybackType::Music);
      mailbox = std::make_shared<Mailbox>();
      mailbox->window = window;
      const std::weak_ptr<Mailbox> weak = mailbox;
      button_token = controls.ButtonPressed(
          [weak](const auto&, const SystemMediaTransportControlsButtonPressedEventArgs& args) {
            Event event;
            switch (args.Button()) {
              case SystemMediaTransportControlsButton::Play: event.method = "play"; break;
              case SystemMediaTransportControlsButton::Pause: event.method = "pause"; break;
              case SystemMediaTransportControlsButton::Stop: event.method = "stop"; break;
              case SystemMediaTransportControlsButton::Next: event.method = "skipToNext"; break;
              case SystemMediaTransportControlsButton::Previous: event.method = "skipToPrevious"; break;
              case SystemMediaTransportControlsButton::FastForward: event.method = "fastForward"; break;
              case SystemMediaTransportControlsButton::Rewind: event.method = "rewind"; break;
              default: return;
            }
            if (auto target = weak.lock()) target->Push(std::move(event));
          });
      button_registered = true;
      position_token = controls.PlaybackPositionChangeRequested(
          [weak](const auto&, const PlaybackPositionChangeRequestedEventArgs& args) {
            Event event;
            event.method = "seek";
            event.arguments.emplace(EncodableValue("position"),
                EncodableValue(args.RequestedPlaybackPosition().count() / kTicksPerMicrosecond));
            if (auto target = weak.lock()) target->Push(std::move(event));
          });
      position_registered = true;
      rate_token = controls.PlaybackRateChangeRequested(
          [weak](const auto&, const PlaybackRateChangeRequestedEventArgs& args) {
            Event event;
            event.method = "setSpeed";
            event.arguments.emplace(EncodableValue("speed"),
                                    EncodableValue(args.RequestedPlaybackRate()));
            if (auto target = weak.lock()) target->Push(std::move(event));
          });
      rate_registered = true;
      Stop();
    } catch (...) {
      Dispose();
      throw;
    }
  }

  void InvalidateArtwork() {
    artwork_key.clear();
    if (mailbox) {
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      ++mailbox->generation;
      auto& events = mailbox->events;
      events.erase(std::remove_if(events.begin(), events.end(),
                                  [](const Event& event) { return event.method.empty(); }),
                   events.end());
    }
  }

  void Stop(MediaPlaybackStatus status = MediaPlaybackStatus::Closed) {
    taskbar.Update({});
    InvalidateArtwork();
    if (mailbox) {
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      mailbox->events.clear();
    }
    seek_enabled = false;
    speed_enabled = false;
    duration = 0;
    if (!controls) return;
    controls.IsEnabled(false);
    controls.PlaybackStatus(status);
    controls.PlaybackRate(0.0);
    controls.IsPlayEnabled(false);
    controls.IsPauseEnabled(false);
    controls.IsStopEnabled(false);
    controls.IsNextEnabled(false);
    controls.IsPreviousEnabled(false);
    controls.IsFastForwardEnabled(false);
    controls.IsRewindEnabled(false);
    auto updater = controls.DisplayUpdater();
    updater.ClearAll();
    updater.Thumbnail(nullptr);
    updater.Update();
    controls.UpdateTimelineProperties(SystemMediaTransportControlsTimelineProperties());
  }

  void Dispose() noexcept {
    if (mailbox) {
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      mailbox->open = false;
      mailbox->window = nullptr;
      mailbox->events.clear();
    }
    // Revocation can race Windows session teardown. Still revoke every token
    // and release the channel-independent mailbox even if one call fails.
    if (controls) {
      try { if (button_registered) controls.ButtonPressed(button_token); } catch (...) {}
      try { if (position_registered) controls.PlaybackPositionChangeRequested(position_token); } catch (...) {}
      try { if (rate_registered) controls.PlaybackRateChangeRequested(rate_token); } catch (...) {}
      try { Stop(); } catch (...) {}
    }
    button_registered = position_registered = rate_registered = false;
    controls = nullptr;
    mailbox.reset();
    if (runtime_initialized) {
      ::RoUninitialize();
      runtime_initialized = false;
    }
  }

  void Update(const EncodableMap& map) {
    const auto status = Text(map, "status");
    if (status == "idle" || status == "stopped") {
      Stop(status == "stopped" ? MediaPlaybackStatus::Stopped : MediaPlaybackStatus::Closed);
      return;
    }
    if (status != "playing" && status != "paused" && status != "changing") {
      throw std::invalid_argument("Invalid SMTC playback status");
    }
    duration = std::clamp(Integer(Field(map, "duration")), int64_t{0}, kMaxMicroseconds);
    const auto position = std::clamp(Integer(Field(map, "position")), int64_t{0}, duration);
    const auto rate = Value<double>(Field(map, "speed"));
    if (!std::isfinite(rate) || rate < 0) throw std::invalid_argument("Invalid SMTC playback rate");
    const auto& actions = Value<EncodableList>(Field(map, "actions"));
    const auto has = [&actions](const char* action) {
      return std::find(actions.begin(), actions.end(), EncodableValue(action)) != actions.end();
    };
    controls.IsPlayEnabled(has("play") || has("playPause"));
    controls.IsPauseEnabled(has("pause") || has("playPause"));
    controls.IsStopEnabled(has("stop"));
    controls.IsNextEnabled(has("skipToNext"));
    controls.IsPreviousEnabled(has("skipToPrevious"));
    controls.IsFastForwardEnabled(has("fastForward"));
    controls.IsRewindEnabled(has("rewind"));
    seek_enabled = has("seek") && duration > 0;
    speed_enabled = has("setSpeed");
    controls.PlaybackStatus(status == "playing" ? MediaPlaybackStatus::Playing :
        status == "paused" ? MediaPlaybackStatus::Paused : MediaPlaybackStatus::Changing);
    controls.PlaybackRate(status == "playing" ? rate : 0.0);
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(MediaTime(0));
    timeline.EndTime(MediaTime(duration));
    timeline.MinSeekTime(MediaTime(seek_enabled ? 0 : position));
    timeline.MaxSeekTime(MediaTime(seek_enabled ? duration : position));
    timeline.Position(MediaTime(position));
    controls.UpdateTimelineProperties(timeline);

    auto updater = controls.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    auto music = updater.MusicProperties();
    music.Title(winrt::to_hstring(Text(map, "title")));
    music.Artist(winrt::to_hstring(Text(map, "artist")));
    music.AlbumTitle(winrt::to_hstring(Text(map, "album")));
    std::string kind;
    std::string value;
    if (const auto artwork = std::get_if<EncodableMap>(&Field(map, "artwork"))) {
      kind = Text(*artwork, "kind");
      value = Text(*artwork, "value");
    }
    const auto key = kind + ":" + value;
    if (key != artwork_key) {
      InvalidateArtwork();
      artwork_key = key;
      updater.Thumbnail(nullptr);
      if (!value.empty()) {
        uint64_t generation;
        {
          std::lock_guard<std::mutex> lock(mailbox->mutex);
          generation = mailbox->generation;
        }
        LoadArtwork(mailbox, generation, std::move(kind), std::move(value));
      }
    }
    updater.Update();
    controls.IsEnabled(true);
    taskbar.Update({true, status == "playing" || (has("pause") && !has("play")),
        has("skipToPrevious"), has("play") || has("playPause"),
        has("pause") || has("playPause"), has("skipToNext")});
  }

  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam) noexcept {
    TaskbarControls::Action action;
    const auto handled = taskbar.HandleMessage(message, wparam, lparam, action);
    if (!mailbox || action == TaskbarControls::Action::none) return handled;
    try {
      Event event;
      switch (action) {
        case TaskbarControls::Action::previous: event.method = "skipToPrevious"; break;
        case TaskbarControls::Action::play: event.method = "play"; break;
        case TaskbarControls::Action::pause: event.method = "pause"; break;
        case TaskbarControls::Action::next: event.method = "skipToNext"; break;
        default: return handled;
      }
      // Use the same mailbox and permission checks as keyboard/SMTC commands.
      mailbox->Push(std::move(event));
    } catch (const std::exception&) {
      ::OutputDebugStringW(L"XMPlus taskbar: unable to queue media command\n");
    }
    return handled;
  }

  bool Allowed(const std::string& method) const {
    if (!controls || !controls.IsEnabled()) return false;
    if (method == "play") return controls.IsPlayEnabled();
    if (method == "pause") return controls.IsPauseEnabled();
    if (method == "stop") return controls.IsStopEnabled();
    if (method == "skipToNext") return controls.IsNextEnabled();
    if (method == "skipToPrevious") return controls.IsPreviousEnabled();
    if (method == "fastForward") return controls.IsFastForwardEnabled();
    if (method == "rewind") return controls.IsRewindEnabled();
    if (method == "seek") return seek_enabled;
    if (method == "setSpeed") return speed_enabled;
    return false;
  }

  void ProcessEvents() noexcept {
    if (!mailbox) return;
    std::deque<Event> events;
    uint64_t generation;
    {
      std::lock_guard<std::mutex> lock(mailbox->mutex);
      events.swap(mailbox->events);
      generation = mailbox->generation;
    }
    for (auto& event : events) {
      try {
        if (event.method.empty()) {
          if (event.generation == generation && controls && controls.IsEnabled()) {
            auto updater = controls.DisplayUpdater();
            updater.Thumbnail(event.artwork);
            updater.Update();
          }
        } else if (Allowed(event.method)) {
          if (event.method == "seek") {
            auto& value = event.arguments.at(EncodableValue("position"));
            value = EncodableValue(std::clamp(Integer(value), int64_t{0}, duration));
          }
          channel.InvokeMethod(event.method,
              std::make_unique<EncodableValue>(std::move(event.arguments)));
        }
      } catch (const winrt::hresult_error& error) {
        ::OutputDebugStringW((L"XMPlus SMTC event: " + error.message() + L"\n").c_str());
      } catch (const std::exception&) {
        ::OutputDebugStringW(L"XMPlus SMTC event: invalid event data\n");
      }
    }
  }
};

SystemMediaControls::SystemMediaControls(HWND window,
                                         flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(window, messenger)) {}

SystemMediaControls::~SystemMediaControls() = default;

void SystemMediaControls::ProcessEvents() noexcept {
  impl_->ProcessEvents();
}

bool SystemMediaControls::HandleWindowMessage(UINT message, WPARAM wparam,
                                              LPARAM lparam) noexcept {
  return impl_->HandleWindowMessage(message, wparam, lparam);
}
